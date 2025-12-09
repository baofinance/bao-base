// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {DeploymentJsonTesting} from "@bao-script/deployment/DeploymentJsonTesting.sol";
import {DeploymentDataMemory} from "@bao-script/deployment/DeploymentDataMemory.sol";

// ============================================================================
// Test Harness
// ============================================================================

contract MockDeploymentRoles is DeploymentJsonTesting {
    string public constant PEGGED = "contracts.pegged";
    string public constant MINTER = "contracts.minter";
    string public constant HUB = "contracts.hub";

    constructor() {
        _disableLogging(); // Prevent file writes during unit tests
        addContract(PEGGED);
        addContract(MINTER);
        addContract(HUB);
    }

    function registerRole(string memory contractKey, string memory roleName, uint256 value) external {
        _setRole(contractKey, roleName, value);
    }

    function registerGrantee(string memory granteeKey, string memory contractKey, string memory roleName) external {
        _setGrantee(granteeKey, contractKey, roleName);
    }

    function getRoleValue(string memory contractKey, string memory roleName) external view returns (uint256) {
        return _getRoleValue(contractKey, roleName);
    }

    function hasRole(string memory contractKey, string memory roleName) external view returns (bool) {
        return _hasRole(contractKey, roleName);
    }

    function getRoleGrantees(
        string memory contractKey,
        string memory roleName
    ) external view returns (string[] memory) {
        return _getRoleGrantees(contractKey, roleName);
    }

    function getContractRoleNames(string memory contractKey) external view returns (string[] memory) {
        return _getContractRoleNames(contractKey);
    }

    function computeExpectedRoles(string memory contractKey, string memory granteeKey) external view returns (uint256) {
        return _computeExpectedRoles(contractKey, granteeKey);
    }

    function fromJsonNoSave(string memory json) external {
        _fromJsonNoSave(json);
    }

    /// @notice Set a contract address directly (for tests that don't need full deployment session)
    function setContractAddress(string memory key, address addr) external {
        _set(key, addr);
    }

    /// @notice Expose _expectRolesOf for testing
    function expectRolesOf(
        uint256 actualBitmap,
        string memory contractKey,
        string[] memory roleNames,
        string memory granteeKey
    ) external view {
        _expectRolesOf(actualBitmap, contractKey, roleNames, granteeKey);
    }

    /// @notice Expose _roles helpers for testing
    function roles(string memory role1) external pure returns (string[] memory) {
        return _roles(role1);
    }

    function roles(string memory role1, string memory role2) external pure returns (string[] memory) {
        return _roles(role1, role2);
    }

    function roles(
        string memory role1,
        string memory role2,
        string memory role3
    ) external pure returns (string[] memory) {
        return _roles(role1, role2, role3);
    }
}

// ============================================================================
// Test Setup
// ============================================================================

contract DeploymentRolesSetup is BaoTest {
    MockDeploymentRoles internal deployment;

    function setUp() public virtual {
        deployment = new MockDeploymentRoles();
    }
}

// ============================================================================
// Role Registration Tests
// ============================================================================

contract DeploymentRolesRegistrationTest is DeploymentRolesSetup {
    function test_RegisterRole_StoresValue() public {
        deployment.registerRole("contracts.pegged", "MINTER_ROLE", 1);

        assertEq(deployment.getRoleValue("contracts.pegged", "MINTER_ROLE"), 1);
        assertTrue(deployment.hasRole("contracts.pegged", "MINTER_ROLE"));
    }

    function test_RegisterRole_TracksRoleName() public {
        deployment.registerRole("contracts.pegged", "MINTER_ROLE", 1);
        deployment.registerRole("contracts.pegged", "BURNER_ROLE", 2);

        string[] memory roleNames = deployment.getContractRoleNames("contracts.pegged");
        assertEq(roleNames.length, 2);
        assertEq(roleNames[0], "MINTER_ROLE");
        assertEq(roleNames[1], "BURNER_ROLE");
    }

    function test_RegisterRole_SameValueIsNoop() public {
        deployment.registerRole("contracts.pegged", "MINTER_ROLE", 1);
        deployment.registerRole("contracts.pegged", "MINTER_ROLE", 1); // Same value, no error

        assertEq(deployment.getRoleValue("contracts.pegged", "MINTER_ROLE"), 1);
    }

    function test_RegisterRole_DifferentValueReverts() public {
        deployment.registerRole("contracts.pegged", "MINTER_ROLE", 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentDataMemory.RoleValueMismatch.selector,
                "contracts.pegged.roles.MINTER_ROLE",
                1,
                2
            )
        );
        deployment.registerRole("contracts.pegged", "MINTER_ROLE", 2);
    }
}

