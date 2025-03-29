// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {IHooks} from "@uniswap/v4-core/interfaces/IHooks.sol";
import {IERC20Minimal} from "@uniswap/v4-core/interfaces/external/IERC20Minimal.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {CallbackValidation} from "@uniswap/v4-core/contracts/libraries/CallbackValidation.sol"; // For callback security

// Interface for the V4 swap callback is implicitly handled by PoolManager interaction now

contract BotSwapExecutor { // Removed ISwapCallback inheritance for simplicity, rely on PoolManager checks
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable poolManager;
    address public immutable botAddress; // The address authorized to call swaps

    // Simple re-entrancy guard
    uint256 private locked = 1; // 1 = unlocked, 2 = locked
    modifier nonReentrant() {
        require(locked == 1, "Reentrant call");
        locked = 2;
        _;
        locked = 1;
    }

    modifier onlyBot() {
        require(msg.sender == botAddress, "Caller is not the authorized bot");
        _;
    }

    constructor(address _poolManager, address _botAddress) {
        poolManager = IPoolManager(_poolManager);
        require(_botAddress != address(0), "Invalid bot address");
        botAddress = _botAddress;
    }

    /**
     * @notice Executes a swap selling a fixed amount of tokenIn for tokenOut.
     * @param tokenIn Address of the token to sell.
     * @param tokenOut Address of the token to buy.
     * @param fee Fee tier of the target pool.
     * @param tickSpacing Tick spacing of the target pool.
     * @param hookAddress Address of the hook contract registered with the pool.
     * @param amountIn The exact amount of tokenIn to sell.
     * @param sqrtPriceLimitX96 The price limit for slippage protection. MUST be calculated by the bot.
     *                          0 is NOT recommended for mainnet swaps.
     * @dev Requires the 'botAddress' to have approved this contract to spend 'amountIn' of 'tokenIn'.
     */
    function executeFixedInputSwap(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        int24 tickSpacing,
        address hookAddress, // Bot needs to know the hook for the specific pool
        uint256 amountIn,
        uint160 sqrtPriceLimitX96 // Bot MUST calculate this off-chain based on desired slippage
    ) external onlyBot nonReentrant {
        require(tokenIn != address(0) && tokenOut != address(0), "Invalid token address");
        require(tokenIn != tokenOut, "Cannot swap same token");
        require(amountIn > 0, "AmountIn must be positive");
        require(hookAddress != address(0), "Hook address required"); // Enforce hook usage

        // --- Transfer tokenIn from Bot's Wallet to this contract ---
        // IMPORTANT: The bot's wallet address MUST have called approve() on the tokenIn contract
        //            granting this BotSwapExecutor contract an allowance >= amountIn.
        IERC20Minimal(tokenIn).transferFrom(botAddress, address(this), amountIn);

        // --- Prepare Pool Key & Swap Params ---
        (address token0, address token1) = tokenIn < tokenOut ? (tokenIn, tokenOut) : (tokenOut, tokenIn);
        bool zeroForOne = tokenIn == token0;

        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.from(token0),
            currency1: CurrencyLibrary.from(token1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hookAddress) // Use the hook specified by the bot
        });

        // Use the provided limit, or set a default (less safe) if 0 is passed
        uint160 effectivePriceLimit = sqrtPriceLimitX96 == 0
            ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
            : sqrtPriceLimitX96;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(amountIn), // Positive amount = selling this much tokenIn
            sqrtPriceLimitX96: effectivePriceLimit
        });

        // --- Approve PoolManager ---
        // Approve the PoolManager to take the tokenIn from *this* contract
        IERC20Minimal(tokenIn).approve(address(poolManager), amountIn);

        // --- Execute Swap ---
        // PoolManager will call the hook's beforeSwap, then execute, then call this contract's callback
         bytes memory hookData = abi.encode(botAddress, tokenIn, tokenOut); // Pass data to callback if needed

        int256 amount0Delta;
        int256 amount1Delta;
        try poolManager.swap(key, params, hookData) returns (BalanceDelta delta) {
             amount0Delta = delta.amount0();
             amount1Delta = delta.amount1();
        } catch {
             // If swap fails (e.g., hook reverted, slippage), refund the input token to bot
             IERC20Minimal(tokenIn).transfer(botAddress, IERC20Minimal(tokenIn).balanceOf(address(this)));
             revert("Swap failed"); // Propagate failure
        }


        // --- Handle Received Token ---
        // The swap callback (uniswapV4SwapCallback below) handles paying the PoolManager.
        // The PoolManager sends the output token directly to this contract *before* returning from swap().

        uint256 amountOutReceived;
        if (zeroForOne && amount1Delta > 0) { // Received token1 (tokenOut)
             amountOutReceived = uint256(amount1Delta);
             require(IERC20Minimal(tokenOut).balanceOf(address(this)) >= amountOutReceived, "Receive output mismatch"); // Sanity check
             IERC20Minimal(tokenOut).transfer(botAddress, amountOutReceived);
        } else if (!zeroForOne && amount0Delta > 0) { // Received token0 (tokenOut)
             amountOutReceived = uint256(amount0Delta);
             require(IERC20Minimal(tokenOut).balanceOf(address(this)) >= amountOutReceived, "Receive output mismatch"); // Sanity check
              IERC20Minimal(tokenOut).transfer(botAddress, amountOutReceived);
        }

        // --- Refund any unused TokenIn (if any, less likely with fixed input) ---
        uint256 remainingTokenIn = IERC20Minimal(tokenIn).balanceOf(address(this));
        if (remainingTokenIn > 0) {
            IERC20Minimal(tokenIn).transfer(botAddress, remainingTokenIn);
        }
    }

    /// @notice Callback function called by the PoolManager during a swap initiated by this contract.
    /// @param delta Amount of tokens owed to (-ve) or by (+ve) the PoolManager.
    /// @param data Arbitrary data passed from the swap() call (contains botAddress, tokens).
    /// @dev Handles transferring the input token collected earlier to the PoolManager.
    // ref: https://github.com/Uniswap/v4-core/blob/main/contracts/PoolManager.sol#L401
    // PoolManager uses `balanceDelta.amount0(), balanceDelta.amount1()`. Positive = pay TO caller, Negative = pay FROM caller
    function uniswapV4SwapCallback(BalanceDelta delta, bytes calldata data) external {
         // Basic validation: only poolManager can call this during our swap.
        require(msg.sender == address(poolManager), "Invalid caller");

        // Decode data to ensure it's related to a known swap pattern if needed
        // (address _botAddress, address _tokenIn, address _tokenOut) = abi.decode(data, (address, address, address));
        // require(_botAddress == botAddress, "Callback data mismatch"); // Extra check if desired


        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

         if (amount0 < 0) {
            // We owe token0 to the pool
            Currency currency0 = poolManager.getCurrency(delta.currency0());
             IERC20Minimal(Currency.unwrap(currency0)).transfer(msg.sender, uint256(-amount0));
         }
         if (amount1 < 0) {
             // We owe token1 to the pool
             Currency currency1 = poolManager.getCurrency(delta.currency1());
             IERC20Minimal(Currency.unwrap(currency1)).transfer(msg.sender, uint256(-amount1));
         }
         // Positive delta values are tokens *received* from the pool, which the PoolManager sends
         // before this callback finishes execution. We handle transferring them *out* in the main function after swap returns.
    }

     // Allow bot to withdraw any accidentally sent ERC20 tokens
     function withdrawStuckTokens(address tokenAddress) external onlyBot {
        uint256 balance = IERC20Minimal(tokenAddress).balanceOf(address(this));
        if (balance > 0) {
             IERC20Minimal(tokenAddress).transfer(botAddress, balance);
        }
     }

      // Allow bot to withdraw native ETH if necessary
     receive() external payable {}
     function withdrawStuckETH() external onlyBot {
         payable(botAddress).transfer(address(this).balance);
     }
}