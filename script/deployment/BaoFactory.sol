// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/***************************************************************
 *  THIS CODE IS UNDER DEVELOPMENT - DO NOT USE IN PRODUCTION  *
 ***************************************************************/

import {CREATE3} from "@solady/utils/CREATE3.sol";
import {Ownable} from "@solady/auth/Ownable.sol";

/// @title Bao Deployer Bootstrap
/// @notice Deterministic CREATE3 wrapper deployed via Nick's Factory
/// @dev No constructor args ensures deterministic address independent of deployer/owner.
///      Authorization is via tx.origin recorded at construction time.
contract BaoFactoryBootstrap {
    error Unauthorized();
    error ValueMismatch(uint256 expected, uint256 received);

    /// @notice The EOA that deployed this contract (recorded via tx.origin)
    address public immutable DEPLOYER;

    /// @dev Records tx.origin as the authorized deployer. No constructor args keeps bytecode constant.
    constructor() {
        DEPLOYER = tx.origin;
    }

    modifier onlyDeployer() {
        if (tx.origin != DEPLOYER) revert Unauthorized();
        _;
    }

    function deploy(bytes32 salt, bytes calldata initCode) external onlyDeployer returns (address deployed) {
        deployed = CREATE3.deployDeterministic(initCode, salt);
    }

    function deploy(
        bytes32 salt,
        bytes calldata initCode,
        uint256 value
    ) external payable onlyDeployer returns (address deployed) {
        if (msg.value != value) revert ValueMismatch(value, msg.value);
        deployed = CREATE3.deployDeterministic(value, initCode, salt);
    }

    function predict(bytes32 salt) external view returns (address predicted) {
        predicted = CREATE3.predictDeterministicAddress(salt);
    }
}