// ============================================================================
// Grantee Registration Tests
// ============================================================================

contract DeploymentRolesGranteeTest is DeploymentRolesSetup {
    function test_RegisterGrantee_StoresGrantee() public {
        deployment.registerRole("contracts.pegged", "MINTER_ROLE", 1);
        deployment.registerGrantee("contracts.minter", "contracts.pegged", "MINTER_ROLE");

        string[] memory grantees = deployment.getRoleGrantees("contracts.pegged", "MINTER_ROLE");
        assertEq(grantees.length, 1);
        assertEq(grantees[0], "contracts.minter");
    }

    function test_RegisterGrantee_MultipleGrantees() public {
        deployment.registerRole("contracts.pegged", "MINTER_ROLE", 1);
        deployment.registerGrantee("contracts.minter", "contracts.pegged", "MINTER_ROLE");
        deployment.registerGrantee("contracts.hub", "contracts.pegged", "MINTER_ROLE");

        string[] memory grantees = deployment.getRoleGrantees("contracts.pegged", "MINTER_ROLE");
        assertEq(grantees.length, 2);
        assertEq(grantees[0], "contracts.minter");
        assertEq(grantees[1], "contracts.hub");
    }

    function test_RegisterGrantee_DuplicateReverts() public {
        deployment.registerRole("contracts.pegged", "MINTER_ROLE", 1);
        deployment.registerGrantee("contracts.minter", "contracts.pegged", "MINTER_ROLE");

        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentDataMemory.DuplicateGrantee.selector,
                "contracts.pegged.roles.MINTER_ROLE",
                "contracts.minter"
            )
        );
        deployment.registerGrantee("contracts.minter", "contracts.pegged", "MINTER_ROLE");
    }
}

// ============================================================================
// Expected Roles Computation Tests
// ============================================================================

contract DeploymentRolesComputeTest is DeploymentRolesSetup {
    function test_ComputeExpectedRoles_SingleRole() public {
        deployment.registerRole("contracts.pegged", "MINTER_ROLE", 1);
        deployment.registerGrantee("contracts.minter", "contracts.pegged", "MINTER_ROLE");

        uint256 expected = deployment.computeExpectedRoles("contracts.pegged", "contracts.minter");
        assertEq(expected, 1);
    }

    function test_ComputeExpectedRoles_MultipleRoles() public {
        deployment.registerRole("contracts.pegged", "MINTER_ROLE", 1);
        deployment.registerRole("contracts.pegged", "BURNER_ROLE", 2);
        deployment.registerGrantee("contracts.minter", "contracts.pegged", "MINTER_ROLE");
        deployment.registerGrantee("contracts.minter", "contracts.pegged", "BURNER_ROLE");

        uint256 expected = deployment.computeExpectedRoles("contracts.pegged", "contracts.minter");
        assertEq(expected, 3); // 1 | 2
    }

    function test_ComputeExpectedRoles_NoRolesGranted() public {
        deployment.registerRole("contracts.pegged", "MINTER_ROLE", 1);
        // No grantee registered

        uint256 expected = deployment.computeExpectedRoles("contracts.pegged", "contracts.minter");
        assertEq(expected, 0);
    }

    function test_ComputeExpectedRoles_PartialRoles() public {
        deployment.registerRole("contracts.pegged", "MINTER_ROLE", 1);
        deployment.registerRole("contracts.pegged", "BURNER_ROLE", 2);
        deployment.registerGrantee("contracts.minter", "contracts.pegged", "MINTER_ROLE");
        // contracts.minter does NOT have BURNER_ROLE

        uint256 expected = deployment.computeExpectedRoles("contracts.pegged", "contracts.minter");
        assertEq(expected, 1); // Only MINTER_ROLE
    }
}

