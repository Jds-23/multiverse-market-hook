// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {MultiverseMarkets} from "../src/MultiverseMarkets.sol";
import {MultiverseHook} from "../src/MultiverseHook.sol";

/// @notice Deploy MultiverseMarkets factory + Hook via CREATE2
contract DeployCoreScript is BaseScript {
    function run() public {
        // Load collateral from previous deployment
        string memory json = _loadDeployment();
        address collateral = _readAddress(json, ".contracts.collateral");
        console.log("Collateral:", collateral);

        // Hook flags
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        vm.startBroadcast(deployerPrivateKey);

        // Deploy MultiverseMarkets
        MultiverseMarkets conditionalMarkets = new MultiverseMarkets(poolManager);
        console.log("MultiverseMarkets:", address(conditionalMarkets));

        // Mine hook address
        bytes memory constructorArgs = abi.encode(poolManager, conditionalMarkets);
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_FACTORY, flags, type(MultiverseHook).creationCode, constructorArgs
        );

        // Deploy hook via CREATE2
        MultiverseHook hook = new MultiverseHook{salt: salt}(poolManager, conditionalMarkets);
        require(address(hook) == hookAddress, "Hook address mismatch");
        console.log("Hook:", address(hook));

        // Wire hook to factory
        conditionalMarkets.setHook(hook);

        vm.stopBroadcast();

        // Update JSON — merge into existing deployment
        string memory obj = "deploy";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "deployer", deployerAddress);
        string memory contracts = "contracts";
        vm.serializeAddress(contracts, "collateral", collateral);
        vm.serializeAddress(contracts, "factory", address(conditionalMarkets));
        vm.serializeAddress(contracts, "hook", address(hook));
        vm.serializeAddress(contracts, "poolManager", address(poolManager));
        vm.serializeAddress(contracts, "swapRouter", address(swapRouter));
        string memory contractsJson = vm.serializeAddress(contracts, "permit2", address(permit2));
        string memory result = vm.serializeString(obj, "contracts", contractsJson);
        _saveDeployment(result);
    }
}
