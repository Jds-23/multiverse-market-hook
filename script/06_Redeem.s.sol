// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {MultiverseMarkets} from "../src/MultiverseMarkets.sol";

/// @notice Redeem winning tokens for collateral after market resolution
contract RedeemScript is BaseScript {
    function run() public {
        string memory json = _loadDeployment();
        address factory = _readAddress(json, ".contracts.factory");

        string memory universeStr = _envOr("UNIVERSE_ID", string("test-market-1"));
        bytes32 universeId = keccak256(bytes(universeStr));

        // Get the resolved winner token
        address winner = MultiverseMarkets(factory).resolved(universeId);
        require(winner != address(0), "Market not resolved");

        uint256 balance = IERC20(winner).balanceOf(deployerAddress);
        require(balance > 0, "No winning tokens to redeem");

        console.log("Redeeming", balance, "winning tokens");

        vm.startBroadcast(deployerPrivateKey);

        IERC20(winner).approve(factory, balance);
        MultiverseMarkets(factory).redeem(winner, balance);

        vm.stopBroadcast();

        console.log("Redeemed for collateral");
    }
}
