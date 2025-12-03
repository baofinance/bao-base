// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "./BaoDeploymentTest.sol";
import {Create3CommitFlow} from "@bao-script/deployment/Create3CommitFlow.sol";
import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";

contract Create3Target {
    uint256 public constant MAGIC = 0xBEEF;
}

contract Create3CommitFlowTest is BaoDeploymentTest {
    function setUp() public override {
        super.setUp();
        // Set operator to this test contract so it can call commit/reveal
        address baoDeployer = DeploymentInfrastructure._ensureBaoDeployer();
        if (BaoDeployer(baoDeployer).operator() != address(this)) {
            vm.prank(DeploymentInfrastructure.BAOMULTISIG);
            BaoDeployer(baoDeployer).setOperator(address(this));
        }
    }

    function _buildRequest(
        string memory key,
        uint256 value
    ) internal view returns (Create3CommitFlow.Request memory req) {
        req.operator = address(this);
        req.systemSaltString = "test-system";
        req.key = key;
        req.initCode = type(Create3Target).creationCode;
        req.value = value;
    }

    function testCommitOnlyRecordsCommitment_() public {
        Create3CommitFlow.Request memory req = _buildRequest("contracts.target", 0);
        (bytes32 salt, bytes32 commitment, address factory, BaoDeployer deployer) = Create3CommitFlow.commitOnly(req);

        assertEq(factory, DeploymentInfrastructure.predictBaoDeployerAddress(), "factory should match prediction");
        assertEq(address(deployer), factory, "deployer reference should match factory");
        assertEq(deployer.isCommitted(commitment), true, "commitment should be recorded");
        assertGt(uint256(salt), 0, "salt should be non-zero");
    }

    function testCommitAndRevealDeploysContract_() public {
        Create3CommitFlow.Request memory req = _buildRequest("contracts.deployed", 0);

        (address deployed, bytes32 salt, address factory) = Create3CommitFlow.commitAndReveal(
            req,
            Create3CommitFlow.RevealMode.MatchValue
        );

        assertEq(factory, DeploymentInfrastructure.predictBaoDeployerAddress(), "factory should match prediction");
        assertGt(uint256(salt), 0, "salt should be non-zero from reveal");
        assertEq(Create3Target(deployed).MAGIC(), 0xBEEF, "deployed contract should match target");
    }

    function testCommitAndRevealForceZeroValueReverts_() public {
        Create3CommitFlow.Request memory req = _buildRequest("contracts.forceZero", 1 ether);
        assertEq(req.value, 1 ether, "value should remain configured");
        vm.expectRevert(abi.encodeWithSelector(BaoDeployer.ValueMismatch.selector, 1 ether, uint256(0)));
        this.callCommitAndReveal(req, Create3CommitFlow.RevealMode.ForceZeroValue);
    }

    function testRevertWhenOperatorMissing_() public {
        Create3CommitFlow.Request memory req = _buildRequest("contracts.badOperator", 0);
        req.operator = address(0);
        vm.expectRevert(Create3CommitFlow.Create3CommitFlow_InvalidOperator.selector);
        this.callCommitOnly(req);
    }

    function testRevertWhenSystemSaltMissing_() public {
        Create3CommitFlow.Request memory req = _buildRequest("contracts.badSalt", 0);
        req.systemSaltString = "";
        vm.expectRevert(Create3CommitFlow.Create3CommitFlow_SystemSaltMissing.selector);
        this.callCommitOnly(req);
    }

    function testRevertWhenKeyMissing_() public {
        Create3CommitFlow.Request memory req = _buildRequest("contracts.badKey", 0);
        req.key = "";
        vm.expectRevert(Create3CommitFlow.Create3CommitFlow_KeyRequired.selector);
        this.callCommitOnly(req);
    }

    function testRevertWhenInitCodeMissing_() public {
        Create3CommitFlow.Request memory req = _buildRequest("contracts.badInit", 0);
        req.initCode = new bytes(0);
        vm.expectRevert(Create3CommitFlow.Create3CommitFlow_InitCodeMissing.selector);
        this.callCommitOnly(req);
    }

    function callCommitOnly(Create3CommitFlow.Request memory req) external {
        Create3CommitFlow.commitOnly(req);
    }

    function callCommitAndReveal(
        Create3CommitFlow.Request memory req,
        Create3CommitFlow.RevealMode mode
    ) external payable returns (address deployed) {
        (deployed, , ) = Create3CommitFlow.commitAndReveal(req, mode);
    }
}
