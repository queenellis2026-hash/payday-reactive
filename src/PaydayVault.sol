// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Payday — per-user savings vault (Base Sepolia)
/// @notice Holds swept savings per user. Only the sweeper can deposit; the user
///         withdraws their own balance any time.
contract PaydayVault {
    IERC20 public immutable token;
    address public immutable owner;
    address public sweeper;
    bool public sweeperSet;

    mapping(address => uint256) public balances;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event SweeperSet(address indexed sweeper);

    modifier onlySweeper() {
        require(msg.sender == sweeper, "sweeper only");
        _;
    }

    constructor(address _token) {
        require(_token != address(0), "zero address");
        token = IERC20(_token);
        owner = msg.sender;
    }

    /// @notice One-time wiring: set the sweeper after it is deployed.
    function setSweeper(address _sweeper) external {
        require(msg.sender == owner, "owner only");
        require(!sweeperSet, "sweeper already set");
        require(_sweeper != address(0), "zero address");
        sweeper = _sweeper;
        sweeperSet = true;
        emit SweeperSet(_sweeper);
    }

    function depositFor(address user, uint256 amount) external onlySweeper {
        require(amount > 0, "zero amount");
        require(token.transferFrom(msg.sender, address(this), amount), "deposit failed");
        balances[user] += amount;
        emit Deposited(user, amount);
    }

    function withdraw(uint256 amount) external {
        require(amount > 0 && balances[msg.sender] >= amount, "insufficient savings");
        balances[msg.sender] -= amount;
        require(token.transfer(msg.sender, amount), "withdraw failed");
        emit Withdrawn(msg.sender, amount);
    }
}
