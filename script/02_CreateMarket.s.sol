// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {ConditionalMarkets} from "../src/ConditionalMarkets.sol";

/// @notice Create a prediction market: deploys outcome tokens, funds LMSR, initializes pools
contract CreateMarketScript is BaseScript {
    function run() public {
        string memory json = _loadDeployment();
        address collateral = _readAddress(json, ".contracts.collateral");
        address factory = _readAddress(json, ".contracts.factory");
        address hook = _readAddress(json, ".contracts.hook");

        string memory conditionStr = _envOr("CONDITION_ID", string("test-market-1"));
        bytes32 conditionId = keccak256(bytes(conditionStr));
        uint256 fundingAmount = _envOr("FUNDING_AMOUNT", uint256(10_000e6));

        console.log("Creating market for condition:", conditionStr);

        vm.startBroadcast();
        IERC20(collateral).approve(factory, fundingAmount);
        ConditionalMarkets(factory).createMarket(conditionId, collateral, fundingAmount);
        vm.stopBroadcast();

        _saveMarketJson(factory, hook, conditionId, fundingAmount);
    }

    function _saveMarketJson(address factory, address hook, bytes32 conditionId, uint256 fundingAmount) internal {
        (address colAddr, address yesToken, address noToken) = ConditionalMarkets(factory).conditions(conditionId);
        console.log("YES:", yesToken);
        console.log("NO:", noToken);

        string memory poolKeysJson = _buildPoolKeysJson(colAddr, yesToken, noToken, hook);

        string memory market = "market";
        vm.serializeAddress(market, "yesToken", yesToken);
        vm.serializeAddress(market, "noToken", noToken);
        vm.serializeUint(market, "funding", fundingAmount);
        string memory marketJson = vm.serializeString(market, "poolKeys", poolKeysJson);

        string memory path = string.concat(".markets.", vm.toString(conditionId));
        vm.writeJson(marketJson, deploymentPath, path);
    }

    function _buildPoolKeysJson(address colAddr, address yesToken, address noToken, address hook) internal returns (string memory) {
        string memory colYesJson = _serializePoolKey(
            "colYes", _makePoolKey(Currency.wrap(colAddr), Currency.wrap(yesToken), IHooks(hook))
        );
        string memory colNoJson = _serializePoolKey(
            "colNo", _makePoolKey(Currency.wrap(colAddr), Currency.wrap(noToken), IHooks(hook))
        );
        string memory poolKeys = "poolKeys";
        vm.serializeString(poolKeys, "colYes", colYesJson);
        return vm.serializeString(poolKeys, "colNo", colNoJson);
    }

    function _serializePoolKey(string memory key, PoolKey memory pk) internal returns (string memory) {
        vm.serializeAddress(key, "currency0", Currency.unwrap(pk.currency0));
        vm.serializeAddress(key, "currency1", Currency.unwrap(pk.currency1));
        vm.serializeUint(key, "fee", pk.fee);
        return vm.serializeInt(key, "tickSpacing", int256(pk.tickSpacing));
    }
}
