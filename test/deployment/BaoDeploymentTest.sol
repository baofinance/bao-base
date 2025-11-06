// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {MockDeployment} from "./MockDeployment.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";

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
    address internal _baoDeployer;
    address internal _baoMultisig;

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
        // install Nick's factory if not present
        if (DeploymentInfrastructure._NICKS_FACTORY.code.length == 0) {
            vm.etch(DeploymentInfrastructure._NICKS_FACTORY, DeploymentInfrastructure._NICKS_FACTORY_BYTECODE);
        }
        vm.label(DeploymentInfrastructure._NICKS_FACTORY, "Nick's factory");

        _baoMultisig = DeploymentInfrastructure.BAOMULTISIG;
        vm.label(_baoMultisig, "_baoMultisig");

        _baoDeployer = DeploymentInfrastructure.predictBaoDeployerAddress();
        if (_baoDeployer.code.length == 0) {
            DeploymentInfrastructure.deployBaoDeployer();
        }
        vm.label(_baoDeployer, "_baoDeployer");
    }
}
