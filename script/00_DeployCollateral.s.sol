// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {BaseScript} from "./base/BaseScript.sol";
import {SimpleERC20} from "../src/SimpleERC20.sol";

/// @notice Deploy collateral token and mint initial supply
contract DeployCollateralScript is BaseScript {
    function run() public {
        string memory name = _envOr("COLLATERAL_NAME", string("TestUSD"));
        string memory symbol = _envOr("COLLATERAL_SYMBOL", string("TUSD"));
        uint256 mintAmount = _envOr("COLLATERAL_MINT_AMOUNT", uint256(1_000_000e6));

        vm.startBroadcast();
        SimpleERC20 collateral = new SimpleERC20(name, symbol);
        collateral.mint(deployerAddress, mintAmount);
        vm.stopBroadcast();

        console.log("Collateral deployed:", address(collateral));

        // Save to JSON
        string memory obj = "deploy";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "deployer", deployerAddress);
        string memory contracts = "contracts";
        string memory contractsJson = vm.serializeAddress(contracts, "collateral", address(collateral));
        string memory result = vm.serializeString(obj, "contracts", contractsJson);
        _saveDeployment(result);
    }
}
