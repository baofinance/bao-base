// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {MockHarborDeploymentDev} from "./MockHarborDeploymentDev.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";

/**
 * @title DeploymentProxyWorkflowTest
 * @notice Tests for proxy deployment workflows with persistence
 * @dev Harbor-specific example demonstrating real-world usage patterns
 */
contract DeploymentProxyWorkflowTest is BaoDeploymentTest {
    function test_MultipleWritesWithProxyDeployment() public {
        // This test demonstrates the full deployment workflow across sequenced phases
        // using the actual proxy deployment code path
        MockHarborDeploymentDev harness = new MockHarborDeploymentDev();

        // Start deployment session with sequencing enabled
        harness.start("MultipleWritesWithProxyDeployment", "DeploymentProxyWorkflowTest", "");

        // Enable sequencing to capture each phase
        harness.enableSequencing();

        address admin = makeAddr("admin");

        // Phase 1: Set configuration for first token
        harness.setString(harness.PEGGED_SYMBOL(), "USD");
        harness.setString(harness.PEGGED_NAME(), "Harbor USD");
        harness.setAddress(harness.PEGGED_OWNER(), admin);

        // Phase 2: Deploy proxy using configuration
        address peggedProxy = harness.deployPegged();
        assertNotEq(peggedProxy, address(0), "Proxy should be deployed");

        // Phase 3: Verify deployment metadata was persisted
        assertEq(harness.get(harness.PEGGED()), peggedProxy, "Proxy address should be stored");
        string memory implKey = harness.getString(string.concat(harness.PEGGED(), ".implementation"));
        assertEq(
            implKey,
            string.concat(harness.PEGGED(), "__MintableBurnableERC20_v1"),
            "Implementation key should be stored"
        );

        // Phase 4: Verify proxy works correctly
        MintableBurnableERC20_v1 token = MintableBurnableERC20_v1(peggedProxy);
        assertEq(token.symbol(), "USD", "Symbol should match configuration");
        assertEq(token.name(), "Harbor USD", "Name should match configuration");
        assertEq(token.owner(), address(harness), "Harness should be initial owner");

        // Phase 5: Transfer ownership
        vm.prank(address(harness));
        token.transferOwnership(admin);
        assertEq(token.owner(), admin, "Ownership should be transferred");

        // All phases should be persisted in sequenced files (.001.json through .005.json)
        // Each file shows progression of deployment state
    }
}
