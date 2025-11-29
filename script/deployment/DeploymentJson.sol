// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;
import {LibString} from "@solady/utils/LibString.sol";

import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {DeploymentKeys} from "@bao-script/deployment/DeploymentKeys.sol";
import {IDeploymentDataWritable} from "@bao-script/deployment/interfaces/IDeploymentDataWritable.sol";
import {DeploymentDataJson} from "@bao-script/deployment/DeploymentDataJson.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @title DeploymentJson
 * @notice JSON-specific deployment layer with file I/O
 * @dev Extends base Deployment with:
 *      - JSON file path resolution (input/output)
 *      - Timestamp-based file naming
 *      - DeploymentDataJson integration
 *      Subclasses implement _createDataLayer to choose specific JSON data implementation
 */
abstract contract DeploymentJson is Deployment {
    using LibString for string;

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string private _systemSaltString;
    string private _network;
    string private _filename;
    // TODO: thie below is a hack
    DeploymentDataJson _dataJson;
    bool _suppressPersistence = false;

    // ============================================================================
    // Abstract Methods for JSON Configuration
    // ============================================================================

    function _afterValueChanged(string memory /* key */) internal virtual override {
        if (!_suppressPersistence) {
            string memory path = string.concat(_getOutputConfigDir(), "/", _getFilename(), ".json");
            VM.writeJson(_dataJson.toJson(), path);
        }
    }

    // ============================================================================
    // Path Calculation
    // ============================================================================

    /// @notice Get base directory for deployment files
    /// @dev Override in test classes to use results/ instead of ./
    /// @return Base directory path
    function _getPrefix() internal virtual returns (string memory) {
        return ".";
    }

    function _getRoot() private returns (string memory) {
        return string.concat(_getPrefix(), "/deployments");
    }

    function _getStartConfigDir() internal returns (string memory) {
        return string.concat(_getRoot(), "/", _systemSaltString);
    }

    function _getOutputConfigDir() internal returns (string memory) {
        if (bytes(_network).length > 0) return string.concat(_getRoot(), "/", _systemSaltString, "/", _network);
        else return string.concat(_getRoot(), "/", _systemSaltString);
    }

    function _getFilename() internal view virtual returns (string memory filename) {
        filename = _filename;
    }
    /**
     * @notice Convert Unix timestamp to ISO 8601 date-time string
     * @param timestamp Unix timestamp in seconds
     * @return ISO 8601 formatted string (YYYY-MM-DDTHH:MM:SSZ)
     */
    function _formatTimestamp(uint256 timestamp) internal pure returns (string memory) {
        if (timestamp == 0) return "";

        // Calculate date components
        uint256 z = timestamp / 86400 + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 d = doy - (153 * mp + 2) / 5 + 1;
        uint256 m = mp < 10 ? mp + 3 : mp - 9;
        y = m <= 2 ? y + 1 : y;

        // Calculate time components
        uint256 secondsInDay = timestamp % 86400;
        uint256 hour = secondsInDay / 3600;
        uint256 minute = (secondsInDay % 3600) / 60;
        uint256 second = secondsInDay % 60;

        // Format as ISO 8601: YYYY-MM-DDTHH:MM:SSZ
        return
            string(
                abi.encodePacked(
                    _padZero(y, 4),
                    "-",
                    _padZero(m, 2),
                    "-",
                    _padZero(d, 2),
                    "T",
                    _padZero(hour, 2),
                    ":",
                    _padZero(minute, 2),
                    ":",
                    _padZero(second, 2),
                    "Z"
                )
            );
    }

    /**
     * @notice Pad number with leading zeros
     * @param num Number to pad
     * @param width Target width
     * @return Padded string
     */
    function _padZero(uint256 num, uint256 width) internal pure returns (string memory) {
        bytes memory b = bytes(LibString.toString(num));
        if (b.length >= width) return string(b);

        bytes memory padded = new bytes(width);
        uint256 padLen = width - b.length;
        for (uint256 i = 0; i < padLen; i++) {
            padded[i] = "0";
        }
        for (uint256 i = 0; i < b.length; i++) {
            padded[padLen + i] = b[i];
        }
        return string(padded);
    }

    // ============================================================================
    // Lifecycle Override with JSON Support
    // ============================================================================
    function _requireNetwork(string memory network_) internal virtual {
        require(bytes(network_).length > 0, "cannot have a null network string");
    }

    /// @notice Initialize data layer with JSON file paths
    /// @dev Implements abstract method from base Deployment
    /// @param network_ Network name
    /// @param systemSaltString_ System salt string
    /// @param startPoint Start point for input resolution
    /// @dev Subclasses choose: DeploymentDataJson, DeploymentDataJsonTesting, etc.
    function _createDeploymentData(
        string memory network_,
        string memory systemSaltString_,
        string memory startPoint
    ) internal virtual override returns (IDeploymentDataWritable) {
        _requireNetwork(network_);
        require(bytes(systemSaltString_).length > 0, "cannot have a null system salt string");
        _network = network_;
        _systemSaltString = systemSaltString_;
        _dataJson = new DeploymentDataJson(this);

        // now load the data from the specified file
        string memory path;
        if (bytes(startPoint).length == 0 || startPoint.eq("first")) {
            path = string.concat(_getStartConfigDir(), "/config.json");
        } else if (startPoint.eq("latest")) {
            // TODO: implement latest file finding if needed
            revert("Latest file resolution not yet implemented");
        } else {
            path = string.concat(_getOutputConfigDir(), "/", startPoint, ".json");
        }
        _suppressPersistence = true; // we don't want the loading to write out each change, on loading
        _dataJson.fromJson(VM.readFile(path));
        _suppressPersistence = false;

        _filename = _formatTimestamp(block.timestamp);
        return _dataJson;
    }
}
