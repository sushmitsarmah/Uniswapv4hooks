// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// --- Uniswap V4 Imports ---
import {BaseHook} from "@uniswap/v4-core/contracts/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/types/Currency.sol"; // Needed for logging addresses

// --- External Lib/Interface Imports ---
// Make sure you have Solmate installed: npm install solmate
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol"; // For percentage math

// !! Replace with actual Brevis interface imports from their SDK/Docs !!
interface IBrevisProof {
    function verifyProof(bytes32 circuitId, bytes calldata proof, bytes calldata publicInputs) external view returns (bool);
}
// !! Define this struct based EXACTLY on your ZK circuit's public outputs !!
struct YourCircuitPublicInputs {
    uint256 historicalVolatilityBps; // Example
    uint256 relevantTimestamp;       // Example
    // Add other public outputs from your specific ZK circuit
}

// Simple Chainlink Interface (ensure it matches the feed you use)
interface IChainlinkAggregator {
    function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}
// ------------------------------

// --- Custom Errors Consolidated ---
error TradingWindowClosed(uint256 currentTime, uint256 startHour, uint256 endHour);
error TradingDayClosed(uint256 currentDay);
error SwapAmountTooLargeForLiquidity(uint256 amountSpecified, uint128 currentLiquidity, uint256 maxAllowedAmount);
error PriceDeviationTooHigh(uint256 poolPriceX96_Precise, uint256 oraclePriceX96_Precise, uint256 maxDeviationBps); // Using normalized price representation
error OraclePriceStale(uint256 lastUpdate, uint256 maxAge);
error InvalidOraclePrice(int256 price);
error BrevisProofVerificationFailed();
error BrevisConditionNotMet(uint256 conditionValue, uint256 threshold);
error InvalidHookData();

/**
 * @title ComprehensiveBotHook
 * @notice A Uniswap V4 Hook combining multiple pre-swap checks and post-swap logging.
 * @dev Checks performed in beforeSwap (in order): Time Window, Liquidity Impact, Oracle Price Deviation, Brevis Proof Verification.
 *      Emits a log event in afterSwap.
 *      Designed to be called via BotSwapExecutor, expecting Brevis proof data in hookData.
 */
