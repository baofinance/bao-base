// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {console2 as console} from "forge-std/console2.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {FactoryDeployer} from "@bao-script/deployment/FactoryDeployer.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";

/// @notice Base for all deployment scripts and tests. Combines CREATE3 factory deployment
///         (FactoryDeployer) with Safe batch transaction queuing.
///
/// @dev No forge Script dependency — usable from both forge test and forge script contexts.
///      In forge test context _executeLocal() pranks as owner(); in script context it broadcasts
///      when EXECUTE_LOCAL=true. Batch JSON files are only written in non-test contexts.
///
/// Environment variables (set by script/run-script):
///   SAFE_BATCH_NAME          Filename prefix for the batch JSON
///   SAFE_BATCH_DESCRIPTION   Description field in the batch JSON
///   SAFE_BATCH_TIMESTAMP     ISO 8601 timestamp for filename
///   EXECUTE_LOCAL            When "true", execute queued transactions on local anvil
abstract contract Deployer is FactoryDeployer {
    using LibString for string;
    using LibString for address;
    using LibString for uint256;

    Vm private constant _vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    struct Transaction {
        address target;
        bytes data;
        string description;
    }

    Transaction[] internal _transactions;
    Transaction[] internal _allTransactions; // accumulated across flushes for local execution
    address private _signer;

    // ─────────────────────────────────────────────────────────────────────────
    // DSL: Signer Context
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Set the signer for subsequent flush() calls in local execution mode.
    function startSigner(address signer_) internal {
        _signer = signer_;
    }

    /// @notice Clear the signer override, reverting to owner() for local execution.
    function stopSigner() internal {
        _signer = address(0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // DSL: Transaction Building
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Queue a transaction to be included in the batch.
    function queue(address target, bytes memory data, string memory description) internal {
        _transactions.push(Transaction({target: target, data: data, description: description}));
    }

    /// @notice Queue a transaction with auto-generated description.
    function queue(address target, bytes memory data) internal {
        queue(target, data, target.toHexString());
    }

    /// @notice Queue a transaction using a local key for address prediction.
    /// @param key The local key (e.g., from SaltString.key()), without salt prefix.
    function queue(string memory key, bytes memory data, string memory description) internal {
        queue(_predictAddress(key), data, string.concat(_saltString(key), ".", description));
    }

    /// @notice Save the current queued transactions as a named batch and clear the queue.
    /// @param suffix Appended to the filename, e.g. "01_grant_roles". Use "" for no suffix.
    /// @param description Description field in the batch JSON.
    function flush(string memory suffix, string memory description) internal {
        _saveAndExecute(suffix, description);
        delete _transactions;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // build()/run() pattern
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Override to define transactions. No-op by default.
    function build() internal virtual {}

    /// @notice Main entry point. Run with: script/run-script <contract> --salt <salt> --network <net>
    /// @param salt_ The salt prefix (e.g., "harbor_v1")
    function run(string memory salt_) public {
        _setSaltPrefix(salt_);
        build();
        _saveAndExecute("", _vm.envOr("SAFE_BATCH_DESCRIPTION", string("")));
        _executeLocal();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Persistence and execution
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Accumulate queued transactions; write batch JSON in non-test contexts.
    function _saveAndExecute(string memory suffix, string memory description) internal {
        if (_transactions.length == 0) {
            console.log("No transactions queued - nothing to execute");
            return;
        }

        if (!_vm.isContext(VmSafe.ForgeContext.TestGroup)) {
            address batchSigner = _signer != address(0) ? _signer : owner();
            string memory name = _vm.envOr("SAFE_BATCH_NAME", string("batch"));
            string memory timestamp = _vm.envOr("SAFE_BATCH_TIMESTAMP", block.timestamp.toString());
            string memory batchDir = string.concat(DeploymentState.resolveDirectory(), "/batch");
            _vm.createDir(batchDir, true);
            string memory signerLabel = _addressLabel(batchSigner);
            string memory fileSuffix = bytes(suffix).length > 0 ? string.concat(suffix, "@", signerLabel) : signerLabel;
            string memory filename = string.concat(name, "_", timestamp, "_", fileSuffix, ".json");
            string memory path = string.concat(batchDir, "/", filename);
            _vm.writeJson(_buildSafeJson(description), path);
            console.log("Safe batch saved to: %s", path);
            console.log("  Transactions:", _transactions.length);
        }

        for (uint256 i = 0; i < _transactions.length; i++) {
            _allTransactions.push(_transactions[i]);
        }
    }

    /// @dev Execute all accumulated transactions.
    ///      Test context: always runs with vm.startPrank(owner()).
    ///      Script context: runs with vm.startBroadcast(owner()) only when EXECUTE_LOCAL=true.
    function _executeLocal() internal {
        if (_allTransactions.length == 0) return;

        bool isTestGroup = _vm.isContext(VmSafe.ForgeContext.TestGroup);
        if (!isTestGroup && !_vm.envOr("EXECUTE_LOCAL", false)) return;

        if (isTestGroup) {
            _vm.startPrank(owner());
        } else {
            _vm.startBroadcast(owner());
        }
        for (uint256 i = 0; i < _allTransactions.length; i++) {
            console.log("Executing:", _allTransactions[i].description);
            (bool ok, bytes memory ret) = _allTransactions[i].target.call(_allTransactions[i].data);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
        if (isTestGroup) {
            _vm.stopPrank();
        } else {
            _vm.stopBroadcast();
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal: JSON Generation
    // ─────────────────────────────────────────────────────────────────────────

    function _buildSafeJson(string memory description) internal view returns (string memory) {
        string memory txArray = "[";
        for (uint256 i = 0; i < _transactions.length; i++) {
            if (i > 0) {
                txArray = string.concat(txArray, ",");
            }
            txArray = string.concat(
                txArray,
                '{"to":"',
                _transactions[i].target.toHexStringChecksummed(),
                '","value":"0","data":"',
                _vm.toString(_transactions[i].data),
                '"}'
            );
        }
        txArray = string.concat(txArray, "]");

        return
            string.concat(
                '{"version":"1.0","chainId":"',
                block.chainid.toString(),
                '","createdAt":',
                (block.timestamp * 1000).toString(),
                ',"meta":{"description":"',
                description,
                '"},"transactions":',
                txArray,
                "}"
            );
    }
}
