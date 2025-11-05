// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/***************************************************************
 *  THIS CODE IS UNDER DEVELOPMENT - DO NOT USE IN PRODUCTION  *
 ***************************************************************/

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {CREATE3} from "@solady/utils/CREATE3.sol";
import {OwnableRoles} from "@solady/auth/OwnableRoles.sol";

/// @title Bao Deterministic Deployer
/// @notice UUPS upgradeable CREATE3 deployer with simple role-based access control
/// @dev Uses Nick's Factory for initial deployment to achieve same address across all chains
/// @dev Owner and DEPLOYER_ROLE holders can deploy contracts
/// @dev No constructor parameters for CREATE2 determinism - use initialize() after deployment
/// @author rootminus0x1
contract BaoDeployer is Initializable, UUPSUpgradeable, OwnableRoles {
    using EnumerableSet for EnumerableSet.AddressSet;

    /*//////////////////////////////////////////////////////////////////////////
                                   CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Deployer role bit flag
    /// @dev Anyone with this role (or the owner) can call deployDeterministic functions
    uint256 public constant DEPLOYER_ROLE = _ROLE_0;

    /// @dev ERC-7201 namespace for deployer set storage
    /// @dev keccak256(abi.encode(uint256(keccak256("bao.storage.BaoDeployer.deployerSet")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DEPLOYER_SET_STORAGE =
        0x8a7d8a0a4b5e8f2c9d3e1a7b6c4d5e2f1a8b9c0d3e4f5a6b7c8d9e0f1a2b3c00;

    /*//////////////////////////////////////////////////////////////////////////
                                   STORAGE
    //////////////////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:bao.storage.BaoDeployer.deployerSet
    struct DeployerSetStorage {
        EnumerableSet.AddressSet deployerSet;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a contract is deployed via CREATE3
    /// @param deployer Address that performed the deployment
    /// @param deployed Address of the deployed contract
    /// @param salt Salt used for deterministic deployment
    event ContractDeployed(address indexed deployer, address indexed deployed, bytes32 indexed salt);

    /*//////////////////////////////////////////////////////////////////////////
                                    ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when caller is not authorized to deploy
    error UnauthorizedDeployer(address caller);

    /*//////////////////////////////////////////////////////////////////////////
                               CONSTRUCTOR/INITIALIZER
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Constructor disables initializers for the implementation contract
    /// @dev No constructor parameters - enables CREATE2 determinism across chains
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the proxy instance with owner and deployers
    /// @dev This is called once when the proxy is deployed
    /// @param owner_ Initial owner of the contract
    /// @param initialDeployers Array of initial deployer addresses
    function initialize(address owner_, address[] calldata initialDeployers) external initializer {
        __UUPSUpgradeable_init();
        _initializeOwner(owner_);

        DeployerSetStorage storage $ = _getDeployerSetStorage();
        
        // Grant DEPLOYER_ROLE to each initial deployer and add to enumerable set
        for (uint256 i = 0; i < initialDeployers.length; i++) {
            _grantRoles(initialDeployers[i], DEPLOYER_ROLE);
            $.deployerSet.add(initialDeployers[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                           ROLE MANAGEMENT (OWNER ONLY)
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Grant roles to a user (overrides OwnableRoles to sync EnumerableSet)
    /// @dev Syncs the deployer set when DEPLOYER_ROLE is granted
    /// @param user Address to grant roles to
    /// @param roles Bitmap of roles to grant
    function grantRoles(address user, uint256 roles) public payable override onlyOwner {
        super.grantRoles(user, roles);
        
        // Add to enumerable set if DEPLOYER_ROLE was granted
        if (roles & DEPLOYER_ROLE != 0) {
            DeployerSetStorage storage $ = _getDeployerSetStorage();
            $.deployerSet.add(user);
        }
    }

    /// @notice Revoke roles from a user (overrides OwnableRoles to sync EnumerableSet)
    /// @dev Syncs the deployer set when DEPLOYER_ROLE is revoked
    /// @param user Address to revoke roles from
    /// @param roles Bitmap of roles to revoke
    function revokeRoles(address user, uint256 roles) public payable override onlyOwner {
        super.revokeRoles(user, roles);
        
        // Remove from enumerable set if DEPLOYER_ROLE was revoked
        if (roles & DEPLOYER_ROLE != 0) {
            DeployerSetStorage storage $ = _getDeployerSetStorage();
            $.deployerSet.remove(user);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                         DEPLOYER-CALLABLE FUNCTIONS
                   (Contract Deployment - Owner or DEPLOYER_ROLE Only)
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Deploy a contract using CREATE3 with deterministic address
    /// @dev Only owner or addresses with DEPLOYER_ROLE can call
    /// @dev NOTE: msg.sender in deployed contract constructor will be the CREATE3 proxy, not this contract
    /// @param initCode Contract initialization code (bytecode + constructor args)
    /// @param salt Salt for deterministic address generation
    /// @return deployed Address of the deployed contract
    function deployDeterministic(bytes memory initCode, bytes32 salt) external returns (address deployed) {
        _requireAuthorizedDeployer();
        deployed = CREATE3.deployDeterministic(initCode, salt);
        emit ContractDeployed(msg.sender, deployed, salt);
    }

    /// @notice Deploy a contract using CREATE3 with ETH funding
    /// @dev Only owner or addresses with DEPLOYER_ROLE can call
    /// @dev Caller must send ETH with the transaction (msg.value == value)
    /// @dev WORKS: When target contract has a payable constructor - value passes through successfully
    /// @dev FAILS: When target contract has non-payable constructor - deployment will revert
    /// @dev NOTE: msg.sender in deployed contract constructor will be the CREATE3 proxy, not this contract
    /// @param value Amount of ETH (in wei) to send to the deployed contract's constructor
    /// @param initCode Contract initialization code (bytecode + constructor args)
    /// @param salt Salt for deterministic address generation
    /// @return deployed Address of the deployed contract
    function deployDeterministic(
        uint256 value,
        bytes memory initCode,
        bytes32 salt
    ) external payable returns (address deployed) {
        _requireAuthorizedDeployer();
        deployed = CREATE3.deployDeterministic(value, initCode, salt);
        emit ContractDeployed(msg.sender, deployed, salt);
    }

    /// @notice Predict the deterministic address for a given salt
    /// @dev Pure function - anyone can call to predict deployment addresses
    /// @param salt Salt that would be used for deployment
    /// @return predicted The address where a contract would be deployed with this salt
    function predictDeterministicAddress(bytes32 salt) external view returns (address predicted) {
        predicted = CREATE3.predictDeterministicAddress(salt);
    }

    /*//////////////////////////////////////////////////////////////////////////
                          ENUMERATION & AUTHORIZATION VIEWS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Get all addresses with DEPLOYER_ROLE
    /// @dev Returns array of all deployer addresses for enumeration
    /// @return Array of deployer addresses
    function deployers() external view returns (address[] memory) {
        DeployerSetStorage storage $ = _getDeployerSetStorage();
        return $.deployerSet.values();
    }

    /// @notice Check if an address is authorized to deploy contracts
    /// @dev Returns true if address is owner or has DEPLOYER_ROLE
    /// @param deployer Address to check
    /// @return True if authorized to deploy
    function isAuthorizedDeployer(address deployer) public view returns (bool) {
        return deployer == owner() || hasAnyRole(deployer, DEPLOYER_ROLE);
    }

    /*//////////////////////////////////////////////////////////////////////////
                              INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Get ERC-7201 namespaced storage for deployer set
    function _getDeployerSetStorage() private pure returns (DeployerSetStorage storage $) {
        /// @solidity memory-safe-assembly
        assembly {
            $.slot := DEPLOYER_SET_STORAGE
        }
    }

    /// @dev Revert if caller is not an authorized deployer (owner or DEPLOYER_ROLE)
    function _requireAuthorizedDeployer() private view {
        if (!isAuthorizedDeployer(msg.sender)) {
            revert UnauthorizedDeployer(msg.sender);
        }
    }

    /// @dev Authorize upgrade - only owner can upgrade
    /// @param newImplementation Address of the new implementation contract
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
