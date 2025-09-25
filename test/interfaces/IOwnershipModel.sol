// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/**
 * @title IOwnershipModel
 * @notice Interface for ownership model adapters
 * @dev Strategy Pattern: Defines common interface for all ownership models
 */
interface IOwnershipModel {
    function implementationType() external view returns (uint256);
    function name() external view returns (string memory);

    function deployImplementation(address prank, address initialOwner) external returns (address implementation);

    function deployProxy(
        address prank,
        address implementation,
        address initialOwner,
        uint256 initialValue
    ) external returns (address proxy);

    function upgradeAndChangeStuff(
        address prank,
        address proxy,
        address implementation,
        address newOwner,
        uint256 newValue
    ) external;
    function upgrade(address prank, address proxy, address implementation) external;

    function unauthorizedSelector() external pure returns (bytes4);
}
