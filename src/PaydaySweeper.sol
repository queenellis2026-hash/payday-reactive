// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { AbstractCallback } from "@reactive/abstract-base/AbstractCallback.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPaydayVault {
    function depositFor(address user, uint256 amount) external;
}

/// @title Payday — savings sweeper (callback side, Base Sepolia)
/// @notice Receives callbacks from PaydayReactive on Lasna. Pulls the swept share
///         from the user's wallet (via their ERC20 allowance) and deposits it into
///         their PaydayVault.
/// @dev The deployer MUST be the same address that deployed PaydayReactive:
///      AbstractCallback records msg.sender as rvm_id, and the Reactive node
///      injects the reactive contract's deployer as the first callback arg.
contract PaydaySweeper is AbstractCallback {
    IERC20 public immutable token;
    IPaydayVault public immutable vault;

    event Swept(address indexed user, uint256 amount);

    /// @param _callbackProxy Base Sepolia callback proxy
    ///        (0x476F44b11F5C942c58f4c8E3d0300E5710743585)
    constructor(address _callbackProxy, address _token, address _vault)
        AbstractCallback(_callbackProxy)
    {
        require(_token != address(0) && _vault != address(0), "zero address");
        token = IERC20(_token);
        vault = IPaydayVault(_vault);
        // One max approval: every sweep moves funds straight through to the vault.
        require(token.approve(address(vault), type(uint256).max), "vault approve failed");
    }

    /// @notice Called by the callback proxy. `sender` is the rvm_id injected by
    ///         the Reactive node (the PaydayReactive deployer).
    function callback(address sender, address user, uint256 amount)
        external
        authorizedSenderOnly
        rvmIdOnly(sender)
    {
        require(amount > 0, "zero amount");
        require(token.transferFrom(user, address(this), amount), "pull failed");
        vault.depositFor(user, amount);
        emit Swept(user, amount);
    }
}
