// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {MockDeployment} from "./MockDeployment.sol";

/**
 * @title BaoDeploymentTest
 * @notice Base test class for deployment-related tests
 * @dev Extends BaoTest and sets up deployment infrastructure (Nick's Factory + BaoDeployer)
 * @dev Test hierarchy:
 *      BaoTest (utility assertions)
 *        └─ BaoDeploymentTest (deployment infrastructure only)
 *             └─ MyDeploymentTest (creates MockDeployment as needed)
 * @dev For tests that don't need deployment infrastructure, extend BaoTest directly
 *
 * @dev NO DUPLICATION: Uses MockDeployment helpers which delegate to production
 *      Deployment._deployBaoDeployer() - tests and production share the same code.
 *
 * @dev NOTE: This base class does NOT declare a `deployment` variable.
 *      Derived test classes should declare and create their own MockDeployment:
 *          MockDeployment public deployment;
 *          function setUp() public override {
 *              super.setUp();
 *              deployment = new MockDeployment();
 *          }
 */
abstract contract BaoDeploymentTest is BaoTest {
    /**
     * @notice Set up deployment infrastructure for tests
     * @dev This runs once per test contract (not per test function)
     * @dev Uses MockDeployment helpers to deploy infrastructure:
     *      1. Nick's Factory (via etchNicksFactory)
     *      2. BaoDeployer proxy + implementation (via deployBaoDeployer)
     * @dev All logic comes from Deployment.sol - no duplication here
     * @dev Derived classes MUST call super.setUp() first, then create their deployment
     */
    function setUp() public virtual {
        // Use MockDeployment to access shared deployment logic
        MockDeployment tempDeployment = new MockDeployment();

        // Step 1: Etch Nick's Factory for test environment
        tempDeployment.etchNicksFactory();

        // Step 2: Deploy BaoDeployer (implementation + proxy) with this contract as owner/deployer
        // This calls Deployment._deployBaoDeployer() which properly deploys via CREATE2
        address[] memory initialDeployers = new address[](1);
        initialDeployers[0] = address(this);
        tempDeployment.deployBaoDeployer(address(this), initialDeployers);

        // Step 3: Derived classes create their own deployment instance after calling super.setUp()
    }
}
