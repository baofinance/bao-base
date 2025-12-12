// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/***************************************************************
 *  THIS CODE IS UNDER DEVELOPMENT - DO NOT USE IN PRODUCTION  *
 ***************************************************************/

/// @title IBaoFactory
/// @notice Interface for BaoFactory - errors, events, and external functions
/// @dev Import this interface instead of BaoFactoryOwnerless for cleaner dependencies
interface IBaoFactory {
    /*//////////////////////////////////////////////////////////////////////////
                                    ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Caller is not owner or a valid (non-expired) operator
    error Unauthorized();

    /// @notice attempt to set a delay that is out of range;
    error InvalidDelay(uint256 delay);

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
    event OperatorSet(address indexed operator, uint256 expiry);

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
    function operators() external view returns (address[] memory addrs, uint256[] memory expiries);

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
