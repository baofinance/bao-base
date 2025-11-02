// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {Deployment} from "./Deployment.sol";

/**
 * @title DeploymentFoundry
 * @notice Production deployment helper for mainnet/testnet scripts
 * @dev For use in forge scripts deploying to real networks
 *      - Has Vm for address labeling in transaction traces
 *
 */
abstract contract DeploymentFoundry is Deployment {
    /// @notice Foundry VM for labeling addresses in traces
    Vm private immutable VM;

    /**
     * @notice Constructor
     * @param _vm Foundry VM instance (pass `vm` from your script)
     * @param deployerContext Address to use for CREATE3 determinism (see Deployment.sol)
     */
    constructor(Vm _vm, address deployerContext) Deployment(deployerContext) {
        VM = _vm;
    }

    /**
     * @notice Label addresses in Foundry traces
     * @dev Makes traces more readable: "admin: [0x1234...]" instead of just "0x1234..."
     * @param addr Address to label
     * @param label Human-readable label
     */
    function labelAddress(address addr, string memory label) public {
        VM.label(addr, label);
    }
}
