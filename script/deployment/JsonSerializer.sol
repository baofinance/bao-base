// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {LibString} from "@solady/utils/LibString.sol";
import {DateTimeLib} from "@solady/utils/DateTimeLib.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";

/// @notice JSON serialization for deployment state.
library JsonSerializer {
    using LibString for string;

    uint256 internal constant SCHEMA_VERSION = 1;

    function renderState(DeploymentTypes.State memory state) internal view returns (string memory) {
        DeploymentTypes.ImplementationRecord[] memory implementationsSorted = sortedImplementations(
            state.implementations
        );
        DeploymentTypes.ProxyRecord[] memory proxiesSorted = sortedProxies(state.proxies);

        string memory implementationsJson = renderImplementationsMap(implementationsSorted);
        string memory proxiesJson = renderProxiesMap(proxiesSorted, state.saltPrefix);

        return
            string.concat(
                '{"schemaVersion":',
                LibString.toString(SCHEMA_VERSION),
                ',"version":"v1","saltPrefix":',
                _quote(state.saltPrefix),
                ',"network":',
                _quote(state.network),
                ',"chainId":',
                LibString.toString(block.chainid),
                ',"baoFactory":',
                _quote(LibString.toHexStringChecksummed(state.baoFactory)),
                ',"lastUpdated":',
                _quote(_formatTimestamp(block.timestamp)),
                ',"implementations":{',
                implementationsJson,
                '},"proxies":{',
                proxiesJson,
                "}}"
            );
    }

    function renderImplementationsMap(
        DeploymentTypes.ImplementationRecord[] memory records
    ) internal pure returns (string memory body) {
        uint256 length = records.length;
        if (length == 0) {
            return "";
        }
        for (uint256 i = 0; i < length; ++i) {
            DeploymentTypes.ImplementationRecord memory rec = records[i];
            string memory entry = string.concat(
                '"',
                LibString.toHexStringChecksummed(rec.implementation),
                '":{"proxy":',
                _quote(rec.proxy),
                ',"contractSource":',
                _quote(rec.contractSource),
                ',"contractType":',
                _quote(rec.contractType),
                ',"deploymentTime":',
                _quote(_formatTimestamp(uint256(rec.deploymentTime))),
                "}"
            );
            body = bytes(body).length == 0 ? entry : string.concat(body, ",", entry);
        }
    }

    function renderProxiesMap(
        DeploymentTypes.ProxyRecord[] memory records,
        string memory saltPrefix
    ) internal pure returns (string memory body) {
        uint256 length = records.length;
        if (length == 0) {
            return "";
        }
        for (uint256 i = 0; i < length; ++i) {
            DeploymentTypes.ProxyRecord memory rec = records[i];
            string memory combinedSalt = string.concat(saltPrefix, "::", rec.id);
            string memory entry = string.concat(
                '"',
                rec.id,
                '":{"address":',
                _quote(LibString.toHexStringChecksummed(rec.proxy)),
                ',"implementation":',
                _quote(LibString.toHexStringChecksummed(rec.implementation)),
                ',"salt":',
                _quote(combinedSalt),
                ',"deploymentTime":',
                _quote(_formatTimestamp(uint256(rec.deploymentTime))),
                "}"
            );
            body = bytes(body).length == 0 ? entry : string.concat(body, ",", entry);
        }
    }

    /// @notice Count the number of fields in a salt (separated by ::).
    function _countFields(string memory salt) private pure returns (uint256) {
        bytes memory data = bytes(salt);
        uint256 count = 1;
        for (uint256 i = 0; i + 1 < data.length; ++i) {
            if (data[i] == ":" && data[i + 1] == ":") {
                ++count;
                ++i;
            }
        }
        return count;
    }

    /// @notice Compare two salt strings for field-aware sorting.
    /// @dev Compares field-by-field. Within fields, lexicographic. Fewer remaining fields wins as tiebreaker.
    /// @return -1 if a < b, 0 if equal, 1 if a > b
    function _compareSalt(
        string memory a,
        uint256 fieldsA,
        string memory b,
        uint256 fieldsB
    ) private pure returns (int256) {
        bytes memory bytesA = bytes(a);
        bytes memory bytesB = bytes(b);
        uint256 lenA = bytesA.length;
        uint256 lenB = bytesB.length;

        uint256 i;
        uint256 j;
        uint256 fieldA = 1;
        uint256 fieldB = 1;

        while (i < lenA && j < lenB) {
            bool delimA = i + 1 < lenA && bytesA[i] == ":" && bytesA[i + 1] == ":";
            bool delimB = j + 1 < lenB && bytesB[j] == ":" && bytesB[j + 1] == ":";

            if (delimA && delimB) {
                // Both at field boundary - compare remaining field counts
                if (fieldsA - fieldA < fieldsB - fieldB) return -1;
                if (fieldsA - fieldA > fieldsB - fieldB) return 1;
                // Same remaining, continue to next field
                i += 2;
                j += 2;
                ++fieldA;
                ++fieldB;
            } else if (delimA) {
                return -1; // A's field ended first (shorter field)
            } else if (delimB) {
                return 1; // B's field ended first (shorter field)
            } else {
                if (bytesA[i] < bytesB[j]) return -1;
                if (bytesA[i] > bytesB[j]) return 1;
                ++i;
                ++j;
            }
        }

        // One or both exhausted - compare remaining fields
        if (i < lenA) {
            if (fieldsA - fieldA > fieldsB - fieldB) return 1;
            if (fieldsA - fieldA < fieldsB - fieldB) return -1;
            return 1;
        }
        if (j < lenB) {
            if (fieldsB - fieldB > fieldsA - fieldA) return -1;
            if (fieldsB - fieldB < fieldsA - fieldA) return 1;
            return -1;
        }
        return 0;
    }

    function sortedImplementations(
        DeploymentTypes.ImplementationRecord[] memory records
    ) internal pure returns (DeploymentTypes.ImplementationRecord[] memory) {
        uint256 len = records.length;
        DeploymentTypes.ImplementationRecord[] memory sorted = new DeploymentTypes.ImplementationRecord[](len);
        uint256[] memory fieldCounts = new uint256[](len);

        for (uint256 i = 0; i < len; ++i) {
            sorted[i] = records[i];
            fieldCounts[i] = _countFields(records[i].proxy);
        }

        // Selection sort with cached field counts
        for (uint256 i = 0; i < len; ++i) {
            uint256 minIndex = i;
            for (uint256 j = i + 1; j < len; ++j) {
                int256 cmp = _compareSalt(
                    sorted[j].proxy,
                    fieldCounts[j],
                    sorted[minIndex].proxy,
                    fieldCounts[minIndex]
                );
                if (cmp < 0 || (cmp == 0 && sorted[j].deploymentTime < sorted[minIndex].deploymentTime)) {
                    minIndex = j;
                }
            }
            if (minIndex != i) {
                DeploymentTypes.ImplementationRecord memory tmpRec = sorted[i];
                sorted[i] = sorted[minIndex];
                sorted[minIndex] = tmpRec;
                uint256 tmpCount = fieldCounts[i];
                fieldCounts[i] = fieldCounts[minIndex];
                fieldCounts[minIndex] = tmpCount;
            }
        }
        return sorted;
    }

    function sortedProxies(
        DeploymentTypes.ProxyRecord[] memory records
    ) internal pure returns (DeploymentTypes.ProxyRecord[] memory) {
        uint256 len = records.length;
        DeploymentTypes.ProxyRecord[] memory sorted = new DeploymentTypes.ProxyRecord[](len);
        uint256[] memory fieldCounts = new uint256[](len);

        for (uint256 i = 0; i < len; ++i) {
            sorted[i] = records[i];
            fieldCounts[i] = _countFields(records[i].id);
        }

        // Selection sort with cached field counts
        for (uint256 i = 0; i < len; ++i) {
            uint256 minIndex = i;
            for (uint256 j = i + 1; j < len; ++j) {
                if (_compareSalt(sorted[j].id, fieldCounts[j], sorted[minIndex].id, fieldCounts[minIndex]) < 0) {
                    minIndex = j;
                }
            }
            if (minIndex != i) {
                DeploymentTypes.ProxyRecord memory tmpRec = sorted[i];
                sorted[i] = sorted[minIndex];
                sorted[minIndex] = tmpRec;
                uint256 tmpCount = fieldCounts[i];
                fieldCounts[i] = fieldCounts[minIndex];
                fieldCounts[minIndex] = tmpCount;
            }
        }
        return sorted;
    }

    function _quote(string memory value) private pure returns (string memory) {
        bytes memory data = bytes(value);
        uint256 length = data.length;
        uint256 escapes;
        for (uint256 i = 0; i < length; ++i) {
            if (data[i] == bytes1('"') || data[i] == bytes1("\\")) {
                ++escapes;
            }
        }
        bytes memory buffer = new bytes(length + escapes + 2);
        uint256 index;
        buffer[index++] = bytes1('"');
        for (uint256 i = 0; i < length; ++i) {
            bytes1 char = data[i];
            if (char == bytes1('"') || char == bytes1("\\")) {
                buffer[index++] = bytes1("\\");
            }
            buffer[index++] = char;
        }
        buffer[index] = bytes1('"');
        return string(buffer);
    }

    function _formatTimestamp(uint256 timestamp) private pure returns (string memory) {
        (uint256 year, uint256 month, uint256 day, uint256 hour, uint256 minute, uint256 second) = DateTimeLib
            .timestampToDateTime(timestamp);
        return
            string.concat(
                _pad(year, 4),
                "-",
                _pad(month, 2),
                "-",
                _pad(day, 2),
                "T",
                _pad(hour, 2),
                ":",
                _pad(minute, 2),
                ":",
                _pad(second, 2),
                "Z"
            );
    }

    function _pad(uint256 value, uint256 width) private pure returns (string memory) {
        string memory base = LibString.toString(value);
        bytes memory baseBytes = bytes(base);
        if (baseBytes.length >= width) {
            return base;
        }
        bytes memory buffer = new bytes(width);
        uint256 padLen = width - baseBytes.length;
        for (uint256 i = 0; i < padLen; ++i) {
            buffer[i] = "0";
        }
        for (uint256 i = 0; i < baseBytes.length; ++i) {
            buffer[padLen + i] = baseBytes[i];
        }
        return string(buffer);
    }
}
