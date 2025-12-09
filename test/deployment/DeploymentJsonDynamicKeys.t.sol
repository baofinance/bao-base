// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {DeploymentJsonTesting} from "@bao-script/deployment/DeploymentJsonTesting.sol";
import {DeploymentKeys} from "@bao-script/deployment/DeploymentKeys.sol";

// Tests demonstrating that dynamically registered keys don't round-trip through JSON
// WITHOUT pattern registration, but DO round-trip WITH pattern registration.
//
// The problem (without patterns):
//   1. Keys registered after construction (e.g., in start()) write to JSON correctly
//   2. But they are NOT loaded back because _fromJsonNoSave() iterates only over schemaKeys()
//   3. schemaKeys() returns only keys registered at construction time
//
// The solution (with patterns):
//   - Use addAnyUintKeySuffix("networks", "chainId") to register pattern networks.*.chainId
//   - On JSON load: scan keys matching patterns and register them dynamically
//   - Round-trip now works because concrete keys are discovered from JSON

string constant NETWORKS = "networks";

/// @notice Test harness that registers dynamic keys like HarborDeploymentJsonScript does (OLD WAY)
/// @dev This demonstrates the BROKEN approach - dynamic registration without patterns
contract DynamicKeysDeployment is DeploymentJsonTesting {
    constructor() {
        // Register the parent NETWORKS key as an object
        addKey(NETWORKS);
        // NOTE: We do NOT register networks.*.chainId etc here - that's the problem
    }

    /// @notice Simulates what HarborDeploymentJsonScript.start() does
    /// @dev Registers network-specific keys dynamically at runtime
    function registerNetworkKeys(string memory network) public {
        string memory networkPrefix = string.concat(NETWORKS, ".", network);
        addUintKey(string.concat(networkPrefix, ".chainId"));
        addAddressKey(string.concat(networkPrefix, ".collateral"));
        addAddressKey(string.concat(networkPrefix, ".wrappedCollateral"));
    }

    function setNetworkData(
        string memory network,
        uint256 chainId,
        address collateral,
        address wrappedCollateral
    ) public {
        string memory networkPrefix = string.concat(NETWORKS, ".", network);
        _setUint(string.concat(networkPrefix, ".chainId"), chainId);
        _setAddress(string.concat(networkPrefix, ".collateral"), collateral);
        _setAddress(string.concat(networkPrefix, ".wrappedCollateral"), wrappedCollateral);
    }

    function getNetworkChainId(string memory network) public view returns (uint256) {
        return _getUint(string.concat(NETWORKS, ".", network, ".chainId"));
    }

    function getNetworkCollateral(string memory network) public view returns (address) {
        return _getAddress(string.concat(NETWORKS, ".", network, ".collateral"));
    }

    function fromJsonNoSave(string memory json) public {
        _fromJsonNoSave(json);
    }
}

/// @notice Test harness using PATTERN REGISTRATION (NEW WAY)
/// @dev This demonstrates the CORRECT approach - patterns registered in constructor
contract PatternKeysDeployment is DeploymentJsonTesting {
    constructor() {
        // Register the parent NETWORKS key as an object
        addKey(NETWORKS);
        // Register patterns for network-specific keys
        addAnyUintKeySuffix(NETWORKS, "chainId");
        addAnyAddressKeySuffix(NETWORKS, "collateral");
        addAnyAddressKeySuffix(NETWORKS, "wrappedCollateral");
    }

    function setNetworkData(
        string memory network,
        uint256 chainId,
        address collateral,
        address wrappedCollateral
    ) public {
        string memory networkPrefix = string.concat(NETWORKS, ".", network);
        // Need to register the intermediate object first
        addKey(networkPrefix);
        _setUint(string.concat(networkPrefix, ".chainId"), chainId);
        _setAddress(string.concat(networkPrefix, ".collateral"), collateral);
        _setAddress(string.concat(networkPrefix, ".wrappedCollateral"), wrappedCollateral);
    }

    function getNetworkChainId(string memory network) public view returns (uint256) {
        return _getUint(string.concat(NETWORKS, ".", network, ".chainId"));
    }

    function getNetworkCollateral(string memory network) public view returns (address) {
        return _getAddress(string.concat(NETWORKS, ".", network, ".collateral"));
    }

    function getNetworkWrappedCollateral(string memory network) public view returns (address) {
        return _getAddress(string.concat(NETWORKS, ".", network, ".wrappedCollateral"));
    }

    function fromJsonNoSave(string memory json) public {
        _fromJsonNoSave(json);
    }
}

