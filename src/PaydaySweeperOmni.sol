// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { AbstractCallback } from "@reactive-omni/src/base/AbstractCallback.sol";
import { IPayable } from "@reactive-omni/src/interfaces/IPayable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPaydayVault {
    function depositFor(address user, uint256 amount) external;
}

/// @title Payday — savings sweeper, Omni callback side (Base Sepolia)
/// @notice Receives callbacks from the Omni PaydayReactive on Lasna. Pulls the
///         swept share from the user's wallet (via their ERC20 allowance) and
///         deposits it into their PaydayVault.
/// @dev Omni port of Rowan's PaydaySweeper (Nov 18, 2026). Sweep logic,
///      amounts and vault interaction are behavior-identical to the legacy
///      sweeper; ONLY the caller-authentication wiring changed:
///
///      - Legacy: AbstractCallback recorded the deployer EOA as rvm_id, and
///        the callback's first argument had to equal it (the legacy node
///        injected the reactive contract's deployer id there).
///      - Omni: the callback proxy overwrites the first argument with the
///        REACTIVE CONTRACT's address, so this sweeper is built on
///        reactive-lib-omni's AbstractCallback and authenticates that
///        address instead — the immutable _CALLBACK_SENDER, set at
///        construction to the Omni PaydayReactive's address. The proxy
///        itself is authenticated by onlyServiceProvider (the proxy is the
///        AbstractPayer service provider), mirroring the legacy
///        authorizedSenderOnly check and the MCP template's guard pair.
contract PaydaySweeperOmni is AbstractCallback {
    IERC20 public immutable token;
    IPaydayVault public immutable vault;

    event Swept(address indexed user, uint256 amount);

    /// @param _callbackProxy Base Sepolia callback proxy
    ///        (0x476F44b11F5C942c58f4c8E3d0300E5710743585)
    /// @param _reactiveContract The Omni PaydayReactive on Lasna. The proxy
    ///        injects this address as the callback's first argument; it is
    ///        immutable, so a wrong value means redeploying this sweeper.
    constructor(address payable _callbackProxy, address _token, address _vault, address _reactiveContract)
        payable
        AbstractCallback(IPayable(_callbackProxy), _reactiveContract)
    {
        require(_token != address(0) && _vault != address(0) && _reactiveContract != address(0), "zero address");
        token = IERC20(_token);
        vault = IPaydayVault(_vault);
        // One max approval: every sweep moves funds straight through to the vault.
        require(token.approve(address(vault), type(uint256).max), "vault approve failed");
    }

    /// @notice Called by the callback proxy. `sender` is the reactive
    ///         contract's address, injected by the proxy (it overwrites the
    ///         address(0) placeholder the reactive contract sends).
    function callback(address sender, address user, uint256 amount)
        external
        onlyServiceProvider
        onlyCallbackSender(sender)
    {
        require(amount > 0, "zero amount");
        require(token.transferFrom(user, address(this), amount), "pull failed");
        vault.depositFor(user, amount);
        emit Swept(user, amount);
    }
}
