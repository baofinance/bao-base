// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/**
 * @title MockImplementation
 * @notice Mock implementation with initialization
 */
contract MockImplementation {
    uint256 public value;

    function initialize(uint256 _value) external {
        value = _value;
    }
}