// ============================================================================
// JSON Serialization Tests
// ============================================================================

contract DeploymentRolesJsonTest is DeploymentRolesSetup {
    function test_toJson_IncludesRoles() public {
        // Set contract address directly (bypasses session requirement)
        deployment.setContractAddress("contracts.pegged", address(0xBEEF));

        deployment.registerRole("contracts.pegged", "MINTER_ROLE", 1);
        deployment.registerGrantee("contracts.minter", "contracts.pegged", "MINTER_ROLE");

        string memory json = deployment.toJson();

        // Check that roles structure exists
        assertTrue(vm.keyExistsJson(json, "$.contracts.pegged.roles"));
        assertTrue(vm.keyExistsJson(json, "$.contracts.pegged.roles.MINTER_ROLE"));
        assertTrue(vm.keyExistsJson(json, "$.contracts.pegged.roles.MINTER_ROLE.value"));
        assertTrue(vm.keyExistsJson(json, "$.contracts.pegged.roles.MINTER_ROLE.grantees"));

        // Check values
        uint256 value = vm.parseJsonUint(json, "$.contracts.pegged.roles.MINTER_ROLE.value");
        assertEq(value, 1);

        string[] memory grantees = vm.parseJsonStringArray(json, "$.contracts.pegged.roles.MINTER_ROLE.grantees");
        assertEq(grantees.length, 1);
        assertEq(grantees[0], "contracts.minter");
    }

    function test_toJson_MultipleRoles() public {
        deployment.setContractAddress("contracts.pegged", address(0xBEEF));

        deployment.registerRole("contracts.pegged", "MINTER_ROLE", 1);
        deployment.registerRole("contracts.pegged", "BURNER_ROLE", 2);
        deployment.registerGrantee("contracts.minter", "contracts.pegged", "MINTER_ROLE");
        deployment.registerGrantee("contracts.hub", "contracts.pegged", "MINTER_ROLE");
        deployment.registerGrantee("contracts.minter", "contracts.pegged", "BURNER_ROLE");

        string memory json = deployment.toJson();

        // Check MINTER_ROLE
        uint256 minterValue = vm.parseJsonUint(json, "$.contracts.pegged.roles.MINTER_ROLE.value");
        assertEq(minterValue, 1);
        string[] memory minterGrantees = vm.parseJsonStringArray(json, "$.contracts.pegged.roles.MINTER_ROLE.grantees");
        assertEq(minterGrantees.length, 2);

        // Check BURNER_ROLE
        uint256 burnerValue = vm.parseJsonUint(json, "$.contracts.pegged.roles.BURNER_ROLE.value");
        assertEq(burnerValue, 2);
        string[] memory burnerGrantees = vm.parseJsonStringArray(json, "$.contracts.pegged.roles.BURNER_ROLE.grantees");
        assertEq(burnerGrantees.length, 1);
    }

    function test_fromJson_LoadsRoles() public {
        string
            memory json = '{"schemaVersion":1,"contracts":{"pegged":{"roles":{"MINTER_ROLE":{"value":1,"grantees":["contracts.minter"]}}}}}';

        deployment.fromJsonNoSave(json);

        assertTrue(deployment.hasRole("contracts.pegged", "MINTER_ROLE"));
        assertEq(deployment.getRoleValue("contracts.pegged", "MINTER_ROLE"), 1);

        string[] memory grantees = deployment.getRoleGrantees("contracts.pegged", "MINTER_ROLE");
        assertEq(grantees.length, 1);
        assertEq(grantees[0], "contracts.minter");
    }

    function test_fromJson_LoadsMultipleRoles() public {
        string
            memory json = '{"schemaVersion":1,"contracts":{"pegged":{"roles":{"MINTER_ROLE":{"value":1,"grantees":["contracts.minter","contracts.hub"]},"BURNER_ROLE":{"value":2,"grantees":["contracts.minter"]}}}}}';

        deployment.fromJsonNoSave(json);

        assertEq(deployment.getRoleValue("contracts.pegged", "MINTER_ROLE"), 1);
        assertEq(deployment.getRoleValue("contracts.pegged", "BURNER_ROLE"), 2);

        string[] memory minterGrantees = deployment.getRoleGrantees("contracts.pegged", "MINTER_ROLE");
        assertEq(minterGrantees.length, 2);

        string[] memory burnerGrantees = deployment.getRoleGrantees("contracts.pegged", "BURNER_ROLE");
        assertEq(burnerGrantees.length, 1);
    }
}

