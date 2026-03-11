// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {ConditionalMarkets} from "../src/ConditionalMarkets.sol";

/// @notice Resolve a market — declare winner (YES or NO)
contract ResolveScript is BaseScript {
    function run() public {
        string memory json = _loadDeployment();
        address factory = _readAddress(json, ".contracts.factory");

        string memory conditionStr = _envOr("CONDITION_ID", string("test-market-1"));
        bytes32 conditionId = keccak256(bytes(conditionStr));
        string memory winnerSide = _envOr("WINNER_SIDE", string("YES"));

        (, address yesToken, address noToken) = ConditionalMarkets(factory).conditions(conditionId);
        address winner = keccak256(bytes(winnerSide)) == keccak256("YES") ? yesToken : noToken;

        console.log("Resolving market:", conditionStr);
        console.log("Winner:", winnerSide, winner);

        vm.startBroadcast();
        ConditionalMarkets(factory).resolve(conditionId, winner);
        vm.stopBroadcast();

        console.log("Market resolved");
    }
}
