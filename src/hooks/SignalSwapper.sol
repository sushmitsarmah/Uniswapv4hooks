// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {IHooks} from "@uniswap/v4-core/interfaces/IHooks.sol";
import {IERC20Minimal} from "@uniswap/v4-core/interfaces/external/IERC20Minimal.sol";

// Interface for the V4 swap callback
interface ISwapCallback {
    function uniswapV4SwapCallback(BalanceDelta delta, bytes calldata data) external;
}

contract SignalSwapper is ISwapCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable poolManager;
    address public immutable owner;
    address public immutable swapHook; // Address of your deployed SwapStrategyHook

    // Mapping to store callback data temporarily during a swap
    struct CallbackData {
        address tokenIn;
        address tokenOut;
        address payer; // Who sends tokenIn to the poolManager
    }
    mapping(bytes32 => CallbackData) public swapCallbackData;


    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(address _poolManager, address _hookAddress) {
        poolManager = IPoolManager(_poolManager);
        swapHook = _hookAddress; // Store the address of your hook
        owner = msg.sender;
    }

    /**
     * @notice Initiates a swap based on external signals.
     * @param tokenIn Address of the token to sell.
     * @param tokenOut Address of the token to buy.
     * @param fee The fee tier of the pool (e.g., 3000 for 0.3%).
     * @param tickSpacing The tick spacing of the pool.
     * @param amountToSwap The amount of tokenIn to sell (positive) or tokenOut to receive (negative).
     * @param sqrtPriceLimitX96 Slippage protection: the price limit for the swap. 0 for no limit (not recommended).
     * @param hookData Optional data to pass to the hook (empty for this example).
     */
    function executeSwap(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        int24 tickSpacing,
        int256 amountToSwap, // Positive: amount of tokenIn to sell. Negative: amount of tokenOut to receive.
        uint160 sqrtPriceLimitX96,
        bytes calldata hookData
    ) external onlyOwner { // Add access control as needed
        require(tokenIn != address(0) && tokenOut != address(0), "Invalid token address");
        require(tokenIn != tokenOut, "Cannot swap same token");

        // Determine zeroForOne based on token order (V4 requires sorted tokens)
        (address token0, address token1) = tokenIn < tokenOut ? (tokenIn, tokenOut) : (tokenOut, tokenIn);
        bool zeroForOne = tokenIn == token0;

        // --- Construct the PoolKey, INCLUDING THE HOOK ADDRESS ---
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.from(token0),
            currency1: CurrencyLibrary.from(token1),
            fee: fee,
            tickSpacing: tick_spacing,
            hooks: IHooks(swapHook) // <--- CRITICAL: Link the hook to the pool key
        });

        // --- Prepare Swap Parameters ---
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountToSwap,
            sqrtPriceLimitX96: sqrtPriceLimitX96 == 0 ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1) : sqrtPriceLimitX96
        });

        // --- Approve the PoolManager to spend tokenIn ---
        // Important: This contract needs tokenIn approved beforehand, or approve here.
        IERC20Minimal(tokenIn).transferFrom(msg.sender, address(this), abs(amountToSwap)); // Get tokens from owner
        IERC20Minimal(tokenIn).approve(address(poolManager), abs(amountToSwap)); // Approve PoolManager

        // --- Store callback data ---
        // Using poolId and timestamp as a unique key for callback data
         bytes32 callbackKey = keccak256(abi.encodePacked(key.toId(), block.timestamp, msg.sender));
         swapCallbackData[callbackKey] = CallbackData({
             tokenIn: tokenIn,
             tokenOut: tokenOut,
             payer: address(this) // This contract pays the input tokens
         });


        // --- Execute the Swap via PoolManager ---
        // The PoolManager will call our `swapHook`'s `beforeSwap` function.
        // If the hook doesn't revert, PoolManager proceeds with the swap math.
        // Then, PoolManager calls `uniswapV4SwapCallback` on THIS contract.
        poolManager.swap(key, params, callbackKey); // Pass callbackKey as hookData

        // --- Handle Output Tokens & Leftover Input ---
        // Retrieve received tokenOut
         uint256 balanceOut = IERC20Minimal(tokenOut).balanceOf(address(this));
         if (balanceOut > 0) {
            IERC20Minimal(tokenOut).transfer(msg.sender, balanceOut); // Send received tokens to owner
         }

        // Refund any leftover tokenIn if amountSpecified was input and not fully used
        uint256 balanceIn = IERC20Minimal(tokenIn).balanceOf(address(this));
        if (balanceIn > 0) {
            IERC20Minimal(tokenIn).transfer(msg.sender, balanceIn); // Refund unused input
        }

        // Clean up callback data storage
        delete swapCallbackData[callbackKey];
    }


     /// @notice Called by the PoolManager during swap to request/dispense funds.
     /// @param delta The amounts to be paid/received by the sender. Positive means PoolManager sends to sender, negative means sender pays PoolManager.
     /// @param data The data passed in the swap call (our callbackKey).
     function uniswapV4SwapCallback(BalanceDelta delta, bytes calldata data) external override {
         require(msg.sender == address(poolManager), "Callback: Invalid caller");

         bytes32 callbackKey = bytes32(data);
         CallbackData memory callbackInfo = swapCallbackData[callbackKey];
         require(callbackInfo.payer != address(0), "Callback: Invalid data key"); // Check if data exists


         if (delta.amount0() < 0) {
             // Pay token0
             Currency currency0 = poolManager.getCurrency(delta.currency0());
             IERC20Minimal(Currency.unwrap(currency0)).transferFrom(callbackInfo.payer, msg.sender, uint256(-delta.amount0()));
         }
         if (delta.amount1() < 0) {
             // Pay token1
              Currency currency1 = poolManager.getCurrency(delta.currency1());
             IERC20Minimal(Currency.unwrap(currency1)).transferFrom(callbackInfo.payer, msg.sender, uint256(-delta.amount1()));
         }
          // Positive delta amounts are handled by PoolManager transferring *to* this contract *before* this callback returns.
     }

     // Helper function for absolute value
     function abs(int256 x) internal pure returns (uint256) {
         return x >= 0 ? uint256(x) : uint256(-x);
     }

     // Allow owner to withdraw any accidentally sent ERC20 tokens
     function withdrawTokens(address tokenAddress) external onlyOwner {
        uint256 balance = IERC20Minimal(tokenAddress).balanceOf(address(this));
        if (balance > 0) {
             IERC20Minimal(tokenAddress).transfer(owner, balance);
        }
     }

      // Allow owner to withdraw native ETH if necessary
     receive() external payable {}
     function withdrawETH() external onlyOwner {
         payable(owner).transfer(address(this).balance);
     }
}