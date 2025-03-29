// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseHook} from "@uniswap/v4-core/contracts/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";

contract AfterSwapLogHook is BaseHook {

    event SwapExecuted(
        address indexed sender, // Address that called swap on PoolManager
        PoolKey poolKey,
        int256 amount0Delta, // Change in token0 balance for the sender
        int256 amount1Delta, // Change in token1 balance for the sender
        bytes hookData // Any data passed through the swap
    );

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions) {
        return Hooks.Permissions({
            beforeInitialize: false, afterInitialize: false,
            beforeModifyPosition: false, afterModifyPosition: false,
            beforeSwap: false,
            afterSwap: true, // Implement afterSwap
            beforeDonate: false, afterDonate: false
        });
    }

    /**
     * @notice Called after the core swap logic executes and balances are settled.
     * @param sender The address that initiated the swap call to the PoolManager.
     * @param key The PoolKey identifying the pool that was swapped in.
     * @param params The parameters of the swap request (same as passed to beforeSwap).
     * @param delta The actual balance changes resulting from the swap. Positive means received by sender, negative means paid by sender.
     * @param hookData Arbitrary data passed by the caller.
     * @return The 4-byte selector of this function.
     */
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta, // The actual amounts swapped
        bytes calldata hookData
    ) external override returns (bytes4) {

        // Simply emit an event with the results
        emit SwapExecuted(
            sender,
            key,
            delta.amount0(),
            delta.amount1(),
            hookData
        );

        // AfterSwap hooks can also contain logic, e.g., updating internal counters,
        // calculating realized slippage based on delta vs expected, etc.
        // Keep it gas-efficient.

        return AfterSwapLogHook.afterSwap.selector;
    }
}