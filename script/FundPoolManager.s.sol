// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {SimpleERC20} from "../src/SimpleERC20.sol";

/// @notice Fund the PoolManager with collateral tokens (mint if deployer is owner, else transfer)
contract FundPoolManagerScript is BaseScript {
    function run() public {
        string memory json = _loadDeployment();
        address collateral = _readAddress(json, ".contracts.collateral");

        uint256 amount = _envOr("FUND_AMOUNT", uint256(1_000e6));

        console.log("Collateral:", collateral);
        console.log("PoolManager:", address(poolManager));
        console.log("Amount:", amount);

        vm.startBroadcast(deployerPrivateKey);

        // Mint fresh tokens to the PoolManager directly
        SimpleERC20(payable(collateral)).mint(address(poolManager), amount);

        vm.stopBroadcast();

        uint256 bal = IERC20(collateral).balanceOf(address(poolManager));
        console.log("PoolManager collateral balance:", bal);
    }
}
