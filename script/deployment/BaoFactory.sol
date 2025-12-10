// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/***************************************************************
 *  THIS CODE IS UNDER DEVELOPMENT - DO NOT USE IN PRODUCTION  *
 ***************************************************************/

import {CREATE3} from "@solady/utils/CREATE3.sol";
import {LibClone} from "@solady/utils/LibClone.sol";
import {UUPSUpgradeable} from "@solady/utils/UUPSUpgradeable.sol";
import {EnumerableMapLib} from "@solady/utils/EnumerableMapLib.sol";

/// @title IBaoFactory
/// @notice Interface for BaoFactory - errors, events, and external functions
/// @dev Import this interface instead of BaoFactoryOwnerless for cleaner dependencies
interface IBaoFactory {
    /*//////////////////////////////////////////////////////////////////////////
                                    ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Caller is not owner or a valid (non-expired) operator
    error Unauthorized();

    /// @notice msg.value does not match the declared value parameter
    /// @param expected The value parameter passed to deploy()
    /// @param received The actual msg.value
    error ValueMismatch(uint256 expected, uint256 received);

    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when an operator is added or has expiry extended
    /// @param operator The operator address
    /// @param expiry Unix timestamp when operator access expires
    event OperatorSet(address indexed operator, uint40 expiry);

    /// @notice Emitted when an operator is explicitly removed
    /// @param operator The operator address that was removed
    event OperatorRemoved(address indexed operator);

    /// @notice Emitted after a successful CREATE3 deployment
    /// @param deployed The address of the newly deployed contract
    /// @param salt The salt used for deterministic address derivation
    /// @param value ETH value sent to the deployed contract's constructor
    event Deployed(address indexed deployed, bytes32 indexed salt, uint256 value);

    /// @notice Emitted when the BaoFactory proxy is deployed
    /// @param proxy The proxy address that should be used for all interactions
    /// @param implementation The implementation address (this contract)
    event BaoFactoryDeployed(address indexed proxy, address indexed implementation);

    /*//////////////////////////////////////////////////////////////////////////
                                  FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Owner address (hardcoded constant)
    function owner() external view returns (address);

    /// @notice Add, update, or remove an operator
    /// @param operator_ Address to grant or revoke operator privileges
    /// @param delay Duration in seconds from now until expiry (0 = remove)
    function setOperator(address operator_, uint256 delay) external;

    /// @notice Enumerate all registered operators (including expired)
    /// @return addrs Array of operator addresses
    /// @return expiries Parallel array of expiry timestamps
    function operators() external view returns (address[] memory addrs, uint40[] memory expiries);

    /// @notice Check if an address is currently a valid operator
    /// @param addr Address to check
    /// @return True if addr is registered and not expired
    function isCurrentOperator(address addr) external view returns (bool);

    /// @notice Deploy a contract deterministically via CREATE3
    /// @param initCode Contract creation bytecode including constructor args
    /// @param salt Unique salt for deterministic address derivation
    /// @return deployed Address of the newly deployed contract
    function deploy(bytes memory initCode, bytes32 salt) external returns (address deployed);

    /// @notice Deploy a contract deterministically with ETH funding
    /// @param value ETH amount to send (must equal msg.value)
    /// @param initCode Contract creation bytecode including constructor args
    /// @param salt Unique salt for deterministic address derivation
    /// @return deployed Address of the newly deployed contract
    function deploy(uint256 value, bytes memory initCode, bytes32 salt) external payable returns (address deployed);

    /// @notice Compute the deterministic address for a given salt
    /// @param salt The salt that would be used for deployment
    /// @return predicted The address where a contract would be deployed
    function predictAddress(bytes32 salt) external view returns (address predicted);
}

