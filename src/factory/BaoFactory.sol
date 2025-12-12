// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CREATE3} from "@solady/utils/CREATE3.sol";
import {LibClone} from "@solady/utils/LibClone.sol";
import {UUPSUpgradeable} from "@solady/utils/UUPSUpgradeable.sol";
import {EnumerableMapLib} from "@solady/utils/EnumerableMapLib.sol";

import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";

/// @title BaoFactoryOwnerless
/// @author Bao Finance
/// @notice UUPS-upgradeable deterministic deployer using CREATE3
/// @dev Deployed via Nick's Factory for cross-chain address consistency.
///      Owner is a compile-time constant - not transferable other than by upgrade
///      Operators are temporary deployers with expiry timestamps.
///
/// Architecture:
/// - Owner: Hardcoded
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
/// 4. Interact with the factory through the proxy address, not the implementation.
///    (both have the same owner and will deploy to different addresses)
///
/// To compute the proxy address off-chain:
///   implementation = predictNicksFactoryAddress(salt, initCodeHash)
///   proxy = address(uint160(uint256(keccak256(abi.encodePacked(
///       bytes1(0xd6), bytes1(0x94), implementation, bytes1(0x01)
///   )))))
///
contract BaoFactory is IBaoFactory, UUPSUpgradeable {
    using EnumerableMapLib for EnumerableMapLib.AddressToUint256Map;

    /*//////////////////////////////////////////////////////////////////////////
                                   STORAGE
    //////////////////////////////////////////////////////////////////////////*/

    address private constant _OWNER = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;

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
    function setOperator(address operator_, uint256 delay) external {
        _onlyOwner();

        if (delay == 0) {
            _operators.remove(operator_);
            emit OperatorRemoved(operator_);
        } else if (delay > 100 * 52 weeks) {
            revert InvalidDelay(delay);
        } else {
            uint256 expiry = block.timestamp + delay;
            _operators.set(operator_, expiry);
            emit OperatorSet(operator_, expiry);
        }
    }

    /// @notice Enumerate all registered operators (including expired)
    /// @dev Expired operators remain in storage until explicitly removed
    /// @return addrs Array of operator addresses
    /// @return expiries Parallel array of expiry timestamps
    function operators() external view returns (address[] memory addrs, uint256[] memory expiries) {
        uint256 len = _operators.length();
        addrs = new address[](len);
        expiries = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 rawExpiry;
            (addrs[i], rawExpiry) = _operators.at(i);
            expiries[i] = uint256(rawExpiry);
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
    function deploy(bytes memory initCode, bytes32 salt) external returns (address deployed) {
        _onlyOwnerOrOperator();

        deployed = CREATE3.deployDeterministic(initCode, salt);
        emit Deployed(deployed, salt, 0);
    }

    /// @notice Deploy a contract deterministically with ETH funding
    /// @dev Value is forwarded to the deployed contract's constructor
    /// @param value ETH amount to send (must equal msg.value)
    /// @param initCode Contract creation bytecode including constructor args
    /// @param salt Unique salt for deterministic address derivation
    /// @return deployed Address of the newly deployed contract
    function deploy(uint256 value, bytes memory initCode, bytes32 salt) external payable returns (address deployed) {
        _onlyOwnerOrOperator();

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
    function _authorizeUpgrade(address) internal view override {
        _onlyOwner();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                   Ownership
    //////////////////////////////////////////////////////////////////////////*/

    function owner() external pure returns (address) {
        return _OWNER;
    }

    /*//////////////////////////////////////////////////////////////////////////
                             ACCESS CONTROL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function _onlyOwner() private view {
        if (msg.sender != _OWNER) {
            revert Unauthorized();
        }
    }

    /// @dev Restrict to owner or valid (non-expired) operator
    ///      Owner check is first since it's a cheap constant comparison
    function _onlyOwnerOrOperator() private view {
        if (msg.sender != _OWNER) {
            (bool exists, uint256 expiry) = _operators.tryGet(msg.sender);
            if (!exists || expiry <= block.timestamp) {
                revert Unauthorized();
            }
        }
    }
}
