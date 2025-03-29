// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseHook} from "@uniswap/v4-core/contracts/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/types/Currency.sol";

// Custom Error
error SwapAmountExceedsSingleTransactionLimit(uint256 amountSpecified, uint256 maxAllowedAmount);

contract MaxSwapSizeEnforcerHook is BaseHook {
    using CurrencyLibrary for Currency;

    // Configuration: Maximum amount of either token allowed in a single swap tx
    // NOTE: This is a simplified example using a fixed limit.
    // A more robust version might fetch this limit from storage set by an owner,
    // or even dynamically based on liquidity percentage (like the first hook example).
    uint256 public immutable maxSwapAmountPerTx; // e.g., 100_000 * 1e6 for 100k USDC
    address public immutable limitedToken; // The token whose amount we're limiting (e.g., USDC address if limit is in USDC)

    constructor(
        IPoolManager _poolManager,
        uint256 _maxSwapAmountPerTx, // The limit amount (in wei/smallest unit)
        address _limitedToken       // Address of the token the limit applies to
    ) BaseHook(_poolManager) {
        require(_maxSwapAmountPerTx > 0, "Max amount cannot be zero");
        require(_limitedToken != address(0), "Limited token cannot be zero address");
        maxSwapAmountPerTx = _maxSwapAmountPerTx;
        limitedToken = _limitedToken;
    }

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
     * @notice Called before the core swap logic executes.
     * @dev Reverts if the absolute amount of the specific `limitedToken` being swapped
     *      (either input or output estimate if amountSpecified is negative) exceeds the configured limit.
     */
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external view override returns (bytes4) {

        // Figure out which token is token0 and token1
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        // Identify the amount being swapped of the `limitedToken`
        uint256 amountOfLimitedToken;
        int256 amountSpecified = params.amountSpecified; // Can be positive (input) or negative (output)

        // Check if the specified amount relates to the token we are limiting
        if (params.zeroForOne) {
            // Swapping token0 for token1
            if (token0 == limitedToken && amountSpecified > 0) { // Selling limitedToken (input amount)
                amountOfLimitedToken = uint256(amountSpecified);
            } else if (token1 == limitedToken && amountSpecified < 0) { // Buying limitedToken (output amount)
                 amountOfLimitedToken = uint256(-amountSpecified);
            } else {
                 // Swap doesn't directly involve the limited token amount we're checking, allow it.
                 // Or add logic to estimate the other token's amount if needed.
                 return MaxSwapSizeEnforcerHook.beforeSwap.selector;
            }
        } else {
            // Swapping token1 for token0
             if (token1 == limitedToken && amountSpecified > 0) { // Selling limitedToken (input amount)
                amountOfLimitedToken = uint256(amountSpecified);
            } else if (token0 == limitedToken && amountSpecified < 0) { // Buying limitedToken (output amount)
                 amountOfLimitedToken = uint256(-amountSpecified);
            } else {
                 // Swap doesn't directly involve the limited token amount we're checking, allow it.
                 return MaxSwapSizeEnforcerHook.beforeSwap.selector;
            }
        }


        // --- Check against the limit ---
        if (amountOfLimitedToken > maxSwapAmountPerTx) {
            revert SwapAmountExceedsSingleTransactionLimit(
                amountOfLimitedToken,
                maxSwapAmountPerTx
            );
        }

        // If the check passes, allow the swap to proceed
        return MaxSwapSizeEnforcerHook.beforeSwap.selector;
    }
}