// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {MockHarborDeploymentDev} from "./MockHarborDeploymentDev.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";

/**
 * @title MockHarborDeploymentTest
 * @notice Shows how Harbor developers would write deployment tests
 * @dev Demonstrates the developer experience of using the new system with real deployments
 */
contract MockHarborDeploymentTest is BaoDeploymentTest {
    MockHarborDeploymentDev public deployment;
    address public admin;

    string internal constant TEST_NETWORK = "anvil";
    string internal constant TEST_SALT = "test";
    string internal constant FILE_PREFIX = "MockHarborDeploymentTest-";
    string internal constant HARBOR_SUITE_LABEL = "mock-harbor";

    function setUp() public override {
        super.setUp(); // Sets up deployment infrastructure (Nick's Factory + BaoDeployer)
        deployment = new MockHarborDeploymentDev();
        deployment.setNetworkLabel(HARBOR_SUITE_LABEL); // No-op for backward compatibility
        deployment.start(address(this), TEST_NETWORK, TEST_SALT, "");
        admin = makeAddr("admin");
    }

    /// @notice Test individual pegged token deployment
    function test_deployPegged() public {
        deployment.setOutputFilename(string.concat(FILE_PREFIX, "test_deployPegged"));
        // Pre-deployment configuration
        deployment.setString(HarborKeys.PEGGED_SYMBOL, "USD");
        deployment.setString(HarborKeys.PEGGED_NAME, "Harbor USD");
        deployment.setAddress(HarborKeys.PEGGED_OWNER, admin);

        // Predict address before deployment
        address predicted = deployment.predictProxyAddress(HarborKeys.PEGGED);

        // Deploy
        address pegged = deployment.deployPegged();

        // Verify deployment
        assertNotEq(pegged, address(0), "Pegged token should be deployed");
        assertEq(predicted, pegged, "Predicted address should match deployed");
        assertEq(deployment.get(HarborKeys.PEGGED), pegged, "Stored address should match");

        // Verify the token works
        MintableBurnableERC20_v1 token = MintableBurnableERC20_v1(pegged);
        assertEq(token.symbol(), "USD", "Symbol should be correct");
        assertEq(token.name(), "Harbor USD", "Name should be correct");
        assertEq(token.decimals(), 18, "Decimals should be 18");

        // Verify ownership - deployment contract is initial owner (via BaoOwnable pattern)
        assertEq(token.owner(), address(deployment), "Deployment should be initial owner");

        // Complete ownership transfer
        vm.prank(address(deployment));
        token.transferOwnership(admin);
        assertEq(token.owner(), admin, "Admin should be owner after transfer");
    }

    /// @notice Test that configuration is read from data layer
    function test_configurationFlow() public {
        deployment.setOutputFilename(string.concat(FILE_PREFIX, "test_configurationFlow"));
        // Configure
        deployment.setString(HarborKeys.PEGGED_SYMBOL, "EURO");
        deployment.setString(HarborKeys.PEGGED_NAME, "Harbor Euro");
        deployment.setAddress(HarborKeys.PEGGED_OWNER, admin);

        // Verify configuration was stored
        assertEq(deployment.getString(HarborKeys.PEGGED_SYMBOL), "EURO", "Symbol should be stored");
        assertEq(deployment.getString(HarborKeys.PEGGED_NAME), "Harbor Euro", "Name should be stored");
        assertEq(deployment.getAddress(HarborKeys.PEGGED_OWNER), admin, "Owner should be stored");

        // Deploy using that configuration
        address pegged = deployment.deployPegged();

        MintableBurnableERC20_v1 token = MintableBurnableERC20_v1(pegged);
        assertEq(token.symbol(), "EURO", "Deployed token should use configured symbol");
        assertEq(token.name(), "Harbor Euro", "Deployed token should use configured name");
    }

    /// @notice Test predictable addressing
    function test_predictableAddress() public {
        deployment.setOutputFilename(string.concat(FILE_PREFIX, "test_predictableAddress"));
        // Predict address
        address predicted = deployment.predictProxyAddress(HarborKeys.PEGGED);
        assertTrue(predicted != address(0), "Predicted address should not be zero");

        // Configure and deploy
        deployment.setString(HarborKeys.PEGGED_SYMBOL, "GBP");
        deployment.setString(HarborKeys.PEGGED_NAME, "Harbor Pound");
        deployment.setAddress(HarborKeys.PEGGED_OWNER, admin);

        address deployed = deployment.deployPegged();

        // Addresses should match
        assertEq(deployed, predicted, "Deployed address should match prediction");
    }

    /// @notice Test that contract existence can be checked
    function test_checkContractExists() public {
        deployment.setOutputFilename(string.concat(FILE_PREFIX, "test_checkContractExists"));
        // Before deployment
        assertFalse(deployment.has(HarborKeys.PEGGED), "Pegged should not exist yet");

        // Configure and deploy
        deployment.setString(HarborKeys.PEGGED_SYMBOL, "CHF");
        deployment.setString(HarborKeys.PEGGED_NAME, "Harbor Franc");
        deployment.setAddress(HarborKeys.PEGGED_OWNER, admin);
        deployment.deployPegged();

        // After deployment
        assertTrue(deployment.has(HarborKeys.PEGGED), "Pegged should exist now");
    }

    /// @notice Test that invalid keys are rejected
    function test_invalidKeyRejected() public {
        // Try to set an unregistered key
        vm.expectRevert();
        deployment.setString("invalid.key", "value");
    }
}
