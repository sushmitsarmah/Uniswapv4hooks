// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseHook} from "v4-core/contracts/BaseHook.sol";
import {Hooks} from "v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/contracts/types/PoolKey.sol";
import "../lib/BrevisApp.sol";

// Custom Errors
error BrevisProofVerificationFailed();
error BrevisConditionNotMet(uint256 conditionValue, uint256 threshold);
error InvalidHookData();

/**
 * @notice Struct representing the public outputs from the ZK circuit
 * @dev This must match exactly with the circuit's output structure
 */
struct CircuitPublicInputs {
    address accountAddr;    // The address of the account being verified
    uint64 blockNum;       // The block number when the data was recorded
    uint256 volume;        // The transfer volume/amount
    uint256 timestamp;     // The timestamp of the transaction
    uint256 historicalVolume; // Historical volume for the account
}

contract BrevisVerificationHook is BrevisApp, BaseHook {
    bytes32 public immutable requiredCircuitId; // The specific circuit ID this hook validates
    uint256 public constant MAX_ALLOWED_VOLATILITY_BPS = 100; // Example threshold: 1%

    constructor(
        IPoolManager _poolManager,
        address _brevisRequest,
        bytes32 _requiredCircuitId
    ) BrevisApp(_brevisRequest) BaseHook(_poolManager) {
        require(_requiredCircuitId != bytes32(0), "Invalid Circuit ID");
        requiredCircuitId = _requiredCircuitId;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions) {
        return Hooks.Permissions({
            beforeInitialize: false, afterInitialize: false,
            beforeModifyPosition: false, afterModifyPosition: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false, afterDonate: false
        });
    }

    /**
     * @notice Verifies a Brevis ZK proof passed via hookData before allowing swap.
     * @dev Expects hookData to be abi.encode(bytes proof, bytes publicInputs)
     *      The structure of publicInputs MUST match CircuitPublicInputs.
     */
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external view override returns (bytes4) {
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
        bool isValid = IBrevisRequest(brevisRequest).validateOpAppData(
            keccak256(abi.encodePacked(zkProof)),
            0, // nonce
            keccak256(publicInputsBytes),
            requiredCircuitId,
            brevisOpConfig.challengeWindow,
            brevisOpConfig.sigOption
        );

        if (!isValid) {
            revert BrevisProofVerificationFailed();
        }

        // Decode and validate public inputs
        CircuitPublicInputs memory publicInputs;
        try abi.decode(publicInputsBytes, (CircuitPublicInputs)) returns (CircuitPublicInputs memory _pi) {
            publicInputs = _pi;
        } catch {
            revert InvalidHookData();
        }

        // Check volatility threshold
        if (publicInputs.historicalVolume > MAX_ALLOWED_VOLATILITY_BPS) {
            revert BrevisConditionNotMet(
                publicInputs.historicalVolume,
                MAX_ALLOWED_VOLATILITY_BPS
            );
        }

        return BrevisVerificationHook.beforeSwap.selector;
    }

    /**
     * @notice Handles ZK proof results from Brevis
     * @dev This is called by BrevisApp's callback mechanism
     */
    function handleProofResult(bytes32 _vkHash, bytes calldata _circuitOutput) internal override {
        // Verify the circuit ID matches
        require(_vkHash == requiredCircuitId, "Invalid circuit ID");
        
        // Decode and process the circuit output
        CircuitPublicInputs memory inputs = abi.decode(_circuitOutput, (CircuitPublicInputs));
        
        // Additional validation can be added here if needed
        if (inputs.historicalVolume > MAX_ALLOWED_VOLATILITY_BPS) {
            revert BrevisConditionNotMet(
                inputs.historicalVolume,
                MAX_ALLOWED_VOLATILITY_BPS
            );
        }
    }

    /**
     * @notice Handles optimistic proof results from Brevis
     * @dev This is called by BrevisApp's optimistic callback mechanism
     */
    function handleOpProofResult(bytes32 _vkHash, bytes calldata _circuitOutput) internal override {
        // For this example, we handle optimistic proofs the same way as ZK proofs
        handleProofResult(_vkHash, _circuitOutput);
    }
}