/// @title BaoFactoryLib
/// @notice Library for predicting BaoFactory addresses
/// @dev Used by deployment infrastructure to compute deterministic addresses
///
/// Salt format follows namespace storage pattern: "Bao.BaoFactory{Name}.v1"
/// - Production: "Bao.BaoFactory.v1"
/// - Testing:    "Bao.BaoFactoryTesting.v1"
/// - etc.
library BaoFactoryLib {
    /// @notice Nick's Factory address (same on all EVM chains)
    address internal constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Production BaoFactory salt
    string internal constant PRODUCTION_SALT = "Bao.BaoFactory.v1";

    /// @notice Production BaoFactory owner (Harbor multisig)
    address internal constant PRODUCTION_OWNER = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;

    /// @notice Predict BaoFactory implementation address (CREATE2 via Nick's Factory)
    /// @param factorySalt Salt string (e.g., "Bao.BaoFactory.v1")
    /// @param creationCodeHash keccak256 of BaoFactory creation code
    /// @return implementation The predicted implementation address
    function predictImplementation(
        string memory factorySalt,
        bytes32 creationCodeHash
    ) internal pure returns (address implementation) {
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), NICKS_FACTORY, keccak256(bytes(factorySalt)), creationCodeHash)
        );
        implementation = address(uint160(uint256(hash)));
    }

    /// @notice Predict BaoFactory proxy address from implementation address
    /// @dev Uses RLP-encoded CREATE formula: keccak256(rlp([sender, nonce]))[12:]
    ///      Implementation deploys proxy as first CREATE (nonce=1)
    /// @param implementation The implementation address that will deploy the proxy
    /// @return proxy The predicted proxy address
    function predictProxy(address implementation) internal pure returns (address proxy) {
        // RLP encoding for [address, 1]: 0xd6 0x94 <20-byte-address> 0x01
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), implementation, bytes1(0x01)));
        proxy = address(uint160(uint256(hash)));
    }

    /// @notice Predict both implementation and proxy addresses
    /// @param factorySalt Salt string (e.g., "Bao.BaoFactory.v1")
    /// @param implCreationCodeHash keccak256 of BaoFactory creation code
    /// @return implementation The predicted implementation address
    /// @return proxy The predicted proxy address
    function predictAddresses(
        string memory factorySalt,
        bytes32 implCreationCodeHash
    ) internal pure returns (address implementation, address proxy) {
        implementation = predictImplementation(factorySalt, implCreationCodeHash);
        proxy = predictProxy(implementation);
    }
}