// ============================================================================
// JSON Round-Trip Tests
// ============================================================================

contract DeploymentRolesRoundTripTest is DeploymentRolesSetup {
    function test_RoundTrip_PreservesRoles() public {
        // Set up initial state (using setContractAddress to bypass session requirement)
        deployment.setContractAddress("contracts.pegged", address(0xBEEF));
        deployment.registerRole("contracts.pegged", "MINTER_ROLE", 1);
        deployment.registerRole("contracts.pegged", "BURNER_ROLE", 2);
        deployment.registerGrantee("contracts.minter", "contracts.pegged", "MINTER_ROLE");
        deployment.registerGrantee("contracts.hub", "contracts.pegged", "MINTER_ROLE");
        deployment.registerGrantee("contracts.minter", "contracts.pegged", "BURNER_ROLE");

        // Serialize to JSON
        string memory json = deployment.toJson();

        // Create fresh deployment and load from JSON
        MockDeploymentRoles newDeployment = new MockDeploymentRoles();
        newDeployment.fromJsonNoSave(json);

        // Verify roles are preserved
        assertEq(newDeployment.getRoleValue("contracts.pegged", "MINTER_ROLE"), 1);
        assertEq(newDeployment.getRoleValue("contracts.pegged", "BURNER_ROLE"), 2);

        string[] memory minterGrantees = newDeployment.getRoleGrantees("contracts.pegged", "MINTER_ROLE");
        assertEq(minterGrantees.length, 2);
        assertEq(minterGrantees[0], "contracts.minter");
        assertEq(minterGrantees[1], "contracts.hub");

        string[] memory burnerGrantees = newDeployment.getRoleGrantees("contracts.pegged", "BURNER_ROLE");
        assertEq(burnerGrantees.length, 1);
        assertEq(burnerGrantees[0], "contracts.minter");

        // Verify computed roles match
        assertEq(
            newDeployment.computeExpectedRoles("contracts.pegged", "contracts.minter"),
            3 // MINTER_ROLE | BURNER_ROLE
        );
        assertEq(
            newDeployment.computeExpectedRoles("contracts.pegged", "contracts.hub"),
            1 // MINTER_ROLE only
        );
    }
}

// ============================================================================
// _expectRolesOf Verification Tests
// ============================================================================

