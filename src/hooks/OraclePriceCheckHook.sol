// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseHook} from "@uniswap/v4-core/contracts/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {IChainlinkAggregator} from "./interfaces/IChainlinkAggregator.sol"; // Simple Chainlink interface
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol"; // For percentage calcs

// Custom Error
error PriceDeviationTooHigh(uint256 poolPriceX96, uint256 oraclePriceX96, uint256 maxDeviationBps);

// Simple Chainlink Interface (you might need a more specific one depending on the feed)
interface IChainlinkAggregator {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer, // Price
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
    function decimals() external view returns (uint8);
}

contract OraclePriceCheckHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using FixedPointMathLib for uint256;

    // Configuration
    IChainlinkAggregator public immutable priceFeed; // Chainlink Feed for token1/token0 price (e.g., ETH/USD)
    uint8 public immutable priceFeedDecimals;       // Decimals of the oracle feed
    uint256 public constant MAX_PRICE_DEVIATION_BPS = 200; // Configurable: 2% max deviation allowed (200 / 10000)
    bool public immutable isToken0PriceFeed; // True if feed is Token0/Token1, False if Token1/Token0

    // Precision constant for price conversion
    uint256 internal constant PRICE_PRECISION = 1e18; // Standard 18 decimals for comparison


    constructor(
        IPoolManager _poolManager,
        address _priceFeedAddress,
        bool _isToken0PriceFeed // Is the feed price T0/T1 (true) or T1/T0 (false)?
    ) BaseHook(_poolManager) {
        priceFeed = IChainlinkAggregator(_priceFeedAddress);
        priceFeedDecimals = priceFeed.decimals();
        isToken0PriceFeed = _isToken0PriceFeed;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions) {
        return Hooks.Permissions({
            beforeInitialize: false, afterInitialize: false,
            beforeModifyPosition: false, afterModifyPosition: false,
            beforeSwap: true, // Implement beforeSwap
            afterSwap: false,
            beforeDonate: false, afterDonate: false
        });
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4) {
        PoolId poolId = key.toId();
        (int24 currentTick,,,,,,) = poolManager.getSlot0(poolId);

        // --- Get Pool Price ---
        // Price is sqrt(token1/token0) * 2^96
        uint160 sqrtPoolPriceX96 = TickMath.getSqrtRatioAtTick(currentTick);
        // Calculate pool price (Token1 per Token0) with PRICE_PRECISION decimals
        // (sqrtPriceX96 / 2^96)^2 * 1e18 = (sqrtPriceX96^2 / 2^192) * 1e18
        uint256 poolPriceX192 = uint256(sqrtPoolPriceX96) * uint256(sqrtPoolPriceX96); // Price is X96 squared = X192
        // Adjust precision (dividing by 2^192 can be tricky, scale oracle price instead)

        // --- Get Oracle Price ---
        (, int256 oracleAnswer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        require(updatedAt >= block.timestamp - 1 hours, "Oracle price stale"); // Check freshness
        require(oracleAnswer > 0, "Invalid oracle price");

        // --- Normalize Prices for Comparison (bring both to PRICE_PRECISION, representing T1/T0) ---
        uint256 oraclePriceT1perT0_Precise;
        uint256 poolPriceT1perT0_Precise;

        // Convert Pool Price (sqrtPrice^2 / 2^192) to have PRICE_PRECISION (1e18) decimals
        // Simplified: poolPrice * 1e18 = (poolPriceX192 * 1e18) >> 192
        poolPriceT1perT0_Precise = (poolPriceX192 * PRICE_PRECISION) >> 192;


        // Convert Oracle Price to represent T1/T0 with PRICE_PRECISION decimals
        if (isToken0PriceFeed) {
            // Oracle gives T0/T1, we need 1 / (T0/T1) = T1/T0
            // oraclePriceT1perT0 = (1 / oracleAnswer) * 10^oracleDecimals
            // To avoid division early: (1 * 10^oracleDecimals * PRICE_PRECISION * PRICE_PRECISION) / (oracleAnswer * PRICE_PRECISION)
            // Scale numerator first to maintain precision during division
             uint256 numerator = uint256(10**priceFeedDecimals) * PRICE_PRECISION * PRICE_PRECISION;
             oraclePriceT1perT0_Precise = numerator / (uint256(oracleAnswer) * PRICE_PRECISION);

        } else {
            // Oracle already gives T1/T0, just adjust decimals
             oraclePriceT1perT0_Precise = (uint256(oracleAnswer) * PRICE_PRECISION) / (10**priceFeedDecimals);
        }


        // --- Compare Prices ---
        uint256 priceDiff = poolPriceT1perT0_Precise > oraclePriceT1perT0_Precise
            ? poolPriceT1perT0_Precise - oraclePriceT1perT0_Precise
            : oraclePriceT1perT0_Precise - poolPriceT1perT0_Precise;

        // Calculate deviation percentage (BPS) relative to the oracle price
        // deviationBps = (priceDiff * 10000) / oraclePrice
        uint256 deviationBps = (priceDiff * 10000) / oraclePriceT1perT0_Precise;

        if (deviationBps > MAX_PRICE_DEVIATION_BPS) {
            revert PriceDeviationTooHigh(poolPriceT1perT0_Precise, oraclePriceT1perT0_Precise, MAX_PRICE_DEVIATION_BPS);
        }

        return OraclePriceCheckHook.beforeSwap.selector;
    }
}