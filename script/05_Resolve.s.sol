// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {MultiverseMarkets} from "../src/MultiverseMarkets.sol";

/// @notice Resolve a market — declare winner (YES or NO)
contract ResolveScript is BaseScript {
    function run() public {
        string memory json = _loadDeployment();
        address factory = _readAddress(json, ".contracts.factory");

        string memory universeStr = _envOr("UNIVERSE_ID", string("test-market-1"));
        bytes32 universeId = keccak256(bytes(universeStr));
        string memory winnerSide = _envOr("WINNER_SIDE", string("YES"));

        (, address yesToken, address noToken) = MultiverseMarkets(factory).universes(universeId);
        address winner = keccak256(bytes(winnerSide)) == keccak256("YES") ? yesToken : noToken;

        console.log("Resolving market:", universeStr);
        console.log("Winner:", winnerSide, winner);

        vm.startBroadcast(deployerPrivateKey);
        MultiverseMarkets(factory).resolve(universeId, winner);
        vm.stopBroadcast();

        console.log("Market resolved");
    }
}
