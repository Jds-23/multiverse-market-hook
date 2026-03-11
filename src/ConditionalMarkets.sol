// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {OutcomeToken} from "./OutcomeToken.sol";
import {IMarketHook} from "./IMarketHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Factory + escrow for binary outcome prediction markets.
/// Deploys YES/NO tokens per condition, handles split/merge/redeem lifecycle.
contract ConditionalMarkets {
    // ── Data Model ──────────────────────────────────────────────────────

    struct Condition {
        address collateralToken;
        address yesToken;
        address noToken;
    }

    IPoolManager public immutable poolManager;

    IMarketHook public hook;
    bool public hookSet;

    mapping(bytes32 => Condition) public conditions;
    mapping(bytes32 => mapping(address => uint256)) public collateralBalances;
    mapping(bytes32 => address) public resolved;
    mapping(address => bytes32) public tokenCondition;

    // ── Errors ──────────────────────────────────────────────────────────

    error InvalidConditionId();
    error ConditionAlreadyExists(bytes32 conditionId);
    error InvalidWinner(address winner);
    error ConditionAlreadyResolved();
    error ConditionNotResolved(bytes32 conditionId);
    error TokenNotWinner(address token);
    error UnknownToken(address token);
    error ZeroAmount();
    error InsufficientBalance(address token, uint256 requested, uint256 available);
    error HookAlreadySet();
    error HookNotSet();

    // ── Events ──────────────────────────────────────────────────────────

    event ConditionCreated(
        bytes32 indexed conditionId, address collateralToken, address yesToken, address noToken
    );
    event Split(bytes32 indexed conditionId, address indexed sender, uint256 amount);
    event Merged(bytes32 indexed conditionId, address indexed sender, uint256 amount);
    event Resolved(bytes32 indexed conditionId, address indexed winner);
    event Redeemed(
        bytes32 indexed conditionId, address indexed sender, address indexed token, uint256 amount
    );

    // ── Modifiers ───────────────────────────────────────────────────────

    modifier notResolved(bytes32 conditionId) {
        if (resolved[conditionId] != address(0)) revert ConditionAlreadyResolved();
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────────

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    // ── External Functions ──────────────────────────────────────────────

    function setHook(IMarketHook _hook) external {
        if (hookSet) revert HookAlreadySet();
        hook = _hook;
        hookSet = true;
    }

    function createMarket(bytes32 conditionId, address collateralToken, uint256 amount) external {
        if (!hookSet) revert HookNotSet();
        if (conditionId == bytes32(0)) revert InvalidConditionId();
        if (conditions[conditionId].collateralToken != address(0)) {
            revert ConditionAlreadyExists(conditionId);
        }

        // Deploy YES/NO tokens
        string memory hexId = _bytes32ToHexString(conditionId);
        OutcomeToken yesToken = new OutcomeToken(string.concat("YES-", hexId), "YES");
        OutcomeToken noToken = new OutcomeToken(string.concat("NO-", hexId), "NO");

        conditions[conditionId] = Condition({
            collateralToken: collateralToken,
            yesToken: address(yesToken),
            noToken: address(noToken)
        });

        tokenCondition[address(yesToken)] = conditionId;
        tokenCondition[address(noToken)] = conditionId;

        emit ConditionCreated(conditionId, collateralToken, address(yesToken), address(noToken));

        // Transfer collateral from caller to hook
        SafeTransferLib.safeTransferFrom(collateralToken, msg.sender, address(hook), amount);

        // Callback: hook splits collateral into YES/NO
        hook.onCreateMarket(conditionId, collateralToken, address(yesToken), address(noToken), amount);

        // Initialize 3 pools
        uint160 sqrtPrice1_1 = TickMath.getSqrtPriceAtTick(0);
        poolManager.initialize(_makePoolKey(Currency.wrap(collateralToken), Currency.wrap(address(yesToken))), sqrtPrice1_1);
        poolManager.initialize(_makePoolKey(Currency.wrap(collateralToken), Currency.wrap(address(noToken))), sqrtPrice1_1);
        poolManager.initialize(_makePoolKey(Currency.wrap(address(yesToken)), Currency.wrap(address(noToken))), sqrtPrice1_1);
    }

    function split(bytes32 conditionId, uint256 amount) external notResolved(conditionId) {
        Condition storage c = conditions[conditionId];

        SafeTransferLib.safeTransferFrom(c.collateralToken, msg.sender, address(this), amount);
        collateralBalances[conditionId][c.collateralToken] += amount;

        OutcomeToken(c.yesToken).mint(msg.sender, amount);
        OutcomeToken(c.noToken).mint(msg.sender, amount);

        emit Split(conditionId, msg.sender, amount);
    }

    function merge(bytes32 conditionId, uint256 amount) external notResolved(conditionId) {
        Condition storage c = conditions[conditionId];

        OutcomeToken(c.yesToken).burn(msg.sender, amount);
        OutcomeToken(c.noToken).burn(msg.sender, amount);

        collateralBalances[conditionId][c.collateralToken] -= amount;
        SafeTransferLib.safeTransfer(c.collateralToken, msg.sender, amount);

        emit Merged(conditionId, msg.sender, amount);
    }

    function resolve(bytes32 conditionId, address winner) external {
        if (resolved[conditionId] != address(0)) revert ConditionAlreadyResolved();

        Condition storage c = conditions[conditionId];
        if (winner != c.yesToken && winner != c.noToken) revert InvalidWinner(winner);

        resolved[conditionId] = winner;

        emit Resolved(conditionId, winner);
    }

    function redeem(address token, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        bytes32 conditionId = tokenCondition[token];
        if (conditionId == bytes32(0)) revert UnknownToken(token);

        address winner = resolved[conditionId];
        if (winner == address(0)) revert ConditionNotResolved(conditionId);
        if (token != winner) revert TokenNotWinner(token);

        uint256 balance = ERC20(token).balanceOf(msg.sender);
        if (balance < amount) revert InsufficientBalance(token, amount, balance);

        Condition storage c = conditions[conditionId];

        OutcomeToken(token).burn(msg.sender, amount);
        collateralBalances[conditionId][c.collateralToken] -= amount;
        SafeTransferLib.safeTransfer(c.collateralToken, msg.sender, amount);

        emit Redeemed(conditionId, msg.sender, token, amount);
    }

    // ── Internal Helpers ────────────────────────────────────────────────

    function _makePoolKey(Currency a, Currency b) internal view returns (PoolKey memory) {
        (Currency c0, Currency c1) = a < b ? (a, b) : (b, a);
        return PoolKey(c0, c1, 0, 60, IHooks(address(hook)));
    }

    function _bytes32ToHexString(bytes32 value) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(66); // "0x" + 64 hex chars
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 32; i++) {
            str[2 + i * 2] = alphabet[uint8(value[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(value[i] & 0x0f)];
        }
        return string(str);
    }
}
