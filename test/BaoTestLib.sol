// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice Number and string helpers for tests, covering the cases Solady's `LibString` does not:
///         fixed-point decimal formatting, thousands separators, parsing a decimal string back to a
///         scaled integer, and joining. For plain integer-to-string, hex, and equality use
///         `LibString` / `LibBytes` directly.
library BaoTestLib {
    bytes16 private constant _SYMBOLS = "0123456789abcdef";

    uint8 internal constant comma = 44;
    uint8 internal constant underscore = 95;

    bytes1 private constant zero = bytes1(uint8(48));
    bytes1 private constant nine = bytes1(uint8(57));
    bytes1 private constant decimalPoint = bytes(".")[0];
    bytes1 private constant percent = bytes1(uint8(37));

    /// @dev Decimal digit count, counting an explicit "0" as one digit rather than none.
    function _length(uint256 value) private pure returns (uint256 digits) {
        for (uint256 j = value; j != 0; j /= 10) {
            digits++;
        }
        if (digits == 0) digits = 1; // always a "0";
    }

    /// @dev `value` rendered with a decimal point `decimals` places from the right, left-padded with
    ///      "0." and leading zeros when the value has fewer digits than that.
    function toStringScaled(uint256 value, uint256 decimals) internal pure returns (string memory buffer) {
        uint256 digits = _length(value);
        uint256 length = digits;
        if (decimals > 0) {
            if (length > decimals) {
                length++; // for the decimal point
            } else {
                length = decimals + 2; // "0.", "0.00...n",  prefix
                digits = decimals + 1;
            }
        }

        buffer = new string(length);
        uint256 ptr;
        /// @solidity memory-safe-assembly
        assembly {
            ptr := add(buffer, add(32, length))
        }
        uint256 digit = 0;
        while (digit < digits) {
            if (decimals > 0 && digit == decimals) {
                /// @solidity memory-safe-assembly
                ptr--;
                assembly {
                    mstore8(ptr, 46)
                }
            }
            ptr--;
            /// @solidity memory-safe-assembly
            assembly {
                mstore8(ptr, byte(mod(value, 10), _SYMBOLS))
            }
            digit++;
            value /= 10;
        }
    }

    function toStringScaled(int256 value, uint256 decimals) internal pure returns (string memory buffer) {
        if (value >= 0) return toStringScaled(uint256(value), decimals);
        return string.concat("-", toStringScaled(uint256(-value), decimals));
    }

    /// @dev `value` in decimal with `separator` inserted every three digits from the right. A
    ///      `separator` of 0 inserts none.
    function toStringThousands(uint256 value, uint8 separator) internal pure returns (string memory buffer) {
        uint256 digits = _length(value);

        uint256 separators = 0;
        if (separator > 0) {
            // calculate the number of separators given the length
            // 1 - 3 => 0; 4 - 6 => 1; 7 - 9 => 2; etc.
            separators = (digits - 1) / 3;
        }
        uint256 length = digits + separators;

        buffer = new string(length);
        uint256 ptr;
        /// @solidity memory-safe-assembly
        assembly {
            ptr := add(buffer, add(32, length))
        }
        uint256 digit = 0;
        while (digit < digits) {
            ptr--;
            /// @solidity memory-safe-assembly
            assembly {
                mstore8(ptr, byte(mod(value, 10), _SYMBOLS))
            }
            digit++;
            value /= 10;
            if ((separators > 0) && (digit % 3 == 0)) {
                ptr--;
                /// @solidity memory-safe-assembly
                assembly {
                    mstore8(ptr, separator)
                }
                separators--;
            }
        }
    }

    /// @dev The inverse of `toStringScaled`: parses a decimal string to an integer scaled by
    ///      `decimals`. A trailing "%" is permitted and divides the result by 100.
    function toUint256(string memory value, uint256 decimals) internal pure returns (uint256 result) {
        uint256 length = bytes(value).length;
        uint256 point = length; // if there's none there, it's after all the digits
        uint256 digits = 0;
        for (uint256 i = 0; i < length; i++) {
            bytes1 char = bytes(value)[i];
            if (char == decimalPoint) {
                point = i;
            } else if (char >= zero && char <= nine) {
                result = result * 10 + uint8(char) - uint8(zero);
                digits++;
            } else if (char == percent) {
                require(i == length - 1, "% character, if present, must be at the end");
                decimals -= 2; // same as * 100
                if (point == length) point--;
            } else {
                require(false, "invalid character in numeric string");
            }
        }
        if ((point + decimals) > digits) {
            result = result * 10 ** ((point + decimals) - digits);
        } else if ((point + decimals) < digits) {
            result = result / 10 ** (digits - (point + decimals));
        }
    }

    function join(string[] memory strings, string memory separator) internal pure returns (string memory) {
        if (strings.length == 0) {
            return "";
        }

        string memory result = strings[0];
        for (uint i = 1; i < strings.length; i++) {
            result = string.concat(result, separator, strings[i]);
        }
        return result;
    }

    function extractUInt256(bytes memory data, uint256 pos) internal pure returns (uint256 result) {
        require((pos + 256 / 8) <= data.length, "don't read beyond the data");
        uint256 endian = pos + 32;
        assembly {
            result := mload(add(data, endian))
        }
    }
}
