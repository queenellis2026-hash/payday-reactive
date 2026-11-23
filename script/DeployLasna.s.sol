// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { PaydayReactive } from "../src/PaydayReactive.sol";

/// @notice Deploys the Lasna side: PaydayReactive.
/// @dev Run AFTER DeployBase.s.sol, with TOKEN_ADDRESS and SWEEPER_ADDRESS from it.
///      forge script script/DeployLasna.s.sol --rpc-url $LASNA_RPC --broadcast
///      The deployer key MUST match the one used for DeployBase.s.sol.
contract DeployLasna is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address token = vm.envAddress("TOKEN_ADDRESS");
        address sweeper = vm.envAddress("SWEEPER_ADDRESS");
        vm.startBroadcast(deployerKey);

        PaydayReactive reactive = new PaydayReactive(token, sweeper);

        vm.stopBroadcast();
        console.log("PaydayReactive:", address(reactive));
        console.log("Fund it with lREACT (faucet) so it can pay for react() calls.");
    }
}