/// @title BaoFactoryOwnerless
/// @author Bao Finance
/// @notice UUPS-upgradeable deterministic deployer using CREATE3
/// @dev Deployed via Nick's Factory for cross-chain address consistency.
///      Owner is a compile-time constant - not transferable.
///      Operators are temporary deployers with expiry timestamps.
///
/// Architecture:
/// - Owner: Hardcoded constant, can upgrade contract and manage operators
/// - Operators: Time-limited deployers, set by owner with expiry delay
/// - Deployments: CREATE3 for address determinism independent of initCode
///
/// Security model:
/// - Owner controls upgrades and operator lifecycle
/// - Operators can only deploy, cannot modify contract state
/// - Expired operators are automatically invalidated (no cleanup needed)
///
/// Deployment:
/// 1. Deploy this implementation via Nick's Factory (0x4e59b44847b379578588920cA78FbF26c0B4956C)
///    with a chosen salt to get a deterministic implementation address
/// 2. The constructor automatically deploys an ERC1967Proxy pointing to itself
/// 3. The proxy address is deterministic: keccak256(rlp([implementation_address, 1]))[12:]
///    This works because the implementation's address is deterministic (Nick's Factory)
///    and the nonce for the first CREATE is always 1
/// 4. Interact with the factory through the proxy address, not the implementation
///
/// To compute the proxy address off-chain:
///   implementation = predictNicksFactoryAddress(salt, initCodeHash)
///   proxy = address(uint160(uint256(keccak256(abi.encodePacked(
///       bytes1(0xd6), bytes1(0x94), implementation, bytes1(0x01)
///   )))))
///
/// Variants:
/// - Production variant (BaoFactory) is defined below with hardcoded owner
/// - Other variants (Testing, RootMinus0x1, etc.) are generated by the
///   extract-bytecode-baofactory script from the VARIANTS config
/// - To add a variant: edit VARIANTS in the script and run yarn extract-bytecode-baofactory
abstract contract BaoFactoryOwnerless is IBaoFactory, UUPSUpgradeable {
    using EnumerableMapLib for EnumerableMapLib.AddressToUint256Map;

    /*//////////////////////////////////////////////////////////////////////////
                                   STORAGE
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Operator address → expiry timestamp mapping
    ///      Uses EnumerableMapLib for gas-efficient iteration and O(1) lookups
    EnumerableMapLib.AddressToUint256Map private _operators;

    /*//////////////////////////////////////////////////////////////////////////
                                  CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Deploys the ERC1967Proxy pointing to this implementation
    /// @dev The proxy address is deterministic based on this implementation's address
    ///      Proxy = keccak256(rlp([address(this), 1]))[12:]
    ///      Since nonce=1 for a fresh contract's first CREATE, this is predictable
    ///      Uses Solady's LibClone for a gas-optimized 61-byte ERC1967 proxy
    constructor() {
        address proxy = LibClone.deployERC1967(address(this));
        emit BaoFactoryDeployed(proxy, address(this));
    }

    /*//////////////////////////////////////////////////////////////////////////
                               OPERATOR MANAGEMENT
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Add, update, or remove an operator
    /// @dev Setting delay=0 removes the operator; any other value sets expiry
    /// @param operator_ Address to grant or revoke operator privileges
    /// @param delay Duration in seconds from now until expiry (0 = remove)
    function setOperator(address operator_, uint256 delay) external onlyOwner {
        if (delay == 0) {
            _operators.remove(operator_);
            emit OperatorRemoved(operator_);
        } else {
            uint40 expiry = uint40(block.timestamp + delay);
            _operators.set(operator_, expiry);
            emit OperatorSet(operator_, expiry);
        }
    }

    /// @notice Enumerate all registered operators (including expired)
    /// @dev Expired operators remain in storage until explicitly removed
    /// @return addrs Array of operator addresses
    /// @return expiries Parallel array of expiry timestamps
    function operators() external view returns (address[] memory addrs, uint40[] memory expiries) {
        uint256 len = _operators.length();
        addrs = new address[](len);
        expiries = new uint40[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 rawExpiry;
            (addrs[i], rawExpiry) = _operators.at(i);
            expiries[i] = uint40(rawExpiry);
        }
    }

    /// @notice Check if an address is currently a valid operator
    /// @param addr Address to check
    /// @return True if addr is registered and not expired
    function isCurrentOperator(address addr) external view returns (bool) {
        (bool exists, uint256 expiry) = _operators.tryGet(addr);
        return exists && expiry > block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  DEPLOYMENT
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Deploy a contract deterministically via CREATE3
    /// @dev Address depends only on this factory's address and salt, not initCode
    /// @param initCode Contract creation bytecode including constructor args
    /// @param salt Unique salt for deterministic address derivation
    /// @return deployed Address of the newly deployed contract
    function deploy(bytes memory initCode, bytes32 salt) external onlyOwnerOrOperator returns (address deployed) {
        deployed = CREATE3.deployDeterministic(initCode, salt);
        emit Deployed(deployed, salt, 0);
    }

    /// @notice Deploy a contract deterministically with ETH funding
    /// @dev Value is forwarded to the deployed contract's constructor
    /// @param value ETH amount to send (must equal msg.value)
    /// @param initCode Contract creation bytecode including constructor args
    /// @param salt Unique salt for deterministic address derivation
    /// @return deployed Address of the newly deployed contract
    function deploy(
        uint256 value,
        bytes memory initCode,
        bytes32 salt
    ) external payable onlyOwnerOrOperator returns (address deployed) {
        if (msg.value != value) {
            revert ValueMismatch(value, msg.value);
        }
        deployed = CREATE3.deployDeterministic(value, initCode, salt);
        emit Deployed(deployed, salt, value);
    }

    /// @notice Compute the deterministic address for a given salt
    /// @dev Address is independent of initCode (CREATE3 property)
    /// @param salt The salt that would be used for deployment
    /// @return predicted The address where a contract would be deployed
    function predictAddress(bytes32 salt) external view returns (address predicted) {
        predicted = CREATE3.predictDeterministicAddress(salt);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  UUPS UPGRADE
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Restrict upgrades to owner only
    function _authorizeUpgrade(address) internal view override onlyOwner {}

    /*//////////////////////////////////////////////////////////////////////////
                                  MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    function _owner() internal view virtual returns (address);

    /// @dev Restrict to owner only
    modifier onlyOwner() {
        if (msg.sender != _owner()) {
            revert Unauthorized();
        }
        _;
    }

    /// @dev Restrict to owner or valid (non-expired) operator
    ///      Owner check is first since it's a cheap constant comparison
    modifier onlyOwnerOrOperator() {
        if (msg.sender != _owner()) {
            (bool exists, uint256 expiry) = _operators.tryGet(msg.sender);
            if (!exists || expiry <= block.timestamp) {
                revert Unauthorized();
            }
        }
        _;
    }
}

/// @title BaoFactory
/// @notice Production BaoFactory with hardcoded Harbor multisig owner
contract BaoFactory is BaoFactoryOwnerless {
    /// @notice Owner address (hardcoded constant - Harbor multisig)
    address public constant owner = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;

    function _owner() internal pure override returns (address) {
        return owner;
    }
}
