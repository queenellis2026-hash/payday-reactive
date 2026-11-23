// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { AbstractCallback } from "@reactive-omni/src/base/AbstractCallback.sol";
import { AbstractPayer } from "@reactive-omni/src/base/AbstractPayer.sol";
import { PaydaySweeperOmni } from "../src/PaydaySweeperOmni.sol";
import { PaydayVault } from "../src/PaydayVault.sol";
import { MockUSDC } from "../src/MockUSDC.sol";

/// @notice Tests for the Omni sweeper's caller authentication — the exact
///         property the legacy sweeper got wrong for Lasna Omni. The Omni
///         callback proxy overwrites the callback's first argument with the
///         reactive contract's address, so the sweeper must accept THAT
///         address and reject everything else, including the legacy rvm_id
///         (the deployer EOA) the old sweeper demanded.
///
/// @dev The vault here is freshly deployed, so its one-time setSweeper is
///      spent on the Omni sweeper. The vault already deployed on Base
///      Sepolia (0xB78F507C8e46CB63ec7D6a76B11cfDE3F9066719) had its
///      setSweeper spent on the legacy sweeper on Nov 18 and cannot be
///      re-pointed — see omni-sweeper-deploy-record-2026-11-18.md.
contract PaydaySweeperOmniTest is Test {
    address internal constant BASE_SEPOLIA_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;
    // Stand-in for the Omni PaydayReactive's address (the value the proxy injects).
    address internal constant REACTIVE_CONTRACT = address(0xC0FFEE);
    // The legacy rvm_id: Ellis's deployer EOA, the only first argument the
    // deployed legacy sweeper accepts.
    address internal constant LEGACY_RVM_ID = 0x307d85Fb0741Bee6Dc8e5CFc62331Af90526eB1B;

    MockUSDC internal token;
    PaydayVault internal vault;
    PaydaySweeperOmni internal sweeper;

    address internal user = address(0xBEEF);

    function setUp() public {
        token = new MockUSDC();
        vault = new PaydayVault(address(token));
        sweeper = new PaydaySweeperOmni(payable(BASE_SEPOLIA_PROXY), address(token), address(vault), REACTIVE_CONTRACT);
        vault.setSweeper(address(sweeper));

        token.mint(user, 1_000_000_000); // 1,000 pdUSD
        vm.prank(user);
        token.approve(address(sweeper), type(uint256).max);
    }

    function testOmniCallbackAcceptsReactiveContractAddress() public {
        uint256 userBefore = token.balanceOf(user);
        vm.expectEmit(true, false, false, true, address(sweeper));
        emit PaydaySweeperOmni.Swept(user, 10_000_000);
        vm.prank(BASE_SEPOLIA_PROXY);
        sweeper.callback(REACTIVE_CONTRACT, user, 10_000_000);
        assertEq(token.balanceOf(user), userBefore - 10_000_000);
        assertEq(token.balanceOf(address(vault)), 10_000_000);
        assertEq(vault.balances(user), 10_000_000);
    }

    function testOmniCallbackRejectsWrongSender() public {
        vm.prank(BASE_SEPOLIA_PROXY);
        vm.expectRevert(
            abi.encodeWithSelector(
                AbstractCallback.CallbackNotAuthorized.selector, address(0xDEAD), REACTIVE_CONTRACT
            )
        );
        sweeper.callback(address(0xDEAD), user, 10_000_000);
    }

    function testOmniCallbackRejectsLegacyRvmId() public {
        // The exact first argument the deployed legacy sweeper requires must
        // NOT open the Omni sweeper: Omni delivers the contract address.
        vm.prank(BASE_SEPOLIA_PROXY);
        vm.expectRevert(
            abi.encodeWithSelector(
                AbstractCallback.CallbackNotAuthorized.selector, LEGACY_RVM_ID, REACTIVE_CONTRACT
            )
        );
        sweeper.callback(LEGACY_RVM_ID, user, 10_000_000);
    }

    function testOmniCallbackRejectsNonProxyCaller() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, user, BASE_SEPOLIA_PROXY));
        sweeper.callback(REACTIVE_CONTRACT, user, 10_000_000);
    }

    function testOmniCallbackRejectsZeroAmount() public {
        vm.prank(BASE_SEPOLIA_PROXY);
        vm.expectRevert("zero amount");
        sweeper.callback(REACTIVE_CONTRACT, user, 0);
    }
}
