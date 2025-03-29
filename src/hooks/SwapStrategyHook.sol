// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseHook} from "@uniswap/v4-core/contracts/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
// Make sure you have a math library like Solmate's FixedPointMathLib
// npm install solmate
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

// Custom Error for clarity
error SwapAmountTooLargeForLiquidity(uint256 amountSpecified, uint128 currentLiquidity, uint256 maxAllowedAmount);

contract SwapStrategyHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using FixedPointMathLib for uint256; // Using Solmate's library for percentage calculation

    // Configuration: Maximum % of current pool liquidity allowed in a single swap (as input)
    // Example: 500 = 5% (500 / 10000)
    uint256 public constant MAX_LIQUIDITY_IMPACT_BPS = 500; // Configurable: 5%

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /**
     * @notice Define which hook functions are implemented by this contract.
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions) {
        return Hooks.Permissions({
            beforeInitialize: false, afterInitialize: false,
            beforeModifyPosition: false, afterModifyPosition: false,
            beforeSwap: true, // We implement the beforeSwap hook
            afterSwap: false,
            beforeDonate: false, afterDonate: false
        });
    }

    /**
     * @notice Called before the core swap logic executes. Checks input amount against liquidity percentage.
     */
    function beforeSwap(
        address sender, // Should be our BotSwapExecutor
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData // Not used in this simple hook
    ) external view override returns (bytes4) { // Mark as view as it only reads state
        // --- Liquidity Check Logic ---
        PoolId poolId = key.toId();
        // Note: getSlot0 provides Tick and Liquidity data. Liquidity here represents liquidity *around* the current tick.
        (, uint128 liquidity,,,,,) = poolManager.getSlot0(poolId);
        if (liquidity == 0) { // Avoid division by zero and swaps in empty ranges
             return SwapStrategyHook.beforeSwap.selector; // Or revert if desired
        }

        // This check works best when amountSpecified is the INPUT amount (positive)
        if (params.amountSpecified > 0) {
            uint256 inputAmount = uint256(params.amountSpecified);
             // Calculate the max allowed input amount based on liquidity percentage
            uint256 maxAllowedSwapBasedOnLiquidity = (uint256(liquidity) * MAX_LIQUIDITY_IMPACT_BPS) / 10000;

            if (inputAmount > maxAllowedSwapBasedOnLiquidity) {
                // Revert if the swap input amount is deemed too large
                revert SwapAmountTooLargeForLiquidity(
                    inputAmount,
                    liquidity,
                    maxAllowedSwapBasedOnLiquidity
                );
            }
        }
        // If amountSpecified is negative (output target), this check is less direct.
        // Could add logic to estimate input amount based on current price if needed, but adds complexity/gas.

        // If all checks pass, allow the swap to proceed
        return SwapStrategyHook.beforeSwap.selector;
    }
}