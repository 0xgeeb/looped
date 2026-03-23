// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISwapRouter} from "../../src/interfaces/ISwapRouter.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice 1:1 swap router for testing. Mints output token, burns input token.
contract MockSwapRouter is ISwapRouter {
    // Optional: set a price ratio (scaled 1e18). Default 1:1.
    mapping(bytes32 => uint256) public priceRatio;

    function setPrice(address tokenIn, address tokenOut, uint256 ratio) external {
        priceRatio[keccak256(abi.encode(tokenIn, tokenOut))] = ratio;
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external returns (uint256 amountOut) {
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        uint256 ratio = priceRatio[keccak256(abi.encode(tokenIn, tokenOut))];
        if (ratio == 0) ratio = 1e18; // default 1:1

        amountOut = amountIn * ratio / 1e18;
        require(amountOut >= minAmountOut, "slippage");

        MockERC20(tokenOut).mint(msg.sender, amountOut);
    }
}
