// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IMarketHook {
    function onCreateMarket(
        bytes32 conditionId,
        address collateral,
        address yesToken,
        address noToken,
        uint256 amount
    ) external;
}