contract ComprehensiveBotHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency; // For logging

    // --- State Variables ---
    address public owner;

    // Time Control Config
    uint8 public constant TRADING_START_HOUR_UTC = 0; // Example: Allow 24h
    uint8 public constant TRADING_END_HOUR_UTC = 24;  // Example: Allow 24h
    mapping(uint256 => bool) public isTradingDay; // 1=Mon, ..., 7=Sun

    // Liquidity Check Config
    uint256 public constant MAX_LIQUIDITY_IMPACT_BPS = 500; // Example: 5%

    // Oracle Check Config
    IChainlinkAggregator public immutable priceFeed; // e.g., ETH/USD feed for a WETH/USDC pool
    uint8 public immutable priceFeedDecimals;
    uint256 public constant MAX_PRICE_DEVIATION_BPS = 300; // Example: 3% max deviation allowed
    bool public immutable isToken0PriceFeed; // True if Chainlink feed is T0/T1, False if T1/T0 relative to PoolKey
    uint256 public constant MAX_ORACLE_AGE = 1 hours;
    // Precision constant for price comparison (using 1e18)
    uint256 internal constant PRICE_PRECISION = 1e18;

    // Brevis Check Config
    IBrevisProof public immutable brevisVerifier; // Brevis verification contract address
    bytes32 public immutable requiredCircuitId;  // Specific circuit ID for this hook's check
    uint256 public constant MAX_ALLOWED_VOLATILITY_BPS = 150; // Example: 1.5% threshold from Brevis proof


    // --- Events ---
    event SwapExecutedLog(
        address indexed sender,
        address indexed token0,
        address indexed token1,
        uint24 fee,
        int24 tickSpacing,
        int128 amount0Delta, // Note: Using int128 from BalanceDelta
        int128 amount1Delta,
        bytes hookDataPassed
    );

    // --- Constructor ---
    constructor(
        IPoolManager _poolManager,
        address _brevisVerifierAddress,
        bytes32 _requiredCircuitId,
        address _priceFeedAddress, // Chainlink feed address
        bool _isToken0PriceFeed   // True if feed = T0/T1, False if T1/T0 for the pool this hook is used with
    ) BaseHook(_poolManager) {
        owner = msg.sender;

        // Time defaults (Mon-Fri)
        isTradingDay[1] = true; isTradingDay[2] = true; isTradingDay[3] = true;
        isTradingDay[4] = true; isTradingDay[5] = true;

        // Oracle setup
        require(_priceFeedAddress != address(0), "Invalid Price Feed");
        priceFeed = IChainlinkAggregator(_priceFeedAddress);
        priceFeedDecimals = priceFeed.decimals();
        isToken0PriceFeed = _isToken0PriceFeed;

        // Brevis setup
        require(_brevisVerifierAddress != address(0), "Invalid Brevis Verifier");
        brevisVerifier = IBrevisProof(_brevisVerifierAddress);
        requiredCircuitId = _requiredCircuitId;
    }

    // --- Permissions ---
    function getHookPermissions() public pure override returns (Hooks.Permissions) {
        return Hooks.Permissions({
            beforeInitialize: false, afterInitialize: false,
            beforeModifyPosition: false, afterModifyPosition: false,
            beforeSwap: true,  // Implement combined pre-swap checks
            afterSwap: true,   // Implement post-swap logging
            beforeDonate: false, afterDonate: false
        });
    }

    // --- Core Hook Logic ---

    /**
     * @notice Performs multiple checks before allowing a swap.
     * @dev Checks: Time -> Liquidity -> Oracle Price -> Brevis Proof.
     *      Expects hookData to be abi.encode(bytes proof, bytes publicInputs) for Brevis.
     */
    function beforeSwap(
        address sender, // Expected to be BotSwapExecutor
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData // Must contain abi.encoded Brevis proof data
    ) external view override returns (bytes4) { // Mark view (check Chainlink/Brevis calls)

        // --- Check 1: Time Control ---
        checkTimeWindow();

        // --- Check 2: Liquidity Percentage Impact ---
        checkLiquidityImpact(key, params);

        // --- Check 3: Oracle Price Deviation ---
        checkOraclePriceDeviation(key);

        // --- Check 4: Brevis ZK Proof Verification ---
        checkBrevisProof(hookData);

        // --- All Checks Passed ---
        return ComprehensiveBotHook.beforeSwap.selector;
    }

    /**
     * @notice Logs details of a successful swap after execution.
     */
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params, // Swap parameters originally requested
        BalanceDelta delta, // Actual balance changes achieved
        bytes calldata hookData // Original hook data passed
    ) external override returns (bytes4) {

        emit SwapExecutedLog(
            sender, // Who initiated the swap (BotSwapExecutor address)
            Currency.unwrap(key.currency0), // Get token addresses
            Currency.unwrap(key.currency1),
            key.fee,
            key.tickSpacing,
            delta.amount0(), // Actual delta for token0
            delta.amount1(), // Actual delta for token1
            hookData        // Log the data passed (e.g., Brevis proof identifier)
        );

        return ComprehensiveBotHook.afterSwap.selector;
    }

    // --- Internal Check Functions ---

    function checkTimeWindow() internal view {
        uint256 currentTime = block.timestamp;
        // Check Hour (UTC)
        uint256 currentHour = (currentTime % 86400) / 3600;
        if (currentHour < TRADING_START_HOUR_UTC || currentHour >= TRADING_END_HOUR_UTC) {
            revert TradingWindowClosed(currentTime, TRADING_START_HOUR_UTC, TRADING_END_HOUR_UTC);
        }
        // Check Day of Week (1=Mon...7=Sun)
        uint256 dayOfWeekStandard = ((currentTime / 86400) + 4) % 7 + 1; // Formula for 1-7 mapping
        if (!isTradingDay[dayOfWeekStandard]) {
            revert TradingDayClosed(dayOfWeekStandard);
        }
    }

    function checkLiquidityImpact(PoolKey calldata key, IPoolManager.SwapParams calldata params) internal view {
        if (params.amountSpecified <= 0) return; // Only check positive input amounts for simplicity

        PoolId poolId = key.toId();
        (, uint128 liquidity,,,,,) = poolManager.getSlot0(poolId);
        if (liquidity == 0) return; // No liquidity to check against

        uint256 inputAmount = uint256(params.amountSpecified);
        uint256 maxAllowedSwapBasedOnLiquidity = (uint256(liquidity) * MAX_LIQUIDITY_IMPACT_BPS) / 10000;

        if (inputAmount > maxAllowedSwapBasedOnLiquidity) {
            revert SwapAmountTooLargeForLiquidity(inputAmount, liquidity, maxAllowedSwapBasedOnLiquidity);
        }
    }

   function checkOraclePriceDeviation(PoolKey calldata key) internal view {
        // Get Pool Price
        PoolId poolId = key.toId();
        (int24 currentTick,,,,,,) = poolManager.getSlot0(poolId);
        uint160 sqrtPoolPriceX96 = TickMath.getSqrtRatioAtTick(currentTick);
        // Calculate pool price (Token1 per Token0) with PRICE_PRECISION decimals: (sqrtPrice^2 * 1e18) >> 192
        uint256 poolPriceX192 = uint256(sqrtPoolPriceX96) * uint256(sqrtPoolPriceX96);
        uint256 poolPriceT1perT0_Precise = (poolPriceX192 * PRICE_PRECISION) >> 192;
        if (poolPriceT1perT0_Precise == 0) return; // Avoid division by zero if pool price is somehow zero

        // Get Oracle Price
        (, int256 oracleAnswer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        if (block.timestamp - updatedAt > MAX_ORACLE_AGE) {
            revert OraclePriceStale(updatedAt, MAX_ORACLE_AGE);
        }
        if (oracleAnswer <= 0) {
             revert InvalidOraclePrice(oracleAnswer);
        }

        // Normalize Oracle Price to T1/T0 with PRICE_PRECISION decimals
        uint256 oraclePriceT1perT0_Precise;
        if (isToken0PriceFeed) { // Oracle provides T0/T1, need inverse: 1 / (OraclePrice / 10^Dec) = 10^Dec / OraclePrice
             // Scale numerator first: (1 * 10^oracleDecimals * PRICE_PRECISION * PRICE_PRECISION) / (oracleAnswer * PRICE_PRECISION)
             // (10**priceFeedDecimals * PRICE_PRECISION * PRICE_PRECISION) should fit uint256 if PRICE_PRECISION is 1e18 and decimals <= 18
             uint256 numerator = (10**priceFeedDecimals) * PRICE_PRECISION * PRICE_PRECISION;
             oraclePriceT1perT0_Precise = numerator / (uint256(oracleAnswer) * PRICE_PRECISION);
        } else { // Oracle provides T1/T0, just adjust decimals: OraclePrice * 1e18 / 10^Dec
            oraclePriceT1perT0_Precise = (uint256(oracleAnswer) * PRICE_PRECISION) / (10**priceFeedDecimals);
        }
         if (oraclePriceT1perT0_Precise == 0) {
             revert InvalidOraclePrice(0); // Avoid division by zero in deviation calc
         }

        // Compare Prices
        uint256 priceDiff = poolPriceT1perT0_Precise > oraclePriceT1perT0_Precise
            ? poolPriceT1perT0_Precise - oraclePriceT1perT0_Precise
            : oraclePriceT1perT0_Precise - poolPriceT1perT0_Precise;
        // deviationBps = (priceDiff * 10000) / oraclePrice (use oracle as baseline)
        uint256 deviationBps = (priceDiff * 10000) / oraclePriceT1perT0_Precise;

        if (deviationBps > MAX_PRICE_DEVIATION_BPS) {
            revert PriceDeviationTooHigh(poolPriceT1perT0_Precise, oraclePriceT1perT0_Precise, MAX_PRICE_DEVIATION_BPS);
        }
    }

    function checkBrevisProof(bytes calldata hookData) internal view {
        // Decode Brevis proof data from hookData
        bytes memory zkProof;
        bytes memory publicInputsBytes;
        try abi.decode(hookData, (bytes, bytes)) returns (bytes memory _proof, bytes memory _inputs) {
            zkProof = _proof;
            publicInputsBytes = _inputs;
        } catch {
            revert InvalidHookData(); // Data structure mismatch
        }
        if (zkProof.length == 0 || publicInputsBytes.length == 0) {
             revert InvalidHookData(); // Data empty
        }


        // Verify the ZK proof
        bool isValid = brevisVerifier.verifyProof(requiredCircuitId, zkProof, publicInputsBytes);
        if (!isValid) {
            revert BrevisProofVerificationFailed();
        }

        // Decode public inputs (structure must match YOUR circuit)
        YourCircuitPublicInputs memory publicInputs;
         try abi.decode(publicInputsBytes, (YourCircuitPublicInputs)) returns (YourCircuitPublicInputs memory _pi) {
             publicInputs = _pi;
         } catch {
              revert InvalidHookData(); // Public inputs structure mismatch
         }

        // Check conditions based on verified public inputs
        // Example: Check proven volatility against threshold
        if (publicInputs.historicalVolatilityBps > MAX_ALLOWED_VOLATILITY_BPS) {
            revert BrevisConditionNotMet(publicInputs.historicalVolatilityBps, MAX_ALLOWED_VOLATILITY_BPS);
        }
        // Example: Check proof freshness
        // if (block.timestamp - publicInputs.relevantTimestamp > 1 hours) {
        //     revert BrevisConditionNotMet(publicInputs.relevantTimestamp, block.timestamp - 1 hours); // Custom error needed
        // }
    }

    // --- Admin Functions ---
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    function setTradingDay(uint256 dayOfWeek, bool allowed) external onlyOwner {
        require(dayOfWeek >= 1 && dayOfWeek <= 7, "Invalid day (1-7)");
        isTradingDay[dayOfWeek] = allowed;
    }

    // Add setters for thresholds (MAX_LIQUIDITY_IMPACT_BPS, MAX_PRICE_DEVIATION_BPS, etc.) if needed, making them non-constant.
}