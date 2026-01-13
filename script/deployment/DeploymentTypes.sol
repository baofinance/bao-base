// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice Shared type definitions for deployment state management.
/// @dev State is simply a list of deployed implementations and proxies.
library DeploymentTypes {
    struct ImplementationRecord {
        string proxy;
        string contractSource;
        string contractType;
        address implementation;
        uint64 deploymentTime;
    }

    struct ProxyRecord {
        string id;
        address proxy;
        address implementation;
        string salt;
        uint64 deploymentTime;
    }

    struct State {
        string network;
        string saltPrefix;
        string directoryPrefix;
        ImplementationRecord[] implementations;
        ProxyRecord[] proxies;
        address baoFactory;
    }
}