contract DeploymentJsonDynamicKeysTest is Test {
    DynamicKeysDeployment deployment;

    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    function setUp() public {
        deployment = new DynamicKeysDeployment();
    }

    /// @notice Demonstrates that dynamically registered keys write to JSON correctly
    function test_DynamicKeysWriteToJson() public {
        // Register and set network data
        deployment.registerNetworkKeys("mainnet");
        deployment.setNetworkData("mainnet", 1, STETH, WSTETH);

        // Generate JSON
        string memory json = deployment.toJson();

        // Verify the data was written to JSON
        assertTrue(vm.keyExistsJson(json, "$.networks.mainnet.chainId"), "chainId should exist in JSON");
        assertEq(vm.parseJsonUint(json, "$.networks.mainnet.chainId"), 1, "chainId value should be 1");

        assertTrue(vm.keyExistsJson(json, "$.networks.mainnet.collateral"), "collateral should exist in JSON");
        assertEq(
            vm.parseJsonAddress(json, "$.networks.mainnet.collateral"),
            STETH,
            "collateral should be STETH address"
        );
    }

    /// @notice EXPECTED FAILURE: Demonstrates that dynamically registered keys are NOT loaded back
    /// @dev This test documents the broken behavior WITHOUT patterns:
    ///      1. The first deployment registers "networks.mainnet.chainId" dynamically
    ///      2. The JSON is generated with this key
    ///      3. A new deployment instance loads the JSON
    ///      4. BUT the new instance doesn't know about "networks.mainnet.chainId"
    ///      5. Because schemaKeys() only returns constructor-registered keys
    ///      6. So _fromJsonNoSave() never loads the value
    function test_RevertWhen_DynamicKeysDontRoundTrip() public {
        // === Phase 1: Create deployment with dynamic keys ===
        deployment.registerNetworkKeys("mainnet");
        deployment.setNetworkData("mainnet", 1, STETH, WSTETH);

        // Generate JSON
        string memory json = deployment.toJson();

        // === Phase 2: Load into fresh deployment WITHOUT registering dynamic keys ===
        DynamicKeysDeployment newDeployment = new DynamicKeysDeployment();
        newDeployment.fromJsonNoSave(json);

        // This reverts because the key was never registered (no pattern support in old approach)
        vm.expectRevert();
        newDeployment.getNetworkChainId("mainnet");
    }

    /// @notice Shows that re-registering dynamic keys before load makes it work
    /// @dev This is the current workaround, but it's fragile and error-prone
    function test_DynamicKeysWorkWithReregistration() public {
        // Phase 1: Create and save
        deployment.registerNetworkKeys("mainnet");
        deployment.setNetworkData("mainnet", 1, STETH, WSTETH);
        string memory json = deployment.toJson();

        // Phase 2: Load with re-registration (current workaround)
        DynamicKeysDeployment newDeployment = new DynamicKeysDeployment();
        newDeployment.registerNetworkKeys("mainnet"); // <-- Must know to call this!
        newDeployment.fromJsonNoSave(json);

        // This works because we re-registered the keys
        assertEq(newDeployment.getNetworkChainId("mainnet"), 1, "chainId should be 1 with workaround");
        assertEq(newDeployment.getNetworkCollateral("mainnet"), STETH, "collateral should be STETH with workaround");
    }

    /// @notice EXPECTED FAILURE: Multiple networks don't round-trip without patterns
    /// @dev Even worse: you have to know ALL network names in the JSON before loading
    function test_RevertWhen_MultipleNetworksDontRoundTrip() public {
        // Phase 1: Create with multiple networks
        deployment.registerNetworkKeys("mainnet");
        deployment.registerNetworkKeys("sepolia");
        deployment.setNetworkData("mainnet", 1, STETH, WSTETH);
        deployment.setNetworkData("sepolia", 11155111, address(0x1111), address(0x2222));

        string memory json = deployment.toJson();

        // Phase 2: Load fresh - neither network's data is loaded
        DynamicKeysDeployment newDeployment = new DynamicKeysDeployment();
        newDeployment.fromJsonNoSave(json);

        // This reverts because the key was never registered (no pattern support in old approach)
        vm.expectRevert();
        newDeployment.getNetworkChainId("mainnet");
    }
}

