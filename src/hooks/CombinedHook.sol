// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// --- Imports from BOTH Hook types ---
import {BaseHook} from "@uniswap/v4-core/contracts/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

// Brevis Imports (replace with actual)
interface IBrevisProof {
    function verifyProof(bytes32 circuitId, bytes calldata proof, bytes calldata publicInputs) external view returns (bool);
}
struct YourCircuitPublicInputs { // Define based on your circuit
    uint256 historicalVolatilityBps;
    uint256 relevantTimestamp;
}

// --- Errors from BOTH Hook types ---
error SwapAmountTooLargeForLiquidity(uint256 amountSpecified, uint128 currentLiquidity, uint256 maxAllowedAmount);
error BrevisProofVerificationFailed();
error BrevisConditionNotMet(uint256 conditionValue, uint256 threshold);
error InvalidHookData();


contract CombinedStrategyAndBrevisHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using FixedPointMathLib for uint256;

    // --- State Variables from BOTH Hook types ---
    // Liquidity Check
    uint256 public constant MAX_LIQUIDITY_IMPACT_BPS = 500; // 5%

    // Brevis Check
    IBrevisProof public immutable brevisVerifier;
    bytes32 public immutable requiredCircuitId;
    uint256 public constant MAX_ALLOWED_VOLATILITY_BPS = 100; // 1% (Example from Brevis check)

    // Optional Owner
    address public owner;

    // --- Constructor taking arguments for BOTH Hook types ---
    constructor(
        IPoolManager _poolManager,
        address _brevisVerifierAddress,
        bytes32 _requiredCircuitId
    ) BaseHook(_poolManager) {
        require(_brevisVerifierAddress != address(0), "Invalid Brevis Verifier");
        brevisVerifier = IBrevisProof(_brevisVerifierAddress);
        requiredCircuitId = _requiredCircuitId;
        owner = msg.sender;
    }

    // --- Permissions (only need beforeSwap typically) ---
    function getHookPermissions() public pure override returns (Hooks.Permissions) {
        return Hooks.Permissions({
            beforeInitialize: false, afterInitialize: false,
            beforeModifyPosition: false, afterModifyPosition: false,
            beforeSwap: true, // Implement combined check in beforeSwap
            afterSwap: false,
            beforeDonate: false, afterDonate: false
        });
    }

    // --- Combined beforeSwap Logic ---
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData // MUST contain Brevis data: abi.encode(proof, publicInputs)
    ) external view override returns (bytes4) { // Mark as view

        // --- Check 1: Liquidity Percentage ---
        PoolId poolId = key.toId();
        (, uint128 liquidity,,,,,) = poolManager.getSlot0(poolId);
        if (liquidity > 0 && params.amountSpecified > 0) { // Only check for positive input amount
             uint256 inputAmount = uint256(params.amountSpecified);
             uint256 maxAllowedSwapBasedOnLiquidity = (uint256(liquidity) * MAX_LIQUIDITY_IMPACT_BPS) / 10000;
             if (inputAmount > maxAllowedSwapBasedOnLiquidity) {
                 revert SwapAmountTooLargeForLiquidity(inputAmount, liquidity, maxAllowedSwapBasedOnLiquidity);
             }
        }
        // --- End Check 1 ---


        // --- Check 2: Brevis Proof Verification (Only if Check 1 passes) ---
        bytes memory zkProof;
        bytes memory publicInputsBytes;
        try abi.decode(hookData, (bytes, bytes)) returns (bytes memory _proof, bytes memory _inputs) {
            zkProof = _proof;
            publicInputsBytes = _inputs;
        } catch {
            revert InvalidHookData(); // Hook data didn't contain proof/inputs
        }

        bool isValid = brevisVerifier.verifyProof(requiredCircuitId, zkProof, publicInputsBytes);
        if (!isValid) {
            revert BrevisProofVerificationFailed();
        }

        // Decode and check public inputs
        YourCircuitPublicInputs memory publicInputs;
         try abi.decode(publicInputsBytes, (YourCircuitPublicInputs)) returns (YourCircuitPublicInputs memory _pi) {
             publicInputs = _pi;
         } catch {
              revert InvalidHookData(); // Public inputs structure mismatch
         }

        // Example condition check on verified inputs
        if (publicInputs.historicalVolatilityBps > MAX_ALLOWED_VOLATILITY_BPS) {
            revert BrevisConditionNotMet(publicInputs.historicalVolatilityBps, MAX_ALLOWED_VOLATILITY_BPS);
        }
        // --- End Check 2 ---


        // If ALL checks passed, allow the swap
        return CombinedStrategyAndBrevisHook.beforeSwap.selector;
    }
}