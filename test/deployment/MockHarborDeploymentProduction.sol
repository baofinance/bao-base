// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeploymentKeys} from "@bao-script/deployment/DeploymentKeys.sol";
import {DeploymentKeyNames as KeyNames} from "@bao-script/deployment/DeploymentKeyNames.sol";
import {IDeploymentDataWritable} from "@bao-script/deployment/interfaces/IDeploymentDataWritable.sol";
import {DeploymentDataJsonTesting} from "@bao-script/deployment/DeploymentDataJsonTesting.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";
import {HarborKeys} from "./HarborKeys.sol";
import {DeploymentTesting} from "./DeploymentTesting.sol";

/**
 * @title HarborKeyRegistry
 * @notice Key registry for Harbor protocol deployment
 */
contract HarborKeyRegistry is DeploymentKeys {
    constructor() {
        string memory prefix = KeyNames.CONTRACTS_PREFIX;
        string memory peggedKey = string.concat(prefix, HarborKeys.PEGGED);
        string memory implementationKey = string.concat(prefix, HarborKeys.PEGGED_IMPLEMENTATION);
        string memory implementationLabelKey = string.concat(prefix, HarborKeys.PEGGED_IMPLEMENTATION_LABEL);

        addKey(peggedKey);
        addKey(implementationKey);
        addStringKey(implementationLabelKey);
        addStringKey(string.concat(peggedKey, ".category"));
        addStringKey(string.concat(implementationKey, ".type"));
        addStringKey(string.concat(implementationKey, ".path"));
        addStringKey(string.concat(prefix, HarborKeys.PEGGED_SYMBOL));
        addStringKey(string.concat(prefix, HarborKeys.PEGGED_NAME));
        addAddressKey(string.concat(prefix, HarborKeys.PEGGED_OWNER));
    }
}

/**
 * @title MockHarborDeploymentProduction
 * @notice Production Harbor deployment - NO public setters
 * @dev This is the base contract that production uses
 *      - All configuration MUST come from JSON file (loaded by data layer)
 *      - No public setString/setAddress methods
 *      - Choice of JSON vs Memory is runtime via _createDataLayer()
 */
contract MockHarborDeploymentProduction is DeploymentTesting {
    // ============================================================================
    // Abstract Method Implementations
    // ============================================================================

    function _createKeys() internal override returns (DeploymentKeys) {
        return new HarborKeyRegistry();
    }

    function _createDataLayer(
        string memory inputPath,
        string memory /* outputPath */
    ) internal override returns (IDeploymentDataWritable) {
        // For testing we use DeploymentDataJsonTesting (results/ directory)
        // Production would use DeploymentDataJson (deployment root)
        return new DeploymentDataJsonTesting(_keyRegistry, inputPath);
    }

    // ============================================================================
    // Harbor-Specific Deployment Logic
    // ============================================================================

    function deployPegged() public returns (address proxy) {
        string memory symbol = _getString(HarborKeys.PEGGED_SYMBOL);
        string memory name = _getString(HarborKeys.PEGGED_NAME);
        address owner = _getAddress(HarborKeys.PEGGED_OWNER);

        MintableBurnableERC20_v1 impl = new MintableBurnableERC20_v1();
        string memory implKey = registerImplementation(
            HarborKeys.PEGGED,
            address(impl),
            "MintableBurnableERC20_v1",
            "src/MintableBurnableERC20_v1.sol"
        );

        bytes memory initData = abi.encodeCall(MintableBurnableERC20_v1.initialize, (owner, name, symbol));
        proxy = this.deployProxy(HarborKeys.PEGGED, implKey, initData);

        return proxy;
    }
}
