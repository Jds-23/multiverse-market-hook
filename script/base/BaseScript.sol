// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {Deployers} from "test/utils/Deployers.sol";

/// @notice Shared base for deployment scripts. Handles env, JSON artifacts, V4 infra.
contract BaseScript is Script, Deployers {
    address immutable deployerAddress;
    string deploymentPath;

    constructor() {
        deployArtifacts();
        deployerAddress = _getDeployer();
        deploymentPath = vm.envOr("DEPLOYMENT_FILE", string("deployments/deployment.json"));
    }

    function _etch(address target, bytes memory bytecode) internal override {
        if (block.chainid == 31337) {
            vm.rpc("anvil_setCode", string.concat('["', vm.toString(target), '",', '"', vm.toString(bytecode), '"]'));
        } else {
            revert("Unsupported etch on this network");
        }
    }

    function _getDeployer() internal returns (address) {
        address[] memory wallets = vm.getWallets();
        return wallets.length > 0 ? wallets[0] : msg.sender;
    }

    // ── JSON Helpers ─────────────────────────────────────────────────────

    function _loadDeployment() internal view returns (string memory) {
        return vm.readFile(deploymentPath);
    }

    function _readAddress(string memory json, string memory key) internal pure returns (address) {
        return abi.decode(vm.parseJson(json, key), (address));
    }

    function _saveDeployment(string memory json) internal {
        vm.writeJson(json, deploymentPath);
    }

    // ── Env Helpers ──────────────────────────────────────────────────────

    function _envOr(string memory key, string memory fallback_) internal view returns (string memory) {
        return vm.envOr(key, fallback_);
    }

    function _envOr(string memory key, uint256 fallback_) internal view returns (uint256) {
        return vm.envOr(key, fallback_);
    }

    function _envOr(string memory key, bool fallback_) internal view returns (bool) {
        return vm.envOr(key, fallback_);
    }

    // ── Pool Key Helper ──────────────────────────────────────────────────

    function _makePoolKey(Currency a, Currency b, IHooks hook) internal pure returns (PoolKey memory) {
        (Currency c0, Currency c1) = a < b ? (a, b) : (b, a);
        return PoolKey(c0, c1, 0, 60, hook);
    }

    // ── Approval Helper ──────────────────────────────────────────────────

    function _approveRouter(IERC20 token) internal {
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token), address(swapRouter), type(uint160).max, type(uint48).max);
    }
}
