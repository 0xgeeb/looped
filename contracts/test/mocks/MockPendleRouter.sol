// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPendleRouter} from "../../src/interfaces/IPendleRouter.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Mock Pendle router for testing. Swaps USDC ↔ PT at a configurable rate.
contract MockPendleRouter is IPendleRouter {
    // ptRate: how many PT (18 dec) you get per 1 USDC (6 dec). Default 1:1 in value terms.
    // Since PT trades at discount, ptRate > 1e12 means discount.
    // E.g. ptRate = 1.05e12 means 1 USDC buys 1.05e12 PT-units worth (5% discount)
    uint256 public ptPerUsdc = 1e12; // 1 USDC (6 dec) → 1e12 PT (18 dec) = 1:1 value

    address public ptToken;
    address public usdcToken;

    function configure(address pt_, address usdc_, uint256 ptPerUsdc_) external {
        ptToken = pt_;
        usdcToken = usdc_;
        ptPerUsdc = ptPerUsdc_;
    }

    function swapExactTokenForPt(
        address receiver,
        address,
        uint256,
        ApproxParams calldata,
        TokenInput calldata input
    ) external payable returns (uint256 netPtOut, uint256 netSyFee) {
        MockERC20(input.tokenIn).transferFrom(msg.sender, address(this), input.netTokenIn);
        // Convert USDC (6 dec) to PT (18 dec)
        netPtOut = input.netTokenIn * ptPerUsdc;
        MockERC20(ptToken).mint(receiver, netPtOut);
        netSyFee = 0;
    }

    function swapExactPtForToken(
        address receiver,
        address,
        uint256 exactPtIn,
        TokenOutput calldata,
        uint256
    ) external returns (uint256 netTokenOut, uint256 netSyFee) {
        MockERC20(ptToken).transferFrom(msg.sender, address(this), exactPtIn);
        // Convert PT (18 dec) to USDC (6 dec)
        netTokenOut = exactPtIn / ptPerUsdc;
        MockERC20(usdcToken).mint(receiver, netTokenOut);
        netSyFee = 0;
    }

    function redeemPyToToken(
        address receiver,
        address,
        uint256 netPyIn,
        TokenOutput calldata
    ) external returns (uint256 netTokenOut) {
        MockERC20(ptToken).transferFrom(msg.sender, address(this), netPyIn);
        // At maturity PT redeems 1:1 to underlying (adjusted for decimals)
        netTokenOut = netPyIn / 1e12;
        MockERC20(usdcToken).mint(receiver, netTokenOut);
    }
}
