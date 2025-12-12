// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;
import {console2} from "forge-std/console2.sol";

import {BaoTest} from "@bao-test/BaoTest.sol";
import {DeploymentBase} from "@bao-script/deployment/DeploymentBase.sol";
import {BaoFactoryLib} from "@bao-factory/BaoFactoryLib.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {DeploymentTestingOutput} from "@bao-script/deployment/DeploymentJsonTesting.sol";
import {LibString} from "@solady/utils/LibString.sol";

/**
 * @title BaoDeploymentTest
 * @notice Base test class for deployment-related tests
 * @dev Extends BaoTest and sets up deployment infrastructure (Nick's Factory + BaoFactory)
 * @dev Test hierarchy:
 *      BaoTest (utility assertions)
 *        └─ BaoDeploymentTest (deployment infrastructure only)
 *             └─ MyDeploymentTest (creates DeploymentTesting as needed)
 * @dev For tests that don't need deployment infrastructure, extend BaoTest directly
 *
 * @dev NOTE: This base class does NOT declare a `deployment` variable.
 *      Derived test classes should declare and create their own DeploymentTesting:
 *          DeploymentTesting public deployment;
 *          function setUp() public override {
 *              super.setUp();
 *              deployment = new DeploymentTesting();
 *          }
 */
abstract contract BaoDeploymentTest is BaoTest {
    using LibString for string;

    address internal _baoFactory;
    address internal _baoMultisig;

    /**
     * @notice Set up deployment infrastructure for tests
     * @dev This runs once per test contract (not per test function)
     * @dev Nick's Factory set up if needed (via etchNicksFactory)
     */
    function setUp() public virtual {
        // TODO: all this should go other than the labelling
        // install Nick's factory if not present
        if (DeploymentInfrastructure._NICKS_FACTORY.code.length == 0) {
            vm.etch(DeploymentInfrastructure._NICKS_FACTORY, DeploymentInfrastructure._NICKS_FACTORY_BYTECODE);
            console2.log("etched Nick's factory");
        }
        vm.label(DeploymentInfrastructure._NICKS_FACTORY, "Nick's factory");

        // Get owner from BaoFactoryLib constant (avoids call to non-contract address)
        _baoMultisig = BaoFactoryLib.PRODUCTION_OWNER;
        vm.label(_baoMultisig, "_baoMultisig");

        // don't deploy it - that is the job of start()
        // _baoFactory = DeploymentInfrastructure._ensureBaoFactory();
        _baoFactory = DeploymentInfrastructure.predictBaoFactoryAddress();
        vm.label(_baoFactory, "_baoFactory");
    }

    /// @notice Default test owner address
    address internal constant DEFAULT_TEST_OWNER = address(0x1234);

    /// @notice Initialize deployment test directory for a salt and network
    /// @dev Idempotent - only writes config.json if it doesn't exist
    ///      Directory cleaning should be done externally (e.g., rm -rf results/deployments before forge test)
    /// @dev If configJson is empty "", uses default config with owner
    /// @param salt The deployment salt (typically the test contract name)
    /// @param network The network/test name (creates a subdirectory for this test's output)
    function _initDeploymentTest(string memory salt, string memory network) internal {
        string memory baseDir = DeploymentTestingOutput._getPrefix();
        string memory deploymentsDir = baseDir.concat("/deployments");
        string memory configPath = deploymentsDir.concat("/").concat(salt).concat(".json");

        // Ensure base directory exists
        vm.createDir(deploymentsDir, true);

        // Only write config if it doesn't exist - makes this idempotent for parallel tests
        if (!vm.exists(configPath)) {
            vm.writeJson('{"owner":"0x0000000000000000000000000000000000001234"}', configPath);
        }

        // Create output directory for this test's output (salt/network)
        string memory outputDir = deploymentsDir.concat("/").concat(salt).concat("/").concat(network);
        vm.createDir(outputDir, true);
    }

    /// @notice Verify that finish() properly recorded session completion metadata
    /// @dev Checks finishTimestamp, finishBlock, and finished (ISO string) are sensible
    /// @param deployment The deployment instance to check
    function _assertFinishState(DeploymentBase deployment) internal view {
        uint256 startTimestamp = deployment.getUint(deployment.SESSION_START_TIMESTAMP());
        uint256 finishTimestamp = deployment.getUint(deployment.SESSION_FINISH_TIMESTAMP());
        uint256 startBlock = deployment.getUint(deployment.SESSION_START_BLOCK());
        uint256 finishBlock = deployment.getUint(deployment.SESSION_FINISH_BLOCK());
        string memory finished = deployment.getString(deployment.SESSION_FINISHED());

        // Finish timestamp must be set and >= start
        assertGt(finishTimestamp, 0, "finishTimestamp should be set");
        assertGe(finishTimestamp, startTimestamp, "finishTimestamp should be >= startTimestamp");

        // Finish block must be set and >= start
        assertGt(finishBlock, 0, "finishBlock should be set");
        assertGe(finishBlock, startBlock, "finishBlock should be >= startBlock");

        // Finished ISO string must be non-empty
        assertGt(bytes(finished).length, 0, "finished ISO string should be set");
    }
}
