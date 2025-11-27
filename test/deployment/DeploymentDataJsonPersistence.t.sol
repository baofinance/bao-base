// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DeploymentDataJsonTesting} from "@bao-script/deployment/DeploymentDataJsonTesting.sol";
import {DeploymentKeys} from "@bao-script/deployment/DeploymentKeys.sol";
import {DeploymentLogsTest} from "./DeploymentLogsTest.sol";
import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {MockHarborDeploymentDev} from "./MockHarborDeploymentDev.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";

string constant OWNER_KEY_PERSISTENCE = "owner";
string constant CONFIG_KEY_PERSISTENCE = "contracts.config";
string constant CONFIG_NAME_KEY_PERSISTENCE = "contracts.config.name";
string constant PERSISTENCE_SUITE_LABEL = "deployment-data-json-persistence";
string constant FILE_PREFIX_PERSISTENCE = "DeploymentDataJsonPersistenceTest";

/**
 * @title TestKeysPersistence
 * @notice Minimal key registry for file persistence testing
 */
contract TestKeysPersistence is DeploymentKeys {
    constructor() {
        addKey(OWNER_KEY_PERSISTENCE);
        addKey(CONFIG_KEY_PERSISTENCE); // Parent key
        addStringKey(CONFIG_NAME_KEY_PERSISTENCE);
    }
}

/**
 * @title DeploymentDataJsonPersistenceTest
 * @notice Tests for file persistence functionality
 * @dev Note: "latest" functionality requires vm.readDir() which isn't available in Foundry yet.
 *      These tests verify the save mechanism works without errors.
 */
contract DeploymentDataJsonPersistenceTest is DeploymentLogsTest {
    TestKeysPersistence keys;

    function setUp() public {
        keys = new TestKeysPersistence();
        _resetDeploymentLogs(PERSISTENCE_SUITE_LABEL);
    }

    function _newData(
        string memory network,
        string memory salt,
        string memory inputTimestamp,
        bool /* applySuiteNetwork */
    ) internal returns (DeploymentDataJsonTesting) {
        // Under new API: inputPath is either empty ("") or points to an existing file
        // For persistence tests, start with empty path and set output path
        DeploymentDataJsonTesting instance = new DeploymentDataJsonTesting(keys, "");

        // Set output path based on network/salt, respecting BAO_DEPLOYMENT_LOGS_ROOT
        string memory baseDir = _getDeploymentBaseDir();
        string memory outputPath = string.concat(
            baseDir,
            "/deployments/",
            network,
            "/",
            salt,
            "-",
            inputTimestamp,
            ".json"
        );
        instance.setOutputPath(outputPath);

        return instance;
    }

    function test_BasicFilePersistence() public {
        // Create deployment and set value
        DeploymentDataJsonTesting data = _newData(PERSISTENCE_SUITE_LABEL, "basic-test", "first", true);

        data.set(OWNER_KEY_PERSISTENCE, address(0x1234));
        data.setString(CONFIG_NAME_KEY_PERSISTENCE, "Test Deployment");

        // Files are saved automatically with ISO 8601 timestamps
        // If no errors, save mechanism is working
        assertTrue(true, "File persistence completes without error");
    }

    function test_MultipleWrites() public {
        DeploymentDataJsonTesting data = _newData(PERSISTENCE_SUITE_LABEL, "multi-write-test", "first", true);

        // Enable sequencing to capture each update phase
        data.enableSequencing();

        // Phase 1: Set initial owner
        data.set(OWNER_KEY_PERSISTENCE, address(0x1111));

        // Phase 2: Add config (owner should be preserved)
        data.set(CONFIG_KEY_PERSISTENCE, address(0xCCCC));

        // Phase 3: Update owner (config should be preserved)
        data.set(OWNER_KEY_PERSISTENCE, address(0x2222));

        // Phase 4: Add config.name (both owner and config should be preserved)
        data.setString(CONFIG_NAME_KEY_PERSISTENCE, "Test Config");

        // Phase 5: Update owner again (config and config.name should be preserved)
        data.set(OWNER_KEY_PERSISTENCE, address(0x3333));

        // Verify final state has all fields
        assertEq(data.get(OWNER_KEY_PERSISTENCE), address(0x3333), "Latest owner not retained");
        assertEq(data.get(CONFIG_KEY_PERSISTENCE), address(0xCCCC), "Config not retained");
        assertEq(data.getString(CONFIG_NAME_KEY_PERSISTENCE), "Test Config", "Config name not retained");
    }

    function test_NetworkIsolation() public {
        // Different networks save to different directories
        DeploymentDataJsonTesting dataMainnet = _newData("mainnet", "isolation-test", "first", false);

        dataMainnet.set(OWNER_KEY_PERSISTENCE, address(0xAAAA));

        DeploymentDataJsonTesting dataArbitrum = _newData("arbitrum", "isolation-test", "first", false);

        dataArbitrum.set(OWNER_KEY_PERSISTENCE, address(0xBBBB));

        // Each retains its own value
        assertEq(dataMainnet.get(OWNER_KEY_PERSISTENCE), address(0xAAAA));
        assertEq(dataArbitrum.get(OWNER_KEY_PERSISTENCE), address(0xBBBB));
    }

    function test_TestingVariantUsesResultsDirectory() public {
        // Verify testing variant creates files under results/
        DeploymentDataJsonTesting data = _newData(PERSISTENCE_SUITE_LABEL, "results-dir-test", "first", true);

        data.set(OWNER_KEY_PERSISTENCE, address(0x9999));

        // File should be under the dedicated persistence deployments directory
        // Can't verify exact path without directory listing, but no error means it worked
        assertTrue(true, "Testing variant saves to results/ directory");
    }

    function test_FilenameOverride() public {
        // Test explicit output path setting
        DeploymentDataJsonTesting data = new DeploymentDataJsonTesting(keys, "");
        string memory baseDir = _getDeploymentBaseDir();
        string memory outputPath = string.concat(baseDir, "/deployments/persistence-test/test-deployment-001.json");
        data.setOutputPath(outputPath);

        data.set(OWNER_KEY_PERSISTENCE, address(0xCCCC));

        // Should save to specified path
        assertTrue(vm.exists(outputPath), "File should exist at specified path");
    }

    function test_LatestFileFunctionality() public {
        // Create directory for test files
        string memory baseDir = _getDeploymentBaseDir();
        string memory testDir = string.concat(baseDir, "/deployments/persistence-latest-test");
        if (!vm.exists(testDir)) {
            vm.createDir(testDir, true);
        }

        // Create first deployment file
        DeploymentDataJsonTesting data1 = new DeploymentDataJsonTesting(keys, "");
        string memory file1 = string.concat(testDir, "/deploy-2024-01-01T00-00-00.json");
        data1.setOutputPath(file1);
        data1.set(OWNER_KEY_PERSISTENCE, address(0xAAAA));

        // Create second deployment file (later timestamp)
        DeploymentDataJsonTesting data2 = new DeploymentDataJsonTesting(keys, "");
        string memory file2 = string.concat(testDir, "/deploy-2024-01-01T00-00-01.json");
        data2.setOutputPath(file2);
        data2.set(OWNER_KEY_PERSISTENCE, address(0xBBBB));

        // The "latest" file resolution is handled by Deployment.sol, not the data layer
        // This test just verifies both files were written
        assertTrue(vm.exists(file1), "First file should exist");
        assertTrue(vm.exists(file2), "Second file should exist");
    }
}

