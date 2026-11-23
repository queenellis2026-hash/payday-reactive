// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IReactive } from "@reactive-omni/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive-omni/src/interfaces/ISystemContract.sol";
import { AbstractReactive } from "@reactive-omni/src/base/AbstractReactive.sol";

/// @title Payday — automatic savings sweep (reactive side, Reactive Lasna)
/// @notice Watches ERC20 Transfer events on Base Sepolia. When a registered user
///         receives an inbound transfer at or above their minimum, this contract
///         asks Reactive Network to call back into PaydaySweeper on Base Sepolia,
///         which pulls the configured percentage into the user's PaydayVault.
/// @dev One subscription covers every Transfer on the token; react() filters by
///      recipient rule, so any number of users share it.
/// @dev OMNI PORT (Nov 18, 2026): built against reactive-lib-omni instead of the
///      legacy reactive-lib. Only the library / system-contract wiring changed:
///      SYSTEM is the Omni system contract (0x8888…8888), the guard is the
///      library's onlySystem, the subscription goes through SYSTEM.subscribe,
///      and the callback is requested via SYSTEM.requestCallbackV_1_0 instead of
///      the deprecated Callback event. Rule handling and the callback payload
///      are unchanged from Rowan's original.
/// @dev FIX ROUND (Nov 18, 2026, after the ChatGPT cold review): react() now
///      reads the sender from topic1 and skips self-transfers (H-01 — a
///      self-transfer is not an inbound receipt), and the sweep share is
///      computed with a full-precision mulDiv (M-05 — no overflow before the
///      division; implemented locally as _mulDiv because the vendored
///      OpenZeppelin Math.sol requires solc ^0.8.31 and this project pins
///      0.8.29). Nothing else changed.
contract PaydayReactive is IReactive, AbstractReactive {
    uint256 public constant ORIGIN_CHAIN_ID = 84532; // Base Sepolia
    uint256 public constant TRANSFER_TOPIC_0 = uint256(keccak256("Transfer(address,address,uint256)"));
    uint64 public constant CALLBACK_GAS_LIMIT = 300_000;

    address public immutable token; // ERC20 watched on Base Sepolia (MockUSDC in the demo)
    address public sweeper; // PaydaySweeper on Base Sepolia
    address public owner;

    struct Rule {
        uint16 pctBps; // share of each inbound transfer to sweep, basis points (0-10000)
        uint256 minAmount; // ignore inbound transfers below this (token base units)
        bool active;
    }

    mapping(address => Rule) public rules;

    event RuleSet(address indexed user, uint16 pctBps, uint256 minAmount, bool active);
    event SweepRequested(address indexed user, uint256 received, uint256 sweepAmount);
    event SweeperUpdated(address indexed sweeper);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    // On Omni there is no RVM: the system contract (0x8888…8888) calls react()
    // directly, and the Omni library's onlySystem modifier authenticates it
    // (it replaces the hand-rolled systemOnly check against the legacy
    // 0x000…fffFfF service address, which is what broke the first deployment).

    /// @notice Payable so the contract can be funded with lREACT at deployment.
    constructor(address _token, address _sweeper) payable {
        require(_token != address(0) && _sweeper != address(0), "zero address");
        token = _token;
        sweeper = _sweeper;
        owner = msg.sender;
        SYSTEM.subscribe(
            ORIGIN_CHAIN_ID,
            _token,
            TRANSFER_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /// @notice Register or update your sweep rule. Callable by anyone for their own address.
    function setRule(uint16 pctBps, uint256 minAmount, bool active) external {
        require(pctBps <= 10_000, "pct > 100%");
        rules[msg.sender] = Rule(pctBps, minAmount, active);
        emit RuleSet(msg.sender, pctBps, minAmount, active);
    }

    function setSweeper(address _sweeper) external onlyOwner {
        require(_sweeper != address(0), "zero address");
        sweeper = _sweeper;
        emit SweeperUpdated(_sweeper);
    }

    /// @notice Settles outstanding debt to the Omni system contract from this
    ///         contract's own balance.
    /// @dev The legacy lib exposed coverDebt() externally via AbstractPayer;
    ///      the Omni lib keeps it internal (_coverDebt), so it is exposed here
    ///      to preserve the deployed contract's external surface. Unlike the
    ///      legacy version, this one reads the debt from the Omni system
    ///      contract (0x8888…8888) — the contract that actually holds it.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Called by the system contract for each matching Transfer log.
    ///         topic1 is the sender, topic2 is the recipient, data is the amount.
    /// @dev Self-transfers (sender == recipient) are NOT inbound receipts — the
    ///      recipient's balance does not increase — so they never qualify
    ///      (H-01). Mints (sender == address(0)) DO qualify: newly issued
    ///      tokens are a genuine inbound receipt.
    function react(LogRecord calldata log) external override onlySystem {
        address sender = address(uint160(log.topic1));
        address recipient = address(uint160(log.topic2));
        if (sender == recipient) return;
        Rule memory rule = rules[recipient];
        if (!rule.active || rule.pctBps == 0) return;
        uint256 amount = abi.decode(log.data, (uint256));
        if (amount < rule.minAmount) return;
        uint256 sweepAmount = _mulDiv(amount, rule.pctBps, 10_000);
        if (sweepAmount == 0) return;
        // First arg is address(0): the Reactive proxy overwrites it with this
        // contract's address when delivering the callback.
        bytes memory payload = abi.encodeWithSignature(
            "callback(address,address,uint256)", address(0), recipient, sweepAmount
        );
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: ORIGIN_CHAIN_ID, recipient: sweeper, gasLimit: CALLBACK_GAS_LIMIT, payload: payload
            })
        );
        emit SweepRequested(recipient, amount, sweepAmount);
    }

    /// @dev Full-precision (x * y) / denominator with a 512-bit intermediate —
    ///      the same algorithm as OpenZeppelin's Math.mulDiv (after Remco
    ///      Bloemen's 512/256 division), implemented locally because the
    ///      vendored OpenZeppelin Math.sol requires solc ^0.8.31 while this
    ///      project pins 0.8.29. Reverts if the result would not fit in
    ///      256 bits (impossible here: pctBps <= 10_000 and the denominator
    ///      is 10_000, so the result never exceeds the amount).
    function _mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = x * y.
            uint256 prod0 = x * y;
            uint256 prod1;
            assembly {
                let mm := mulmod(x, y, not(0))
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Non-overflow case: 256-by-256 division.
            if (prod1 == 0) {
                return prod0 / denominator;
            }

            // The result must fit in 256 bits; also rejects denominator == 0.
            require(denominator > prod1, "mulDiv overflow");

            // 512-by-256 division: subtract the remainder so [prod1 prod0]
            // is exactly divisible by the denominator.
            uint256 remainder;
            assembly {
                remainder := mulmod(x, y, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of the denominator (twos = its largest
            // power-of-two divisor) and divide them out of [prod1 prod0].
            uint256 twos = denominator & (0 - denominator);
            denominator /= twos;
            prod0 /= twos;
            // twos becomes 2^256 / twos (the shift-in factor for prod1's bits).
            twos = (0 - twos) / twos + 1;

            // Shift the remaining high bits into prod0.
            prod0 |= prod1 * twos;

            // Modular inverse of the (now odd) denominator mod 2^256,
            // Newton–Raphson from a 4-bit seed to full precision.
            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse; // inverse mod 2^8
            inverse *= 2 - denominator * inverse; // inverse mod 2^16
            inverse *= 2 - denominator * inverse; // inverse mod 2^32
            inverse *= 2 - denominator * inverse; // inverse mod 2^64
            inverse *= 2 - denominator * inverse; // inverse mod 2^128
            inverse *= 2 - denominator * inverse; // inverse mod 2^256

            result = prod0 * inverse;
        }
    }
}
