// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { MockUSDC } from "../src/MockUSDC.sol";
import { PaydayVault } from "../src/PaydayVault.sol";
import { PaydaySweeper } from "../src/PaydaySweeper.sol";

/// @notice Deploys the Base Sepolia side: MockUSDC, PaydayVault, PaydaySweeper.
/// @dev Run with: forge script script/DeployBase.s.sol --rpc-url $BASE_SEPOLIA_RPC --broadcast
///      The deployer key MUST be the same one used for DeployLasna.s.sol
///      (the sweeper checks the reactive contract's deployer id).
contract DeployBase is Script {
    address internal constant BASE_SEPOLIA_CALLBACK_PROXY =
        0x476F44b11F5C942c58f4c8E3d0300E5710743585;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        MockUSDC token = new MockUSDC();
        PaydayVault vault = new PaydayVault(address(token));
        PaydaySweeper sweeper =
            new PaydaySweeper(BASE_SEPOLIA_CALLBACK_PROXY, address(token), address(vault));
        vault.setSweeper(address(sweeper));

        vm.stopBroadcast();
        console.log("MockUSDC:", address(token));
        console.log("PaydayVault:", address(vault));
        console.log("PaydaySweeper:", address(sweeper));
    }
}
