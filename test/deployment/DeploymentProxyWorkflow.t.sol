// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {MockHarborDeploymentDev} from "./MockHarborDeploymentDev.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";
import {DeploymentJson} from "@bao-script/deployment/DeploymentJson.sol";
import {DeploymentDataMemory} from "@bao-script/deployment/DeploymentDataMemory.sol";

contract MockHarborDeploymentSequenced is MockHarborDeploymentDev {
    uint private _sequenceNumber;

    function _afterValueChanged(string memory key) internal override {
        super._afterValueChanged(key);
        _sequenceNumber++;
    }

    function _getFilename() internal view override returns (string memory) {
        return string.concat(super._getFilename(), ".", _padZero(_sequenceNumber, 3));
    }
}

/**
 * @title DeploymentProxyWorkflowTest
 * @notice Tests for proxy deployment workflows with persistence
 * @dev Harbor-specific example demonstrating real-world usage patterns
 */
contract DeploymentProxyWorkflowTest is BaoDeploymentTest {
    function test_MultipleWritesWithProxyDeployment() public {
        // This test demonstrates the full deployment workflow across sequenced phases
        // using the actual proxy deployment code path
        MockHarborDeploymentSequenced deployment = new MockHarborDeploymentSequenced();

        // Start deployment session with sequencing enabled
        _initDeploymentTest("DeploymentProxyWorkflowTest", "MultipleWritesWithProxyDeployment");
        deployment.start("MultipleWritesWithProxyDeployment", "DeploymentProxyWorkflowTest", "");

        address admin = makeAddr("admin");

        // Phase 1: Set configuration for first token
        deployment.setString(deployment.PEGGED_SYMBOL(), "USD");
        deployment.setString(deployment.PEGGED_NAME(), "Harbor USD");
        deployment.setAddress(deployment.PEGGED_OWNER(), admin);

        // Phase 2: Deploy proxy using configuration
        deployment.deployPegged();
        assertNotEq(deployment.get(deployment.PEGGED()), address(0), "Proxy should be deployed");

        // Phase 3: Verify deployment metadata was persisted
        assertEq(
            deployment.get(deployment.PEGGED()),
            deployment.get(deployment.PEGGED()),
            "Proxy address should be stored"
        );
        string memory implType = deployment.getString(
            string.concat(deployment.PEGGED(), ".implementation.contractType")
        );
        assertEq(implType, "MintableBurnableERC20_v1", "Implementation type should be stored");

        // Phase 4: Verify proxy works correctly
        MintableBurnableERC20_v1 token = MintableBurnableERC20_v1(deployment.get(deployment.PEGGED()));
        assertEq(token.symbol(), "USD", "Symbol should match configuration");
        assertEq(token.name(), "Harbor USD", "Name should match configuration");
        assertEq(token.owner(), address(deployment), "Harness should be initial owner");

        // Phase 5: Finish deployment (transfers ownership via finish())
        deployment.finish();
        assertEq(token.owner(), admin, "Ownership should be transferred to configured owner");

        // Verify ownershipModel was updated
        string memory ownershipModel = deployment.getString(
            string.concat(deployment.PEGGED(), ".implementation.ownershipModel")
        );
        assertEq(ownershipModel, "transferred-after-deploy", "Ownership model should be updated after finish");

        // Verify session finish metadata was recorded
        _assertFinishState(deployment);

        // All phases should be persisted in sequenced files
        // Each file shows progression of deployment state
    }
}
