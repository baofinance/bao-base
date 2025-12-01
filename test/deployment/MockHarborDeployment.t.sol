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

    string internal constant TEST_SALT = "MockHarborDeploymentTest";

    function setUp() public override {
        super.setUp(); // Sets up deployment infrastructure (Nick's Factory + BaoDeployer)
        deployment = new MockHarborDeploymentDev();
        _resetDeploymentLogs("MockHarborDeploymentTest", "");
        admin = makeAddr("admin");
    }

    function _startDeployment(string memory network) internal {
        _prepareTestNetwork(TEST_SALT, network);
        deployment.start(network, TEST_SALT, "");
    }

    /// @notice Test individual pegged token deployment
    function test_deployPegged() public {
        _startDeployment("test_deployPegged");

        deployment.setFilename("test_deployPegged");
        // Pre-deployment configuration
        deployment.setString(deployment.PEGGED_SYMBOL(), "USD");
        deployment.setString(deployment.PEGGED_NAME(), "Harbor USD");
        deployment.setAddress(deployment.PEGGED_OWNER(), admin);

        // Predict address before deployment
        address predicted = deployment.predictProxyAddress(deployment.PEGGED());

        // Deploy
        deployment.deployPegged();

        // Verify deployment
        assertNotEq(deployment.get(deployment.PEGGED()), address(0), "Pegged token should be deployed");
        assertEq(predicted, deployment.get(deployment.PEGGED()), "Predicted address should match deployed");
        assertEq(
            deployment.get(deployment.PEGGED()),
            deployment.get(deployment.PEGGED()),
            "Stored address should match"
        );

        // Verify the token works
        MintableBurnableERC20_v1 token = MintableBurnableERC20_v1(deployment.get(deployment.PEGGED()));
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
        _startDeployment("test_configurationFlow");

        deployment.setFilename("test_configurationFlow");
        // Configure
        deployment.setString(deployment.PEGGED_SYMBOL(), "EURO");
        deployment.setString(deployment.PEGGED_NAME(), "Harbor Euro");
        deployment.setAddress(deployment.PEGGED_OWNER(), admin);

        // Verify configuration was stored
        assertEq(deployment.getString(deployment.PEGGED_SYMBOL()), "EURO", "Symbol should be stored");
        assertEq(deployment.getString(deployment.PEGGED_NAME()), "Harbor Euro", "Name should be stored");
        assertEq(deployment.getAddress(deployment.PEGGED_OWNER()), admin, "Owner should be stored");

        // Deploy using that configuration
        deployment.deployPegged();

        MintableBurnableERC20_v1 token = MintableBurnableERC20_v1(deployment.get(deployment.PEGGED()));
        assertEq(token.symbol(), "EURO", "Deployed token should use configured symbol");
        assertEq(token.name(), "Harbor Euro", "Deployed token should use configured name");
    }

    /// @notice Test predictable addressing
    function test_predictableAddress() public {
        _startDeployment("test_predictableAddress");

        deployment.setFilename("test_predictableAddress");
        // Predict address
        address predicted = deployment.predictProxyAddress(deployment.PEGGED());
        assertTrue(predicted != address(0), "Predicted address should not be zero");

        // Configure and deploy
        deployment.setString(deployment.PEGGED_SYMBOL(), "GBP");
        deployment.setString(deployment.PEGGED_NAME(), "Harbor Pound");
        deployment.setAddress(deployment.PEGGED_OWNER(), admin);

        deployment.deployPegged();

        // Addresses should match
        assertEq(deployment.get(deployment.PEGGED()), predicted, "Deployed address should match prediction");
    }

    /// @notice Test that contract existence can be checked
    function test_checkContractExists() public {
        _startDeployment("test_checkContractExists");

        deployment.setFilename("test_checkContractExists");
        // Before deployment
        assertFalse(deployment.has(deployment.PEGGED()), "Pegged should not exist yet");

        // Configure and deploy
        deployment.setString(deployment.PEGGED_SYMBOL(), "CHF");
        deployment.setString(deployment.PEGGED_NAME(), "Harbor Franc");
        deployment.setAddress(deployment.PEGGED_OWNER(), admin);
        deployment.deployPegged();

        // After deployment
        assertTrue(deployment.has(deployment.PEGGED()), "Pegged should exist now");
    }

    /// @notice Test that invalid keys are rejected
    function test_invalidKeyRejected() public {
        _startDeployment("test_invalidKeyRejected");

        // Try to set an unregistered key
        vm.expectRevert();
        deployment.setString("invalid.key", "value");
    }
}
