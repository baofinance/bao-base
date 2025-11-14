// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {Deployment} from "./Deployment.sol";
import {DeploymentRegistry} from "@bao-script/deployment/DeploymentRegistry.sol";
import {DeploymentRegistryJson} from "@bao-script/deployment/DeploymentRegistryJson.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";

/**
 * @title DeploymentFoundry
 * @notice Production deployment helper for mainnet/testnet scripts
 * @dev For use in forge scripts deploying to real networks
 *      - Has Vm for address labeling in transaction traces
 *
 */
abstract contract DeploymentFoundry is Deployment, DeploymentRegistryJson {
    function _getBaseDirPrefix()
        internal
        view
        virtual
        override(DeploymentRegistryJson, DeploymentRegistry)
        returns (string memory)
    {
        return ".";
    }

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

abstract contract DeploymentFoundryTest is DeploymentFoundry {
    function _ensureBaoDeployerOperator() internal virtual override {
        address baoDeployer = DeploymentInfrastructure.predictBaoDeployerAddress();
        if (baoDeployer.code.length > 0 && BaoDeployer(baoDeployer).operator() != address(this)) {
            VM.startPrank(DeploymentInfrastructure.BAOMULTISIG);
            BaoDeployer(baoDeployer).setOperator(address(this));
            VM.stopPrank();
        }
        super._ensureBaoDeployerOperator();
    }

    function _getBaseDirPrefix() internal view virtual override returns (string memory) {
        if (VM.envExists("BAO_DEPLOYMENT_LOGS_ROOT")) {
            return VM.envString("BAO_DEPLOYMENT_LOGS_ROOT");
        }
        return "results";
    }
}
