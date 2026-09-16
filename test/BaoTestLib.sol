// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DateTimeLib} from "@solady/utils/DateTimeLib.sol";

/// @notice Number and string helpers for tests, covering the cases Solady's `LibString` does not:
///         fixed-point decimal formatting, thousands separators, parsing a decimal string back to a
///         scaled integer, joining, and rendering a unix timestamp as readable UTC. For plain
///         integer-to-string, hex, and equality use `LibString` / `LibBytes` directly, and for
///         calendar arithmetic use `DateTimeLib`.
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

    /// @notice A unix timestamp as `"YYYY-MM-DD HH:MM:SS UTC"`, for a log line a person has to read.
    /// @dev A block timestamp logged as a number tells a reader nothing about when a fork is pinned,
    ///      how stale a feed is, or how far apart two rounds fell. Every field is fixed width and the
    ///      most significant comes first, so the strings also sort chronologically.
    ///
    ///      The calendar arithmetic is Solady's `DateTimeLib` — this only lays the digits out. Years
    ///      of five digits or more cannot fit the four-digit field and wrap within it, which is the
    ///      same limit the format itself has.
    /// @param timestamp Seconds since the unix epoch, as `block.timestamp` reports it.
    function toUtcString(uint256 timestamp) internal pure returns (string memory) {
        (uint256 year, uint256 month, uint256 day, uint256 hour, uint256 minute, uint256 second) = DateTimeLib
            .timestampToDateTime(timestamp);

        bytes memory out = new bytes(23);
        out[0] = _digit((year / 1000) % 10);
        out[1] = _digit((year / 100) % 10);
        out[2] = _digit((year / 10) % 10);
        out[3] = _digit(year % 10);
        out[4] = "-";
        out[5] = _digit(month / 10);
        out[6] = _digit(month % 10);
        out[7] = "-";
        out[8] = _digit(day / 10);
        out[9] = _digit(day % 10);
        out[10] = " ";
        out[11] = _digit(hour / 10);
        out[12] = _digit(hour % 10);
        out[13] = ":";
        out[14] = _digit(minute / 10);
        out[15] = _digit(minute % 10);
        out[16] = ":";
        out[17] = _digit(second / 10);
        out[18] = _digit(second % 10);
        out[19] = " ";
        out[20] = "U";
        out[21] = "T";
        out[22] = "C";
        return string(out);
    }

    /// @dev One decimal digit as its ASCII character.
    function _digit(uint256 value) private pure returns (bytes1) {
        return bytes1(uint8(48 + value));
    }
}
