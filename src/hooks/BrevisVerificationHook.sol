// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseHook} from "@uniswap/v4-core/contracts/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";

// --- Brevis Specific Imports ---
// !! Replace with actual Brevis interface imports from their SDK/Docs !!
interface IBrevisProof {
    function verifyProof(
        bytes32 circuitId,
        bytes calldata proof,
        bytes calldata publicInputs
    ) external view returns (bool);
}

// !! Define this struct based EXACTLY on your ZK circuit's public outputs !!
struct YourCircuitPublicInputs {
    uint256 historicalVolatilityBps; // Example
    uint256 relevantTimestamp;       // Example
    // Add other public outputs from your specific ZK circuit
}
// ------------------------------

// Custom Errors
error BrevisProofVerificationFailed();
error BrevisConditionNotMet(uint256 conditionValue, uint256 threshold);
error InvalidHookData();

contract BrevisVerificationHook is BaseHook {

    IBrevisProof public immutable brevisVerifier; // Address of Brevis verification contract
    bytes32 public immutable requiredCircuitId; // The specific circuit ID this hook validates
    uint256 public constant MAX_ALLOWED_VOLATILITY_BPS = 100; // Example threshold: 1%

    address public owner; // Optional: for managing parameters

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

    function getHookPermissions() public pure override returns (Hooks.Permissions) {
        return Hooks.Permissions({
            beforeInitialize: false, afterInitialize: false,
            beforeModifyPosition: false, afterModifyPosition: false,
            beforeSwap: true, // Implement beforeSwap for pre-swap check
            afterSwap: false,
            beforeDonate: false, afterDonate: false
        });
    }

    /**
     * @notice Verifies a Brevis ZK proof passed via hookData before allowing swap.
     * @dev Expects hookData to be abi.encode(bytes proof, bytes publicInputs)
     *      The structure of publicInputs MUST match YourCircuitPublicInputs.
     */
    function beforeSwap(
        address sender, // Should be BotSwapExecutor
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData // Expecting abi.encoded(proof, publicInputs)
    ) external view override returns (bytes4) { // Mark as view

        // Decode the proof and public inputs from hookData
        bytes memory zkProof;
        bytes memory publicInputsBytes;
        try abi.decode(hookData, (bytes, bytes)) returns (bytes memory _proof, bytes memory _inputs) {
            zkProof = _proof;
            publicInputsBytes = _inputs;
        } catch {
            revert InvalidHookData();
        }

        // Verify the proof on-chain using the Brevis contract
        bool isValid = brevisVerifier.verifyProof(
            requiredCircuitId,
            zkProof,
            publicInputsBytes
        );

        if (!isValid) {
            revert BrevisProofVerificationFailed();
        }

        // --- Condition Check based on Verified Public Inputs ---
        // Decode the public inputs according to YOUR circuit's output structure
        YourCircuitPublicInputs memory publicInputs;
         try abi.decode(publicInputsBytes, (YourCircuitPublicInputs)) returns (YourCircuitPublicInputs memory _pi) {
            publicInputs = _pi;
         } catch {
             revert InvalidHookData(); // Public inputs structure mismatch
         }


        // Example Check: Ensure proven historical volatility is below the threshold
        if (publicInputs.historicalVolatilityBps > MAX_ALLOWED_VOLATILITY_BPS) {
            revert BrevisConditionNotMet(
                publicInputs.historicalVolatilityBps,
                MAX_ALLOWED_VOLATILITY_BPS
            );
        }

        // Example Check: Ensure the proof isn't too old
        // require(block.timestamp - publicInputs.relevantTimestamp < 1 hours, "Proof data too old");

        // Add other checks based on the verified public inputs as needed...

        // If verification is successful and conditions met, allow the swap
        return BrevisVerificationHook.beforeSwap.selector;
    }
}