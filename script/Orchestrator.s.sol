// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {SimpleERC20} from "../src/SimpleERC20.sol";
import {ConditionalMarkets} from "../src/ConditionalMarkets.sol";
import {ConditionalLMSRMarketHook} from "../src/ConditionalLMSRMarketHook.sol";

/// @notice Combines phases 0-2: deploy collateral, core, and create market in one broadcast
contract OrchestratorScript is BaseScript {
    function run() public {
        bool runPhase0 = _envOr("RUN_PHASE_0", true);
        bool runPhase1 = _envOr("RUN_PHASE_1", true);
        bool runPhase2 = _envOr("RUN_PHASE_2", true);

        address collateral;
        address factory;
        address hook;

        vm.startBroadcast(deployerPrivateKey);

        if (runPhase0) {
            collateral = _deployCollateral();
        } else {
            collateral = _readAddress(_loadDeployment(), ".contracts.collateral");
        }

        if (runPhase1) {
            (factory, hook) = _deployCore();
        } else {
            string memory json = _loadDeployment();
            factory = _readAddress(json, ".contracts.factory");
            hook = _readAddress(json, ".contracts.hook");
        }

        if (runPhase2) {
            _createMarket(collateral, factory);
        }

        vm.stopBroadcast();

        _saveFullDeployment(collateral, factory, hook);
        if (runPhase2) {
            _saveMarketData(factory, hook);
        }
    }

    function _deployCollateral() internal returns (address) {
        string memory name = _envOr("COLLATERAL_NAME", string("TestUSD"));
        string memory symbol = _envOr("COLLATERAL_SYMBOL", string("TUSD"));
        uint256 mintAmount = _envOr("COLLATERAL_MINT_AMOUNT", uint256(1_000_000e6));

        SimpleERC20 col = new SimpleERC20(name, symbol);
        col.mint(deployerAddress, mintAmount);
        console.log("Collateral:", address(col));
        return address(col);
    }

    function _deployCore() internal returns (address factory, address hook) {
        ConditionalMarkets cm = new ConditionalMarkets(poolManager);
        factory = address(cm);
        console.log("ConditionalMarkets:", factory);

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(poolManager, cm);
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_FACTORY, flags, type(ConditionalLMSRMarketHook).creationCode, constructorArgs
        );

        ConditionalLMSRMarketHook h = new ConditionalLMSRMarketHook{salt: salt}(poolManager, cm);
        require(address(h) == hookAddress, "Hook address mismatch");
        hook = address(h);
        console.log("Hook:", hook);

        cm.setHook(h);
    }

    function _createMarket(address collateral, address factory) internal {
        string memory conditionStr = _envOr("CONDITION_ID", string("test-market-1"));
        bytes32 conditionId = keccak256(bytes(conditionStr));
        uint256 fundingAmount = _envOr("FUNDING_AMOUNT", uint256(10_000e6));

        IERC20(collateral).approve(factory, fundingAmount);
        ConditionalMarkets(factory).createMarket(conditionId, collateral, fundingAmount);

        (, address yesToken, address noToken) = ConditionalMarkets(factory).conditions(conditionId);
        console.log("Market created. YES:", yesToken, "NO:", noToken);
    }

    function _saveFullDeployment(address collateral, address factory, address hook) internal {
        string memory obj = "deploy";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "deployer", deployerAddress);

        string memory c = "contracts";
        vm.serializeAddress(c, "collateral", collateral);
        vm.serializeAddress(c, "factory", factory);
        vm.serializeAddress(c, "hook", hook);
        vm.serializeAddress(c, "poolManager", address(poolManager));
        vm.serializeAddress(c, "swapRouter", address(swapRouter));
        string memory cJson = vm.serializeAddress(c, "permit2", address(permit2));

        string memory result = vm.serializeString(obj, "contracts", cJson);
        _saveDeployment(result);
    }

    function _saveMarketData(address factory, address hook) internal {
        string memory conditionStr = _envOr("CONDITION_ID", string("test-market-1"));
        bytes32 conditionId = keccak256(bytes(conditionStr));
        uint256 fundingAmount = _envOr("FUNDING_AMOUNT", uint256(10_000e6));

        (address colAddr, address yesToken, address noToken) = ConditionalMarkets(factory).conditions(conditionId);

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
