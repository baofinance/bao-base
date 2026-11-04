// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {FactoryDeployer} from "@bao-script/deployment/FactoryDeployer.sol";

/// @notice A deploy run with nothing of its own: what `FactoryDeployer` answers is what every run answers.
contract Run is FactoryDeployer {
    function treasury() public pure override returns (address) {
        return address(1);
    }

    function owner() public pure override returns (address) {
        return address(2);
    }
}

/// @notice Who owns what a run deploys until the hand-over: the context decides, and no run says otherwise. The
///         script half - a script's sender, before and under `vm.startBroadcast()` - is what a forge script run
///         sees, which no forge test can be, and was read from one (see `FactoryDeployer.deployerOwner`).
contract DeployerOwnerTest is BaoTest {
    /// @dev In a forge test the run contract owns what it deploys: the test holds the run and sends its
    ///      configuring calls from it, whoever calls into it.
    function test_inATestTheRunContractIsTheDeployerOwner() public {
        Run run = new Run();
        address caller = makeAddr("caller");
        vm.startPrank(caller);
        address deployerOwner = run.deployerOwner();
        vm.stopPrank();
        assertEq(deployerOwner, address(run), "the run contract, not its caller");
    }
}
