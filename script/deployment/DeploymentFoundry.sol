// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {Deployment} from "./Deployment.sol";
import {DeploymentRegistryJson} from "@bao-script/deployment/DeploymentRegistryJson.sol";

/**
 * @title DeploymentFoundry
 * @notice Production deployment helper for mainnet/testnet scripts
 * @dev For use in forge scripts deploying to real networks
 *      - Has Vm for address labeling in transaction traces
 *
 */
abstract contract DeploymentFoundry is Deployment, DeploymentRegistryJson {
    /// @notice Foundry VM for labeling addresses in traces
    Vm constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

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
