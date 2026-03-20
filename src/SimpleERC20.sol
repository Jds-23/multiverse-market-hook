// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract SimpleERC20 is ERC20, Ownable {
    string internal _name;
    string internal _symbol;
    uint256 internal _mintCap;

    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
        _mintCap = type(uint128).max;
        _initializeOwner(msg.sender);
    }

    function name() public view virtual override returns (string memory) {
        return _name;
    }

    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    function decimals() public view virtual override returns (uint8) {
        return 6;
    }

    function setMintCap(uint256 mintCap) public virtual onlyOwner {
        _mintCap = mintCap;
    }

    function mint(address recipient, uint256 value) public virtual onlyOwner {
        require(value < _mintCap, "Mint cap exceeded");
        _mint(recipient, value);
    }

    fallback() external payable {}
    receive() external payable {}
}