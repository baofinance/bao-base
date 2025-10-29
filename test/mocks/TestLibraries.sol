// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/**
 * @title TestLibraries
 * @notice Common libraries for deployment testing
 * @dev Centralized location for all test libraries to reduce duplication
 */

// Simple math library
library MathLib {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        return a + b;
    }

    function multiply(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b;
    }

    function divide(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "Division by zero");
        return a / b;
    }
}

// String utilities library
library StringLib {
    function concat(string memory a, string memory b) internal pure returns (string memory) {
        return string(abi.encodePacked(a, b));
    }

    function length(string memory str) internal pure returns (uint256) {
        return bytes(str).length;
    }

    function isEmpty(string memory str) internal pure returns (bool) {
        return bytes(str).length == 0;
    }
}

// Address utilities library
library AddressLib {
    function isContract(address addr) internal view returns (bool) {
        return addr.code.length > 0;
    }

    function isZero(address addr) internal pure returns (bool) {
        return addr == address(0);
    }
}

// Array utilities library
library ArrayLib {
    function contains(address[] memory array, address element) internal pure returns (bool) {
        for (uint256 i = 0; i < array.length; i++) {
            if (array[i] == element) {
                return true;
            }
        }
        return false;
    }

    function indexOf(address[] memory array, address element) internal pure returns (uint256) {
        for (uint256 i = 0; i < array.length; i++) {
            if (array[i] == element) {
                return i;
            }
        }
        revert("Element not found");
    }
}
