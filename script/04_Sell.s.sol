// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {ConditionalMarkets} from "../src/ConditionalMarkets.sol";

/// @notice Sell outcome tokens back for collateral via swapRouter
contract SellScript is BaseScript {
    function run() public {
        string memory json = _loadDeployment();
        address collateral = _readAddress(json, ".contracts.collateral");
        address factory = _readAddress(json, ".contracts.factory");
        address hook = _readAddress(json, ".contracts.hook");

        string memory conditionStr = _envOr("CONDITION_ID", string("test-market-1"));
        bytes32 conditionId = keccak256(bytes(conditionStr));
        string memory side = _envOr("OUTCOME_SIDE", string("YES"));
        uint256 amountIn = _envOr("SWAP_AMOUNT", uint256(100e6));

        (, address yesToken, address noToken) = ConditionalMarkets(factory).conditions(conditionId);
        address outcomeToken = keccak256(bytes(side)) == keccak256("YES") ? yesToken : noToken;

        Currency colCur = Currency.wrap(collateral);
        Currency outCur = Currency.wrap(outcomeToken);
        PoolKey memory poolKey = _makePoolKey(colCur, outCur, IHooks(hook));
        // Sell: outcome → collateral (reverse of buy)
        bool zeroForOne = outcomeToken < collateral;

        console.log("Selling", side, "tokens");
        console.log("Amount in:", amountIn);

        vm.startBroadcast(deployerPrivateKey);

        _approveRouter(IERC20(outcomeToken));

        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: new bytes(0),
            receiver: deployerAddress,
            deadline: block.timestamp + 300
        });

        vm.stopBroadcast();

        console.log("Sell complete");
    }
}
