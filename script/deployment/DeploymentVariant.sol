// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2} from "forge-std/console2.sol";

import {DeploymentBase} from "@bao-script/deployment/DeploymentBase.sol";
import {BaoFactoryBytecode} from "@bao-script/deployment/BaoFactoryBytecode.sol";
import {BaoFactory} from "@bao-script/deployment/BaoFactory.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title DeploymentVariant
/// @notice Mixin for BaoFactory variant selection via environment variable
/// @dev Extends DeploymentBase with env var-based variant selection.
///      This is for beta testing on testnets with non-production owners.
///
///      This is a mixin - use it with DeploymentJson for JSON-based scripts:
///      contract MyScript is DeploymentJson, DeploymentVariant { ... }
///
/// Environment variable values:
///   - "Bao.BaoFactory.v1" or unset: Production variant
///   - "Testing": BaoFactoryTesting (Anvil owner)
///   - "RootMinus0x1": BaoFactoryRootMinus0x1 (rootminus0x1 owner)
abstract contract DeploymentVariant is DeploymentBase {
    Vm private constant _VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Deploy BaoFactory using variant selected by BAO_FACTORY_VARIANT env var
    function _ensureBaoFactory() internal virtual override returns (address factory) {
        string memory variant = _VM.envOr("BAO_FACTORY_VARIANT", string("Bao.BaoFactory.v1"));
        console2.log("factory variant = %s", variant);
        (bytes memory creationCode, string memory factorySalt, address expectedOwner) = BaoFactoryBytecode
            .getVariantConfig(variant);
        factory = DeploymentInfrastructure._ensureBaoFactoryWithConfig(creationCode, factorySalt, expectedOwner);

        // now make sure operator is set for this deployer
        if (!BaoFactory(factory).isCurrentOperator(_getAddress(SESSION_DEPLOYER))) {
            // you may be the owner!
            console2.log("Setting BaoFactory operator for deployer:", _getAddress(SESSION_DEPLOYER));
            BaoFactory(factory).setOperator(_getAddress(SESSION_DEPLOYER), 1 hours);
        }
    }
}
