// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IReactive } from "@reactive-omni/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive-omni/src/interfaces/ISystemContract.sol";
import { AbstractPayer } from "@reactive-omni/src/base/AbstractPayer.sol";
import { PaydayReactive } from "../src/PaydayReactive.sol";
import { PaydaySweeper } from "../src/PaydaySweeper.sol";
import { PaydayVault } from "../src/PaydayVault.sol";
import { MockUSDC } from "../src/MockUSDC.sol";

/// @notice Minimal stand-in for the Omni system contract (0x8888…8888), which
///         exists on Lasna but not in the local test env. Etched in setUp so
///         the reactive contract's constructor subscription succeeds. Records
///         callback requests so tests can assert on them (the Omni API has no
///         Callback event; react() requests callbacks through the system
///         contract instead).
contract MockSystemContract {
    uint256 public requestCount;
    uint256 public lastChainId;
    address public lastRecipient;
    uint64 public lastGasLimit;
    bytes public lastPayload;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external { }
    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external { }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 calldata config) external {
        requestCount += 1;
        lastChainId = config.chainId;
        lastRecipient = config.recipient;
        lastGasLimit = config.gasLimit;
        lastPayload = config.payload;
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable { }
}

contract PaydayTest is Test {
    address internal constant SYSTEM_CONTRACT = 0x8888888888888888888888888888888888888888;
    address internal constant BASE_SEPOLIA_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;

    MockUSDC internal token;
    PaydayVault internal vault;
    PaydaySweeper internal sweeper;
    PaydayReactive internal reactive;
    MockSystemContract internal systemMock;

    address internal user = address(0xBEEF);
    uint256 internal constant TRANSFER_TOPIC_0 = uint256(keccak256("Transfer(address,address,uint256)"));

    function setUp() public {
        // Etch the mock system contract before deploying the reactive contract:
        // its constructor subscribes via the system contract at 0x8888…8888.
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_CONTRACT, address(mock).code);
        systemMock = MockSystemContract(payable(SYSTEM_CONTRACT));

        token = new MockUSDC();
        vault = new PaydayVault(address(token));
        // This test contract is the deployer, so it is the rvm_id the sweeper trusts.
        sweeper = new PaydaySweeper(BASE_SEPOLIA_PROXY, address(token), address(vault));
        vault.setSweeper(address(sweeper));
        reactive = new PaydayReactive(address(token), address(sweeper));

        token.mint(user, 1_000_000_000); // 1,000 pdUSD
        vm.prank(user);
        token.approve(address(sweeper), type(uint256).max);
    }

    function _transferLog(address to, uint256 amount) internal pure returns (IReactive.LogRecord memory) {
        return _transferLogFrom(address(0), to, amount);
    }

    function _transferLogFrom(address from, address to, uint256 amount)
        internal
        pure
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: 84532,
            contractAddress: address(0),
            topic0: TRANSFER_TOPIC_0,
            topic1: uint256(uint160(from)),
            topic2: uint256(uint160(to)),
            topic3: 0,
            data: abi.encode(amount),
            blockNumber: 0,
            opCode: 0,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function testSetRuleAndReactRequestsSweep() public {
        vm.prank(user);
        reactive.setRule(1000, 5_000_000, true); // 10%, min 5 pdUSD

        bytes memory expectedPayload =
            abi.encodeWithSignature("callback(address,address,uint256)", address(0), user, 10_000_000);

        vm.prank(SYSTEM_CONTRACT);
        reactive.react(_transferLog(user, 100_000_000)); // 100 pdUSD in -> 10 swept

        // Omni: the sweep is requested through the system contract, with the
        // same chain, recipient, gas limit and payload the legacy build
        // carried in its Callback event.
        assertEq(systemMock.requestCount(), 1, "one callback request expected");
        assertEq(systemMock.lastChainId(), 84532);
        assertEq(systemMock.lastRecipient(), address(sweeper));
        assertEq(systemMock.lastGasLimit(), 300_000);
        assertEq(systemMock.lastPayload(), expectedPayload);
    }

    /// @notice H-01 regression: a self-transfer is not an inbound receipt —
    ///         the recipient's balance does not increase — so react() must
    ///         request NO callback for it, even with an active rule and an
    ///         amount above the minimum.
    function testReactSkipsSelfTransfer() public {
        vm.prank(user);
        reactive.setRule(1000, 5_000_000, true); // 10%, min 5 pdUSD
        vm.prank(SYSTEM_CONTRACT);
        reactive.react(_transferLogFrom(user, user, 100_000_000)); // user -> user, 100 pdUSD
        assertEq(systemMock.requestCount(), 0, "self-transfer must not request a callback");
    }

    /// @notice H-01 regression, other side: a mint (sender == address(0)) is a
    ///         genuine inbound receipt and must still qualify.
    function testReactAcceptsMint() public {
        vm.prank(user);
        reactive.setRule(1000, 5_000_000, true);
        vm.prank(SYSTEM_CONTRACT);
        reactive.react(_transferLogFrom(address(0), user, 100_000_000)); // mint 100 pdUSD to user
        assertEq(systemMock.requestCount(), 1, "mint must request a callback");
    }

    /// @notice Ordinary wallet-to-wallet transfer (sender != recipient,
    ///         sender != address(0)) must still qualify.
    function testReactAcceptsOrdinaryTransfer() public {
        address payer = address(0xCAFE);
        vm.prank(user);
        reactive.setRule(1000, 5_000_000, true);
        vm.prank(SYSTEM_CONTRACT);
        reactive.react(_transferLogFrom(payer, user, 100_000_000)); // payer -> user, 100 pdUSD
        assertEq(systemMock.requestCount(), 1, "ordinary transfer must request a callback");
    }

    /// @notice M-05 regression: the sweep share uses a full-precision mulDiv,
    ///         so amounts whose (amount * pctBps) would overflow uint256 under
    ///         the old formula still compute instead of reverting. Both cases
    ///         push the product past 2^256, exercising the 512-bit path.
    function testReactHugeAmountNoOverflow() public {
        uint256 huge = 2 ** 255;
        vm.prank(user);
        reactive.setRule(10_000, 0, true); // 100%
        bytes memory expectedPayload =
            abi.encodeWithSignature("callback(address,address,uint256)", address(0), user, huge);
        vm.prank(SYSTEM_CONTRACT);
        reactive.react(_transferLogFrom(address(0xCAFE), user, huge));
        assertEq(systemMock.requestCount(), 1, "huge amount must request a callback");
        assertEq(systemMock.lastPayload(), expectedPayload);

        // 3 * 2^253 at 50% -> exactly 3 * 2^252 (product ~2^266.6, full path,
        // non-power-of-two numerator so the division is genuinely exercised).
        uint256 amount2 = 3 * 2 ** 253;
        vm.prank(user);
        reactive.setRule(5000, 0, true); // 50%
        bytes memory expectedPayload2 =
            abi.encodeWithSignature("callback(address,address,uint256)", address(0), user, 3 * 2 ** 252);
        vm.prank(SYSTEM_CONTRACT);
        reactive.react(_transferLogFrom(address(0xCAFE), user, amount2));
        assertEq(systemMock.requestCount(), 2, "second huge amount must request a callback");
        assertEq(systemMock.lastPayload(), expectedPayload2);
    }

    function testReactSkipsBelowMinimum() public {
        vm.prank(user);
        reactive.setRule(1000, 5_000_000, true);
        vm.prank(SYSTEM_CONTRACT);
        reactive.react(_transferLog(user, 4_000_000)); // 4 pdUSD < 5 min
        assertEq(systemMock.requestCount(), 0, "no callback expected");
    }

    function testReactSkipsUnregisteredUser() public {
        vm.prank(SYSTEM_CONTRACT);
        reactive.react(_transferLog(user, 100_000_000));
        assertEq(systemMock.requestCount(), 0, "no callback expected");
    }

    function testReactRejectsNonSystemCaller() public {
        vm.prank(user);
        reactive.setRule(1000, 0, true);
        // Omni onlySystem reverts with AbstractPayer.NotAuthorized(caller, SYSTEM).
        vm.expectRevert(
            abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYSTEM_CONTRACT)
        );
        reactive.react(_transferLog(user, 100_000_000));
    }

    function testSetRuleRejectsOver100Percent() public {
        vm.prank(user);
        vm.expectRevert("pct > 100%");
        reactive.setRule(10_001, 0, true);
    }

    function testSweeperCallbackMovesFundsToVault() public {
        uint256 userBefore = token.balanceOf(user);
        vm.prank(BASE_SEPOLIA_PROXY);
        sweeper.callback(address(this), user, 10_000_000);
        assertEq(token.balanceOf(user), userBefore - 10_000_000);
        assertEq(vault.balances(user), 10_000_000);
    }

    function testSweeperCallbackRejectsWrongProxy() public {
        vm.prank(user);
        vm.expectRevert("Authorized sender only");
        sweeper.callback(address(this), user, 10_000_000);
    }

    function testSweeperCallbackRejectsWrongRvmId() public {
        vm.prank(BASE_SEPOLIA_PROXY);
        vm.expectRevert("Authorized RVM ID only");
        sweeper.callback(address(0xDEAD), user, 10_000_000);
    }

    function testVaultWithdraw() public {
        vm.prank(BASE_SEPOLIA_PROXY);
        sweeper.callback(address(this), user, 10_000_000);
        vm.prank(user);
        vault.withdraw(4_000_000);
        assertEq(vault.balances(user), 6_000_000);
        assertEq(token.balanceOf(user), 1_000_000_000 - 10_000_000 + 4_000_000);
    }

    function testVaultWithdrawRejectsOverBalance() public {
        vm.prank(user);
        vm.expectRevert("insufficient savings");
        vault.withdraw(1);
    }
}
