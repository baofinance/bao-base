// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/**
 * @title DeploymentKeyNames
 * @notice Centralized registry of deployment key strings
 * @dev Shared between Deployment, DeploymentKeys, and data layer implementations
 */
library DeploymentKeyNames {
    // Global metadata
    string internal constant SCHEMA_VERSION = "schemaVersion";
    string internal constant OWNER = "owner";
    string internal constant SYSTEM_SALT_STRING = "systemSaltString";

    // Session metadata
    string internal constant SESSION_ROOT = "session";
    string internal constant SESSION_VERSION = "session.version";
    string internal constant SESSION_DEPLOYER = "session.deployer";
    string internal constant SESSION_START_TIMESTAMP = "session.startTimestamp";
    string internal constant SESSION_FINISH_TIMESTAMP = "session.finishTimestamp";
    string internal constant SESSION_START_BLOCK = "session.startBlock";
    string internal constant SESSION_FINISH_BLOCK = "session.finishBlock";
    string internal constant SESSION_NETWORK = "session.network";

    // Contracts namespace
    string internal constant CONTRACTS_ROOT = "contracts";
    string internal constant CONTRACTS_PREFIX = "contracts.";
}