/// @notice Tests for pattern-based registration (the SOLUTION)
contract DeploymentJsonPatternKeysTest is Test {
    PatternKeysDeployment deployment;

    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    function setUp() public {
        deployment = new PatternKeysDeployment();
    }

    /// @notice Pattern-registered keys write to JSON correctly
    function test_PatternKeysWriteToJson() public {
        deployment.setNetworkData("mainnet", 1, STETH, WSTETH);

        string memory json = deployment.toJson();

        assertTrue(vm.keyExistsJson(json, "$.networks.mainnet.chainId"), "chainId should exist in JSON");
        assertEq(vm.parseJsonUint(json, "$.networks.mainnet.chainId"), 1, "chainId value should be 1");
        assertEq(
            vm.parseJsonAddress(json, "$.networks.mainnet.collateral"),
            STETH,
            "collateral should be STETH"
        );
    }

    /// @notice PASSING TEST: Pattern-registered keys round-trip correctly
    /// @dev This demonstrates the fix - patterns auto-discover keys from JSON
    function test_PatternKeysRoundTrip() public {
        // Phase 1: Create deployment with network data
        deployment.setNetworkData("mainnet", 1, STETH, WSTETH);

        // Verify data is set
        assertEq(deployment.getNetworkChainId("mainnet"), 1, "Phase 1: chainId should be 1");
        assertEq(deployment.getNetworkCollateral("mainnet"), STETH, "Phase 1: collateral should be STETH");

        // Generate JSON
        string memory json = deployment.toJson();

        // Phase 2: Load into fresh deployment - patterns auto-discover keys
        PatternKeysDeployment newDeployment = new PatternKeysDeployment();
        newDeployment.fromJsonNoSave(json);

        // This should PASS - patterns discover "networks.mainnet.*" keys from JSON
        assertEq(newDeployment.getNetworkChainId("mainnet"), 1, "Phase 2: chainId should be 1 after round-trip");
        assertEq(newDeployment.getNetworkCollateral("mainnet"), STETH, "Phase 2: collateral should be STETH");
        assertEq(newDeployment.getNetworkWrappedCollateral("mainnet"), WSTETH, "Phase 2: wrappedCollateral should be WSTETH");
    }

    /// @notice Multiple networks round-trip correctly with patterns
    function test_MultipleNetworksRoundTrip() public {
        // Phase 1: Create with multiple networks
        deployment.setNetworkData("mainnet", 1, STETH, WSTETH);
        deployment.setNetworkData("sepolia", 11155111, address(0x1111), address(0x2222));

        string memory json = deployment.toJson();

        // Phase 2: Load fresh - patterns discover ALL networks
        PatternKeysDeployment newDeployment = new PatternKeysDeployment();
        newDeployment.fromJsonNoSave(json);

        // Both networks should load correctly
        assertEq(newDeployment.getNetworkChainId("mainnet"), 1, "mainnet chainId");
        assertEq(newDeployment.getNetworkCollateral("mainnet"), STETH, "mainnet collateral");
        assertEq(newDeployment.getNetworkChainId("sepolia"), 11155111, "sepolia chainId");
        assertEq(newDeployment.getNetworkCollateral("sepolia"), address(0x1111), "sepolia collateral");
    }
}

