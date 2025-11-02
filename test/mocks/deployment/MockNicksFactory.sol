// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/**
 * @title MockNicksFactory
 * @notice Mock implementation of Nick's Factory (0x4e59b44847b379578588920cA78FbF26c0B4956C)
 * @dev For testing production deployment flows that use Nick's Factory.
 *      Deploy this mock and use vm.etch() to place it at NICKS_FACTORY address.
 * @dev Usage:
 *      MockNicksFactory mockFactory = new MockNicksFactory();
 *      vm.etch(NICKS_FACTORY, address(mockFactory).code);
 */
contract MockNicksFactory {
    /// @notice Emitted when a contract is deployed
    event ContractDeployed(address indexed deployed, bytes32 indexed salt);

    /**
     * @notice Deploy a contract using CREATE2
     * @dev Mimics Nick's Factory interface: call(abi.encodePacked(salt, bytecode))
     * @dev Calldata format: salt (32 bytes) + creation bytecode
     * @return Address of deployed contract (as bytes32)
     */
    fallback(bytes calldata) external payable returns (bytes memory) {
        // Extract salt and bytecode from calldata
        require(msg.data.length >= 32, "Invalid calldata length");

        bytes32 salt;
        bytes memory bytecode;

        assembly {
            // First 32 bytes are the salt
            salt := calldataload(0)

            // Remaining bytes are the bytecode
            let bytecodeLength := sub(calldatasize(), 32)
            bytecode := mload(0x40)
            mstore(bytecode, bytecodeLength)
            calldatacopy(add(bytecode, 0x20), 32, bytecodeLength)
            mstore(0x40, add(add(bytecode, 0x20), bytecodeLength))
        }

        // Deploy using CREATE2
        address deployed;
        assembly {
            deployed := create2(callvalue(), add(bytecode, 0x20), mload(bytecode), salt)
        }

        require(deployed != address(0), "Deployment failed");

        emit ContractDeployed(deployed, salt);

        // Return the deployed address (as bytes32 for compatibility)
        return abi.encodePacked(bytes32(uint256(uint160(deployed))));
    }

    /// @notice Required to accept ETH
    receive() external payable {}
}
