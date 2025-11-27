// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeploymentKeys} from "@bao-script/deployment/DeploymentKeys.sol";
import {IDeploymentDataWritable} from "@bao-script/deployment/interfaces/IDeploymentDataWritable.sol";
import {DeploymentDataJsonTesting} from "@bao-script/deployment/DeploymentDataJsonTesting.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";
import {DeploymentTesting} from "@bao-script/deployment/DeploymentTesting.sol";

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

    // Contract keys (top-level, no dots)
    string constant PEGGED = "pegged";
    string constant PEGGED_IMPLEMENTATION = "pegged__MintableBurnableERC20_v1";
    string constant PEGGED_IMPLEMENTATION_LABEL = "pegged.implementation";

    // Pegged token configuration keys
    string constant PEGGED_SYMBOL = "pegged.symbol";
    string constant PEGGED_NAME = "pegged.name";
    string constant PEGGED_OWNER = "pegged.owner";

    constructor() {
        addKey(PEGGED);
        addStringKey(string.concat(PEGGED, ".category"));
        addStringKey(string.concat(PEGGED_IMPLEMENTATION, ".type"));
        addStringKey(string.concat(PEGGED_IMPLEMENTATION, ".path"));
        addStringKey(string.concat(CONTRACTS_PREFIX, PEGGED_SYMBOL));
        addStringKey(string.concat(CONTRACTS_PREFIX, PEGGED_NAME));
        addAddressKey(string.concat(CONTRACTS_PREFIX, PEGGED_OWNER));
    }

    // ============================================================================
    // Harbor-Specific Deployment Logic
    // ============================================================================

    function deployPegged() public returns (address proxy) {
        string memory symbol = _getString(PEGGED_SYMBOL);
        string memory name = _getString(PEGGED_NAME);
        address owner = _getAddress(PEGGED_OWNER);

        MintableBurnableERC20_v1 impl = new MintableBurnableERC20_v1();
        string memory implKey = registerImplementation(
            PEGGED,
            address(impl),
            "MintableBurnableERC20_v1",
            "src/MintableBurnableERC20_v1.sol"
        );

        bytes memory initData = abi.encodeCall(MintableBurnableERC20_v1.initialize, (owner, name, symbol));
        proxy = this.deployProxy(PEGGED, implKey, initData);

        return proxy;
    }
}