/// @title Bao Deterministic Deployer
/// @notice Non-upgradeable CREATE3 deployer with commit-reveal protection
/// @dev Owner is baked into the constructor (part of CREATE2 address derivation)
/// @dev Operator executes commit → reveal, owner retains direct deploy access for migrations/tests
contract BaoFactory is Ownable {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when operator is updated by the owner
    event OperatorUpdated(address indexed previousOperator, address indexed newOperator);

    /// @notice Emitted when an operator commitment is recorded
    event DeploymentCommitted(bytes32 indexed commitment, address indexed committer, uint40 committedAt);

    /// @notice Emitted when a commitment is cleared without deployment
    event DeploymentCleared(bytes32 indexed commitment, address indexed caller);

    /// @notice Emitted after a successful reveal + deployment
    event DeploymentRevealed(bytes32 indexed commitment, address indexed deployed, bytes32 indexed salt, uint256 value);

    /*//////////////////////////////////////////////////////////////////////////
                                    ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    error OperatorRequired();
    error OwnerRequired();
    error UnauthorizedOperator(address caller);
    error CommitmentAlreadyExists(bytes32 commitment);
    error UnknownCommitment(bytes32 commitment);
    error CommitmentMismatch(bytes32 expected, bytes32 provided);
    error ValueMismatch(uint256 expected, uint256 received);

    /*//////////////////////////////////////////////////////////////////////////
                                   STORAGE
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Current deployment operator (set by owner)
    address public operator;

    /// @notice Commitment timestamp ledger used to guard reuse
    mapping(bytes32 => uint40) private _commitments;

    /*//////////////////////////////////////////////////////////////////////////
                                  CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @param owner_ Address that will permanently own the deployer
    constructor(address owner_) {
        if (owner_ == address(0)) revert OwnerRequired();
        _initializeOwner(owner_);
        operator = tx.origin;
    }

    /*//////////////////////////////////////////////////////////////////////////
                               OPERATOR MANAGEMENT
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Set the operator that may commit and reveal deployments
    /// @param newOperator Address allowed to perform commit/reveal (can be address(0) to disable)
    function setOperator(address newOperator) external onlyOwner {
        address previous = operator;
        operator = newOperator;
        emit OperatorUpdated(previous, newOperator);
    }

    /*//////////////////////////////////////////////////////////////////////////
                               COMMIT → REVEAL FLOW
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Record a deployment commitment (hash of all deployment parameters)
    /// @param commitment keccak256 hash produced via {DeploymentInfrastructure.commitment}
    function commit(bytes32 commitment) external onlyOperator {
        if (commitment == bytes32(0)) revert CommitmentMismatch(bytes32(0), bytes32(0));
        if (_commitments[commitment] != 0) revert CommitmentAlreadyExists(commitment);
        _commitments[commitment] = uint40(block.timestamp);
        emit DeploymentCommitted(commitment, msg.sender, uint40(block.timestamp));
    }

    /// @notice Clear a stale commitment (owner override)
    /// @param commitment Commitment hash to clear
    function clearCommitment(bytes32 commitment) external onlyOwner {
        if (_commitments[commitment] == 0) revert UnknownCommitment(commitment);
        delete _commitments[commitment];
        emit DeploymentCleared(commitment, msg.sender);
    }

    /// @notice Reveal deployment parameters and perform CREATE3 deployment
    /// @param initCode Contract creation bytecode (with constructor args)
    /// @param salt CREATE3 salt used for deterministic address
    /// @param value ETH value forwarded to the constructor
    /// @return deployed Address of the deployed contract
    function reveal(
        bytes memory initCode,
        bytes32 salt,
        uint256 value
    ) external payable onlyOperator returns (address deployed) {
        if (msg.value != value) revert ValueMismatch(value, msg.value);
        bytes32 expected = keccak256(abi.encode(msg.sender, value, salt, keccak256(initCode)));
        if (_commitments[expected] == 0) revert UnknownCommitment(expected);
        delete _commitments[expected];
        deployed = CREATE3.deployDeterministic(value, initCode, salt);
        emit DeploymentRevealed(expected, deployed, salt, value);
    }

    /*//////////////////////////////////////////////////////////////////////////
                             DIRECT OWNER DEPLOYMENT
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Owner convenience method mirroring legacy deployDeterministic
    function deployDeterministic(bytes memory initCode, bytes32 salt) external onlyOwner returns (address deployed) {
        deployed = CREATE3.deployDeterministic(initCode, salt);
        emit DeploymentRevealed(bytes32(0), deployed, salt, 0);
    }

    /// @notice Owner convenience method for value-enabled deployments
    function deployDeterministic(
        uint256 value,
        bytes memory initCode,
        bytes32 salt
    ) external payable onlyOwner returns (address deployed) {
        if (msg.value != value) revert ValueMismatch(value, msg.value);
        deployed = CREATE3.deployDeterministic(value, initCode, salt);
        emit DeploymentRevealed(bytes32(0), deployed, salt, value);
    }

    /// @notice Predict deterministic address identical to legacy API
    function predictDeterministicAddress(bytes32 salt) external view returns (address predicted) {
        predicted = CREATE3.predictDeterministicAddress(salt);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                 VIEW HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Check if a commitment is currently active
    function isCommitted(bytes32 commitment) external view returns (bool) {
        return _commitments[commitment] != 0;
    }

    /// @notice Return the timestamp recorded for a commitment (or zero if none)
    function committedAt(bytes32 commitment) external view returns (uint40) {
        return _commitments[commitment];
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    modifier onlyOperator() {
        if (msg.sender != operator) revert UnauthorizedOperator(msg.sender);
        if (operator == address(0)) revert OperatorRequired();
        _;
    }
}

/*
Example deterministic deployment flow (address depends only on salt + Nick's factory):
    // 1. Deploy BaoFactoryBootstrap via Nick's Factory using CREATE2.
    //    No constructor args → bytecode is constant → address is deterministic.
    //    tx.origin becomes the authorized DEPLOYER.
    bytes memory bootstrapCode = type(BaoFactoryBootstrap).creationCode;
    // factory.call(abi.encodePacked(salt, bootstrapCode));

    // 2. Use the bootstrapper to CREATE3 the BaoFactory with any owner address.
    //    The BaoFactory address depends only on (bootstrap_address, salt), not on owner.
    address deployed = BaoFactoryBootstrap(bootstrap).deploy(
        keccak256("bao.deployer"),
        abi.encodePacked(type(BaoFactory).creationCode, abi.encode(environmentOwner))
    );
*/
