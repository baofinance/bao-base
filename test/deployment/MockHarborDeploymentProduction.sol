// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeploymentKeys} from "@bao-script/deployment/DeploymentKeys.sol";
import {IDeploymentDataWritable} from "@bao-script/deployment/interfaces/IDeploymentDataWritable.sol";
import {DeploymentDataJsonTesting} from "@bao-script/deployment/DeploymentDataJsonTesting.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";
import {DeploymentJsonTesting} from "@bao-script/deployment/DeploymentJsonTesting.sol";

/**
 * @title MockHarborDeploymentProduction
 * @notice Production Harbor deployment - NO public setters
 * @dev This is the base contract that production uses
 *      - All configuration MUST come from JSON file (loaded by data layer)
 *      - No public setString/setAddress methods
 *      - Choice of JSON vs Memory is runtime via _createDataLayer()
 */
contract MockHarborDeploymentProduction is DeploymentJsonTesting {
    // ============================================================================
    // Abstract Method Implementations
    // ============================================================================

    // Contract keys (top-level, no dots)
    string public constant PEGGED = "contracts.pegged";
    string public constant PEGGED_IMPLEMENTATION = "contracts.pegged.implementation";
    string public constant PEGGED_IMPLEMENTATION_LABEL = "pegged.implementation";

    // Pegged token configuration keys
    string public constant PEGGED_SYMBOL = "contracts.pegged.symbol";
    string public constant PEGGED_NAME = "contracts.pegged.name";
    string public constant PEGGED_OWNER = "contracts.pegged.owner";

    constructor() {
        addProxy(PEGGED);
        addStringKey(PEGGED_SYMBOL);
        addStringKey(PEGGED_NAME);
        addAddressKey(PEGGED_OWNER);
    }

    // ============================================================================
    // Harbor-Specific Deployment Logic
    // ============================================================================

    function deployPegged() public {
        string memory symbol = _getString(PEGGED_SYMBOL);
        string memory name = _getString(PEGGED_NAME);
        address owner = _getAddress(PEGGED_OWNER);

        MintableBurnableERC20_v1 impl = new MintableBurnableERC20_v1();

        bytes memory initData = abi.encodeCall(MintableBurnableERC20_v1.initialize, (owner, name, symbol));
        this.deployProxy(
            PEGGED,
            address(impl),
            initData,
            "MintableBurnableERC20_v1",
            "src/MintableBurnableERC20_v1.sol",
            address(this)
        );
    }
}
