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
                _quote(LibString.toHexString(state.baoFactory)),
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
                LibString.toHexString(rec.implementation),
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
                _quote(LibString.toHexString(rec.proxy)),
                ',"implementation":',
                _quote(LibString.toHexString(rec.implementation)),
                ',"salt":',
                _quote(combinedSalt),
                ',"deploymentTime":',
                _quote(_formatTimestamp(uint256(rec.deploymentTime))),
                "}"
            );
            body = bytes(body).length == 0 ? entry : string.concat(body, ",", entry);
        }
    }

    function sortedImplementations(
        DeploymentTypes.ImplementationRecord[] memory records
    ) internal pure returns (DeploymentTypes.ImplementationRecord[] memory) {
        DeploymentTypes.ImplementationRecord[] memory sorted = new DeploymentTypes.ImplementationRecord[](
            records.length
        );
        for (uint256 i = 0; i < records.length; ++i) {
            sorted[i] = records[i];
        }
        for (uint256 i = 0; i < sorted.length; ++i) {
            uint256 minIndex = i;
            for (uint256 j = i + 1; j < sorted.length; ++j) {
                if (
                    LibString.eq(sorted[j].proxy, sorted[minIndex].proxy)
                        ? false
                        : bytes(sorted[j].proxy)[0] < bytes(sorted[minIndex].proxy)[0]
                ) {
                    minIndex = j;
                }
            }
            if (minIndex != i) {
                DeploymentTypes.ImplementationRecord memory tmp = sorted[i];
                sorted[i] = sorted[minIndex];
                sorted[minIndex] = tmp;
            }
        }
        return sorted;
    }

    function sortedProxies(
        DeploymentTypes.ProxyRecord[] memory records
    ) internal pure returns (DeploymentTypes.ProxyRecord[] memory) {
        DeploymentTypes.ProxyRecord[] memory sorted = new DeploymentTypes.ProxyRecord[](records.length);
        for (uint256 i = 0; i < records.length; ++i) {
            sorted[i] = records[i];
        }
        for (uint256 i = 0; i < sorted.length; ++i) {
            uint256 minIndex = i;
            for (uint256 j = i + 1; j < sorted.length; ++j) {
                if (sorted[j].id.cmp(sorted[minIndex].id) < 0) {
                    minIndex = j;
                }
            }
            if (minIndex != i) {
                DeploymentTypes.ProxyRecord memory tmp = sorted[i];
                sorted[i] = sorted[minIndex];
                sorted[minIndex] = tmp;
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
