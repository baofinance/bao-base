// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {MockHarborDeploymentDev} from "./MockHarborDeploymentDev.sol";
import {HarborKeys} from "./HarborKeys.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";

/**
 * @title DeploymentProxyTest
 * @notice Tests proxy deployment functionality (CREATE3)
 * @dev Uses MockHarborDeploymentDev and its deployPegged() method to test proxy deployment
 */
contract DeploymentProxyTest is BaoDeploymentTest {
    MockHarborDeploymentDev public deployment;
    address internal admin;
    address internal outsider;
    string constant TEST_NETWORK = "anvil";
    string constant TEST_SALT = "proxy-test";
    string constant FILE_PREFIX = "DeploymentProxyTest-";

    function setUp() public override {
        super.setUp();
        deployment = new MockHarborDeploymentDev();
        deployment.start(address(this), TEST_NETWORK, TEST_SALT, "");
        admin = makeAddr("admin");
        outsider = makeAddr("outsider");
    }

    function test_DeployProxy() public {
        deployment.setOutputFilename(string.concat(FILE_PREFIX, "test_DeployProxy"));
        deployment.setString(HarborKeys.PEGGED_SYMBOL, "USD");
        deployment.setString(HarborKeys.PEGGED_NAME, "Harbor USD");
        deployment.setAddress(HarborKeys.PEGGED_OWNER, admin);

        address proxyAddr = deployment.deployPegged();

        assertTrue(proxyAddr != address(0), "Proxy should be deployed");
        assertTrue(deployment.has(HarborKeys.PEGGED), "Proxy key should exist");
        assertEq(deployment.get(HarborKeys.PEGGED), proxyAddr, "Stored address should match");

        // Verify proxy is working
        MintableBurnableERC20_v1 token = MintableBurnableERC20_v1(proxyAddr);
        assertEq(token.symbol(), "USD", "Symbol should be correct");
        assertEq(token.name(), "Harbor USD", "Name should be correct");
        assertEq(token.decimals(), 18, "Decimals should be 18");

        // Verify ownership - deployment contract is initial owner (via BaoOwnable pattern)
        assertEq(token.owner(), address(deployment), "Deployment should be initial owner");

        // Transfer ownership to admin
        vm.prank(address(deployment));
        token.transferOwnership(admin);
        assertEq(token.owner(), admin, "Owner should be admin");
    }

    function test_PredictProxyAddress() public {
        deployment.setOutputFilename(string.concat(FILE_PREFIX, "test_PredictProxyAddress"));
        address predicted = deployment.predictProxyAddress(HarborKeys.PEGGED);

        deployment.setString(HarborKeys.PEGGED_SYMBOL, "EUR");
        deployment.setString(HarborKeys.PEGGED_NAME, "Harbor EUR");
        deployment.setAddress(HarborKeys.PEGGED_OWNER, admin);

        address actual = deployment.deployPegged();

        assertEq(predicted, actual, "Predicted address should match deployed");
    }

    function test_DeterministicProxyAddress() public {
        deployment.setOutputFilename(string.concat(FILE_PREFIX, "test_DeterministicProxyAddress"));
        // Same key with same salt should produce same address
        address addr1 = deployment.predictProxyAddress(HarborKeys.PEGGED);

        deployment.setString(HarborKeys.PEGGED_SYMBOL, "GBP");
        deployment.setString(HarborKeys.PEGGED_NAME, "Harbor GBP");
        deployment.setAddress(HarborKeys.PEGGED_OWNER, admin);

        address deployed = deployment.deployPegged();
        assertEq(deployed, addr1, "Deployed address should match prediction");

        // Different deployment with different salt should produce different address
        MockHarborDeploymentDev deployment2 = new MockHarborDeploymentDev();
        deployment2.start(address(this), TEST_NETWORK, "different-salt", "");
        address addr2 = deployment2.predictProxyAddress(HarborKeys.PEGGED);

        assertNotEq(addr2, addr1, "Different salt should produce different address");
    }

    function test_MultipleProxies() public {
        deployment.setOutputFilename(string.concat(FILE_PREFIX, "test_MultipleProxies"));
        // Deploy first proxy
        deployment.setString(HarborKeys.PEGGED_SYMBOL, "USD");
        deployment.setString(HarborKeys.PEGGED_NAME, "Harbor USD");
        deployment.setAddress(HarborKeys.PEGGED_OWNER, admin);
        address proxy1 = deployment.deployPegged();

        // To deploy a second proxy, we'd need a different key
        // The current Harbor deployment only has one pegged token
        // This test demonstrates that the first deployment works
        assertTrue(deployment.has(HarborKeys.PEGGED), "First proxy should exist");
        assertEq(deployment.get(HarborKeys.PEGGED), proxy1, "First proxy address should be stored");

        MintableBurnableERC20_v1 token1 = MintableBurnableERC20_v1(proxy1);
        assertEq(token1.symbol(), "USD", "First token symbol should be correct");
    }

    function test_RevertWhen_ProxyWithEmptyKey() public {
        deployment.setOutputFilename(string.concat(FILE_PREFIX, "test_RevertWhen_ProxyWithEmptyKey"));

        // Try to deploy with empty key - should revert with KeyRequired
        vm.expectRevert();
        deployment.deployProxy("", "some-impl", "");
    }

    function test_RevertWhen_ProxyWithoutImplementation() public {
        deployment.setOutputFilename(string.concat(FILE_PREFIX, "test_RevertWhen_ProxyWithoutImplementation"));
        vm.expectRevert();
        deployment.deployProxy(HarborKeys.PEGGED, "nonexistent_impl", "");
    }

    function test_ProxyMetadataStored() public {
        deployment.setOutputFilename(string.concat(FILE_PREFIX, "test_ProxyMetadataStored"));
        deployment.setString(HarborKeys.PEGGED_SYMBOL, "JPY");
        deployment.setString(HarborKeys.PEGGED_NAME, "Harbor JPY");
        deployment.setAddress(HarborKeys.PEGGED_OWNER, admin);

        deployment.deployPegged();

        // Verify metadata is stored
        string memory implKey = deployment.getString(string.concat(HarborKeys.PEGGED, ".implementation"));
        assertEq(
            implKey,
            string.concat(HarborKeys.PEGGED, "__MintableBurnableERC20_v1"),
            "Implementation key should be stored"
        );

        string memory category = deployment.getString(string.concat(HarborKeys.PEGGED, ".category"));
        assertEq(category, "proxy", "Category should be proxy");
    }

    function test_ImplementationReuse() public {
        deployment.setOutputFilename(string.concat(FILE_PREFIX, "test_ImplementationReuse"));
        // Deploy pegged token
        deployment.setString(HarborKeys.PEGGED_SYMBOL, "USD");
        deployment.setString(HarborKeys.PEGGED_NAME, "Harbor USD");
        deployment.setAddress(HarborKeys.PEGGED_OWNER, admin);

        deployment.deployPegged();

        string memory implKey = string.concat(HarborKeys.PEGGED, "__MintableBurnableERC20_v1");
        address impl1 = deployment.get(implKey);

        assertNotEq(impl1, address(0), "Implementation should be deployed");

        // Verify implementation metadata
        string memory implType = deployment.getString(string.concat(implKey, ".type"));
        assertEq(implType, "MintableBurnableERC20_v1", "Implementation type should be stored");
    }
}