contract DeploymentRolesExpectTest is DeploymentRolesSetup {
    /// @notice Test that _expectRolesOf passes when bitmap matches expected roles
    function test_ExpectRolesOf_PassesWhenMatches() public {
        // Setup: register roles and grantees
        deployment.registerRole("contracts.pegged", "MINTER_ROLE", 1);
        deployment.registerRole("contracts.pegged", "BURNER_ROLE", 2);
        deployment.registerGrantee("contracts.minter", "contracts.pegged", "MINTER_ROLE");
        deployment.registerGrantee("contracts.minter", "contracts.pegged", "BURNER_ROLE");

        // Simulate on-chain bitmap (MINTER_ROLE | BURNER_ROLE = 1 | 2 = 3)
        uint256 actualBitmap = 3;

        // This should pass (log success, not revert)
        // We can't easily assert console2.log output, but we verify it doesn't revert
        deployment.expectRolesOf(
            actualBitmap,
            "contracts.pegged",
            deployment.roles("MINTER_ROLE", "BURNER_ROLE"),
            "contracts.minter"
        );
    }

    /// @notice Test with single role
    function test_ExpectRolesOf_SingleRole() public {
        deployment.registerRole("contracts.pegged", "MINTER_ROLE", 1);
        deployment.registerGrantee("contracts.minter", "contracts.pegged", "MINTER_ROLE");

        uint256 actualBitmap = 1;

        deployment.expectRolesOf(actualBitmap, "contracts.pegged", deployment.roles("MINTER_ROLE"), "contracts.minter");
    }

    /// @notice Test with three roles
    function test_ExpectRolesOf_ThreeRoles() public {
        deployment.registerRole("contracts.pegged", "MINTER_ROLE", 1);
        deployment.registerRole("contracts.pegged", "BURNER_ROLE", 2);
        deployment.registerRole("contracts.pegged", "ADMIN_ROLE", 4);
        deployment.registerGrantee("contracts.minter", "contracts.pegged", "MINTER_ROLE");
        deployment.registerGrantee("contracts.minter", "contracts.pegged", "BURNER_ROLE");
        deployment.registerGrantee("contracts.minter", "contracts.pegged", "ADMIN_ROLE");

        uint256 actualBitmap = 7; // 1 | 2 | 4

        deployment.expectRolesOf(
            actualBitmap,
            "contracts.pegged",
            deployment.roles("MINTER_ROLE", "BURNER_ROLE", "ADMIN_ROLE"),
            "contracts.minter"
        );
    }

    /// @notice Test that _expectRolesOf logs error when bitmap doesn't match
    /// @dev We can't assert console2.log output, but we verify it doesn't revert
    ///      and the function completes (it logs errors instead of reverting)
    function test_ExpectRolesOf_LogsErrorWhenBitmapMismatch() public {
        deployment.registerRole("contracts.pegged", "MINTER_ROLE", 1);
        deployment.registerRole("contracts.pegged", "BURNER_ROLE", 2);
        deployment.registerGrantee("contracts.minter", "contracts.pegged", "MINTER_ROLE");
        deployment.registerGrantee("contracts.minter", "contracts.pegged", "BURNER_ROLE");

        // Wrong bitmap - actual has extra role bit set
        uint256 wrongBitmap = 7; // Expected 3 (1 | 2)

        // This logs an error but doesn't revert
        deployment.expectRolesOf(
            wrongBitmap,
            "contracts.pegged",
            deployment.roles("MINTER_ROLE", "BURNER_ROLE"),
            "contracts.minter"
        );
    }

    /// @notice Test that _expectRolesOf logs error when grantee not recorded
    function test_ExpectRolesOf_LogsErrorWhenGranteeNotRecorded() public {
        deployment.registerRole("contracts.pegged", "MINTER_ROLE", 1);
        deployment.registerRole("contracts.pegged", "BURNER_ROLE", 2);
        // Only register MINTER_ROLE grantee, not BURNER_ROLE
        deployment.registerGrantee("contracts.minter", "contracts.pegged", "MINTER_ROLE");

        // Correct bitmap
        uint256 actualBitmap = 3;

        // This logs an error (grantee not recorded for BURNER_ROLE) but doesn't revert
        deployment.expectRolesOf(
            actualBitmap,
            "contracts.pegged",
            deployment.roles("MINTER_ROLE", "BURNER_ROLE"),
            "contracts.minter"
        );
    }
}

// ============================================================================
// _roles Helper Tests
// ============================================================================

contract DeploymentRolesHelperTest is DeploymentRolesSetup {
    function test_Roles_SingleElement() public view {
        string[] memory arr = deployment.roles("MINTER_ROLE");
        assertEq(arr.length, 1);
        assertEq(arr[0], "MINTER_ROLE");
    }

    function test_Roles_TwoElements() public view {
        string[] memory arr = deployment.roles("MINTER_ROLE", "BURNER_ROLE");
        assertEq(arr.length, 2);
        assertEq(arr[0], "MINTER_ROLE");
        assertEq(arr[1], "BURNER_ROLE");
    }

    function test_Roles_ThreeElements() public view {
        string[] memory arr = deployment.roles("MINTER_ROLE", "BURNER_ROLE", "ADMIN_ROLE");
        assertEq(arr.length, 3);
        assertEq(arr[0], "MINTER_ROLE");
        assertEq(arr[1], "BURNER_ROLE");
        assertEq(arr[2], "ADMIN_ROLE");
    }
}