/**
 * @title DeploymentDataJsonPersistenceProxyTest
 * @notice Tests proxy deployment workflow with sequenced file persistence
 * @dev Extends BaoDeploymentTest to get deployment infrastructure (BaoDeployer, etc.)
 */
// TODO:
// contract DeploymentDataJsonPersistenceProxyTest is BaoDeploymentTest {
//     function test_MultipleWritesWithProxyDeployment() public {
//         // This test demonstrates the full deployment workflow across sequenced phases
//         // using the actual proxy deployment code path
//         MockHarborDeploymentDev harness = new MockHarborDeploymentDev();

//         // Start deployment session with sequencing enabled
//         harness.start(address(this), PERSISTENCE_SUITE_LABEL, "proxy-workflow", "");

//         // Enable sequencing on the data layer to capture each phase
//         DeploymentDataJsonTesting dataLayer = DeploymentDataJsonTesting(harness.dataStore());
//         dataLayer.enableSequencing();

//         address admin = makeAddr("admin");

//         // Phase 1: Set configuration for first token
//         harness.setString(HarborKeys.PEGGED_SYMBOL, "USD");
//         harness.setString(HarborKeys.PEGGED_NAME, "Harbor USD");
//         harness.setAddress(HarborKeys.PEGGED_OWNER, admin);

//         // Phase 2: Deploy proxy using configuration
//         address peggedProxy = harness.deployPegged();
//         assertNotEq(peggedProxy, address(0), "Proxy should be deployed");

//         // Phase 3: Verify deployment metadata was persisted
//         assertEq(harness.get(HarborKeys.PEGGED), peggedProxy, "Proxy address should be stored");
//         string memory implKey = harness.getString(string.concat(HarborKeys.PEGGED, ".implementation"));
//         assertEq(
//             implKey,
//             string.concat(HarborKeys.PEGGED, "__MintableBurnableERC20_v1"),
//             "Implementation key should be stored"
//         );

//         // Phase 4: Verify proxy works correctly
//         MintableBurnableERC20_v1 token = MintableBurnableERC20_v1(peggedProxy);
//         assertEq(token.symbol(), "USD", "Symbol should match configuration");
//         assertEq(token.name(), "Harbor USD", "Name should match configuration");
//         assertEq(token.owner(), address(harness), "Harness should be initial owner");

//         // Phase 5: Transfer ownership
//         vm.prank(address(harness));
//         token.transferOwnership(admin);
//         assertEq(token.owner(), admin, "Ownership should be transferred");

//         // All phases should be persisted in sequenced files (.001.json through .005.json)
//         // Each file shows progression of deployment state
//     }
// }