/// @notice Test harness for explicit role registration
contract RolePatternDeployment is DeploymentJsonTesting {
    string public constant CONTRACTS_PEGGED = "contracts.pegged";
    
    constructor() {
        // Register the contract and its explicit roles
        addProxy(CONTRACTS_PEGGED);
        string[] memory roles = new string[](3);
        roles[0] = "MINTER_ROLE";
        roles[1] = "BURNER_ROLE";
        roles[2] = "ADMIN_ROLE";
        addRoles(CONTRACTS_PEGGED, roles);
    }

    function setRole(string memory roleName, uint256 value) public {
        _setRole(CONTRACTS_PEGGED, roleName, value);
    }

    function setGrantee(string memory granteeKey, string memory roleName) public {
        _setGrantee(granteeKey, CONTRACTS_PEGGED, roleName);
    }

    function getRoleValue(string memory roleName) public view returns (uint256) {
        return _getRoleValue(CONTRACTS_PEGGED, roleName);
    }

    function fromJsonNoSave(string memory json) public {
        _fromJsonNoSave(json);
    }
}

/// @notice Tests for addRoles explicit registration
contract DeploymentJsonRolePatternTest is Test {
    RolePatternDeployment deployment;

    function setUp() public {
        deployment = new RolePatternDeployment();
    }

    /// @notice Roles registered via addRolesFor write to JSON correctly
    function test_RolePatternsWriteToJson() public {
        deployment.setRole("MINTER_ROLE", 1);
        deployment.setRole("BURNER_ROLE", 2);

        string memory json = deployment.toJson();

        assertTrue(vm.keyExistsJson(json, "$.contracts.pegged.roles.MINTER_ROLE.value"), "MINTER_ROLE should exist");
        assertEq(vm.parseJsonUint(json, "$.contracts.pegged.roles.MINTER_ROLE.value"), 1, "MINTER_ROLE value");
        assertEq(vm.parseJsonUint(json, "$.contracts.pegged.roles.BURNER_ROLE.value"), 2, "BURNER_ROLE value");
    }

    /// @notice Roles round-trip correctly with addRolesFor patterns
    function test_RolePatternsRoundTrip() public {
        // Phase 1: Create roles
        deployment.setRole("MINTER_ROLE", 1);
        deployment.setRole("BURNER_ROLE", 2);
        deployment.setRole("ADMIN_ROLE", 4);

        string memory json = deployment.toJson();

        // Phase 2: Load into fresh deployment
        RolePatternDeployment newDeployment = new RolePatternDeployment();
        newDeployment.fromJsonNoSave(json);

        // Roles should be discovered and loaded via patterns
        assertEq(newDeployment.getRoleValue("MINTER_ROLE"), 1, "MINTER_ROLE after round-trip");
        assertEq(newDeployment.getRoleValue("BURNER_ROLE"), 2, "BURNER_ROLE after round-trip");
        assertEq(newDeployment.getRoleValue("ADMIN_ROLE"), 4, "ADMIN_ROLE after round-trip");
    }

    /// @notice Unregistered roles are rejected
    /// @dev This validates that explicit role registration provides validation
    function test_RevertWhen_UnregisteredRoleUsed() public {
        // UNKNOWN_ROLE was not in the addRoles array, so this should revert
        vm.expectRevert(abi.encodeWithSelector(DeploymentKeys.KeyNotRegistered.selector, "contracts.pegged.roles.UNKNOWN_ROLE.value"));
        deployment.setRole("UNKNOWN_ROLE", 99);
    }
}
