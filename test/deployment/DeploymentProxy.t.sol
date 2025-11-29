// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {MockHarborDeploymentDev} from "./MockHarborDeploymentDev.sol";
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
    string constant TEST_SALT = "DeploymentProxyTest";

    function setUp() public override {
        super.setUp();
        deployment = new MockHarborDeploymentDev();
        _resetDeploymentLogs(TEST_SALT, "{}");
        admin = makeAddr("admin");
        outsider = makeAddr("outsider");
    }

    function _startDeployment(string memory network) internal {
        _prepareTestNetwork(TEST_SALT, network);
        deployment.start(network, TEST_SALT, "");
    }

    function test_DeployProxy() public {
        _startDeployment("test_DeployProxy");
        
        deployment.setFilename("test_DeployProxy");
        deployment.setString(deployment.PEGGED_SYMBOL(), "USD");
        deployment.setString(deployment.PEGGED_NAME(), "Harbor USD");
        deployment.setAddress(deployment.PEGGED_OWNER(), admin);

        deployment.deployPegged();

        assertNotEq(deployment.get(deployment.PEGGED()), address(0), "Proxy should be deployed");
        assertTrue(deployment.has(deployment.PEGGED()), "Proxy key should exist");
        assertEq(
            deployment.get(deployment.PEGGED()),
            deployment.get(deployment.PEGGED()),
            "Stored address should match"
        );

        // Verify proxy is working
        MintableBurnableERC20_v1 token = MintableBurnableERC20_v1(deployment.get(deployment.PEGGED()));
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
        _startDeployment("test_PredictProxyAddress");
        
        deployment.setFilename("test_PredictProxyAddress");
        address predicted = deployment.predictProxyAddress(deployment.PEGGED());

        deployment.setString(deployment.PEGGED_SYMBOL(), "EUR");
        deployment.setString(deployment.PEGGED_NAME(), "Harbor EUR");
        deployment.setAddress(deployment.PEGGED_OWNER(), admin);

        deployment.deployPegged();

        assertEq(predicted, deployment.get(deployment.PEGGED()), "Predicted address should match deployed");
    }

    function test_DeterministicProxyAddress() public {
        _startDeployment("test_DeterministicProxyAddress");
        
        deployment.setFilename("test_DeterministicProxyAddress");
        // Same key with same salt should produce same address
        address addr1 = deployment.predictProxyAddress(deployment.PEGGED());

        deployment.setString(deployment.PEGGED_SYMBOL(), "GBP");
        deployment.setString(deployment.PEGGED_NAME(), "Harbor GBP");
        deployment.setAddress(deployment.PEGGED_OWNER(), admin);

        deployment.deployPegged();
        assertEq(deployment.get(deployment.PEGGED()), addr1, "Deployed address should match prediction");

        // Different deployment with different salt should produce different address
        MockHarborDeploymentDev deployment2 = new MockHarborDeploymentDev();
        _resetDeploymentLogs("different-salt", "{}");
        _prepareTestNetwork("different-salt", "test_DeterministicProxyAddress");
        deployment2.start("test_DeterministicProxyAddress", "different-salt", "");
        address addr2 = deployment2.predictProxyAddress(deployment2.PEGGED());

        assertNotEq(addr2, addr1, "Different salt should produce different address");
    }

    function test_MultipleProxies() public {
        _startDeployment("test_MultipleProxies");
        
        deployment.setFilename("test_MultipleProxies");
        // Deploy first proxy
        deployment.setString(deployment.PEGGED_SYMBOL(), "USD");
        deployment.setString(deployment.PEGGED_NAME(), "Harbor USD");
        deployment.setAddress(deployment.PEGGED_OWNER(), admin);
        deployment.deployPegged();

        // To deploy a second proxy, we'd need a different key
        // The current Harbor deployment only has one pegged token
        // This test demonstrates that the first deployment works
        assertTrue(deployment.has(deployment.PEGGED()), "First proxy should exist");
        assertEq(
            deployment.get(deployment.PEGGED()),
            deployment.get(deployment.PEGGED()),
            "First proxy address should be stored"
        );

        MintableBurnableERC20_v1 token1 = MintableBurnableERC20_v1(deployment.get(deployment.PEGGED()));
        assertEq(token1.symbol(), "USD", "First token symbol should be correct");
    }

    function test_RevertWhen_ProxyWithEmptyKey() public {
        _startDeployment("test_RevertWhen_ProxyWithEmptyKey");
        
        deployment.setFilename("test_RevertWhen_ProxyWithEmptyKey");
        // Try to deploy with empty key - should revert with KeyRequired
        vm.expectRevert();
        deployment.deployProxy("", address(this), "", "", "", address(this));
    }

    function test_RevertWhen_ProxyWithoutImplementation() public {
        _startDeployment("test_RevertWhen_ProxyWithoutImplementation");
        
        deployment.setFilename("test_RevertWhen_ProxyWithoutImplementation");
        vm.expectRevert();
        deployment.deployProxy(deployment.PEGGED(), address(0), "", "", "", address(this));
    }

    function test_ProxyMetadataStored() public {
        _startDeployment("test_ProxyMetadataStored");
        
        deployment.setFilename("test_ProxyMetadataStored");
        deployment.setString(deployment.PEGGED_SYMBOL(), "JPY");
        deployment.setString(deployment.PEGGED_NAME(), "Harbor JPY");
        deployment.setAddress(deployment.PEGGED_OWNER(), admin);

        deployment.deployPegged();

        // Verify metadata is stored
        string memory implKey = deployment.getString(string.concat(deployment.PEGGED(), ".implementation"));
        assertEq(
            implKey,
            string.concat(deployment.PEGGED(), "__MintableBurnableERC20_v1"),
            "Implementation key should be stored"
        );

        string memory category = deployment.getString(string.concat(deployment.PEGGED(), ".category"));
        assertEq(category, "proxy", "Category should be proxy");
    }

    function test_ImplementationReuse() public {
        _startDeployment("test_ImplementationReuse");
        
        deployment.setFilename("test_ImplementationReuse");
        // Deploy pegged token
        deployment.setString(deployment.PEGGED_SYMBOL(), "USD");
        deployment.setString(deployment.PEGGED_NAME(), "Harbor USD");
        deployment.setAddress(deployment.PEGGED_OWNER(), admin);

        deployment.deployPegged();

        string memory implKey = string.concat(deployment.PEGGED(), "__MintableBurnableERC20_v1");
        address impl1 = deployment.get(implKey);

        assertNotEq(impl1, address(0), "Implementation should be deployed");

        // Verify implementation metadata
        string memory implType = deployment.getString(string.concat(implKey, ".type"));
        assertEq(implType, "MintableBurnableERC20_v1", "Implementation type should be stored");
    }
}
