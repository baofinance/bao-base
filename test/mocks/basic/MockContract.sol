// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/**
 * @title MockContract
 * @notice Simple mock contract with name
 */
contract MockContract {
    string public name;

    constructor(string memory _name) {
        name = _name;
    }
}
