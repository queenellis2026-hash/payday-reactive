// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Demo-only 6-decimal stablecoin for the Base Sepolia demo. NOT real USDC.
contract MockUSDC is ERC20 {
    constructor() ERC20("Payday Demo USD", "pdUSD") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
