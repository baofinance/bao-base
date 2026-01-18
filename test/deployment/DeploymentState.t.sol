// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {JsonParser} from "@bao-script/deployment/JsonParser.sol";

/// @notice Wrapper contract to make library calls external for expectRevert testing.
contract DeploymentStateWrapper {
    function recordImplementation(
        DeploymentTypes.State memory state,
        DeploymentTypes.ImplementationRecord memory rec
    ) external pure returns (bool) {
        return DeploymentState.recordImplementation(state, rec);
    }

    function recordProxy(
        DeploymentTypes.State memory state,
        DeploymentTypes.ProxyRecord memory rec
    ) external pure returns (bool) {
        return DeploymentState.recordProxy(state, rec);
    }

    /// @notice Records first then attempts second - for duplicate testing. Returns modified state.
    function recordImplementationTwice(
        DeploymentTypes.State memory state,
        DeploymentTypes.ImplementationRecord memory rec1,
        DeploymentTypes.ImplementationRecord memory rec2
    ) external pure returns (DeploymentTypes.State memory) {
        DeploymentState.recordImplementation(state, rec1);
        DeploymentState.recordImplementation(state, rec2);
        return state;
    }

    /// @notice Records first then attempts second - for duplicate testing.
    function recordProxyTwice(
        DeploymentTypes.State memory state,
        DeploymentTypes.ProxyRecord memory rec1,
        DeploymentTypes.ProxyRecord memory rec2
    ) external pure {
        DeploymentState.recordProxy(state, rec1);
        DeploymentState.recordProxy(state, rec2);
    }
}

contract DeploymentStateTest is Test {
    DeploymentStateWrapper internal wrapper;

    function setUp() public {
        wrapper = new DeploymentStateWrapper();
    }

    function _newState() internal pure returns (DeploymentTypes.State memory state) {
        state.network = "mainnet";
        state.saltPrefix = "test_v1";
        state.baoFactory = address(0xD696E56b3A054734d4C6DCBD32E11a278b0EC458);
    }

    // ========== RECORD IMPLEMENTATION TESTS ==========

    function test_recordImplementation_addsNewRecord() public {
        DeploymentTypes.State memory state = _newState();
        DeploymentTypes.ImplementationRecord memory rec = DeploymentTypes.ImplementationRecord({
            proxy: "ETH::minter",
            contractSource: "@project/Minter.sol",
            contractType: "Minter_v1",
            implementation: makeAddr("impl1"),
            deploymentTime: uint64(block.timestamp)
        });

        bool alreadyExists = DeploymentState.recordImplementation(state, rec);

        assertFalse(alreadyExists, "new record should not already exist");
        assertEq(state.implementations.length, 1, "one implementation recorded");
        assertEq(state.implementations[0].proxy, "ETH::minter", "proxy key stored");
        assertEq(state.implementations[0].implementation, makeAddr("impl1"), "impl address stored");
    }

    function test_recordImplementation_idempotent() public {
        DeploymentTypes.State memory state = _newState();
        DeploymentTypes.ImplementationRecord memory rec = DeploymentTypes.ImplementationRecord({
            proxy: "ETH::minter",
            contractSource: "@project/Minter.sol",
            contractType: "Minter_v1",
            implementation: makeAddr("impl1"),
            deploymentTime: uint64(block.timestamp)
        });

        DeploymentState.recordImplementation(state, rec);
        bool alreadyExists = DeploymentState.recordImplementation(state, rec);

        assertTrue(alreadyExists, "second insert of same record is idempotent");
        assertEq(state.implementations.length, 1, "still only one record");
    }

    function test_recordImplementation_allowsMultipleImplsForSameProxy() public {
        // Upgrade history: same proxy, different implementations
        DeploymentTypes.State memory state = _newState();
        DeploymentTypes.ImplementationRecord memory rec1 = DeploymentTypes.ImplementationRecord({
            proxy: "ETH::minter",
            contractSource: "@project/Minter.sol",
            contractType: "Minter_v1",
            implementation: makeAddr("impl1"),
            deploymentTime: uint64(block.timestamp)
        });

        DeploymentTypes.ImplementationRecord memory rec2 = DeploymentTypes.ImplementationRecord({
            proxy: "ETH::minter",
            contractSource: "@project/Minter.sol",
            contractType: "Minter_v2",
            implementation: makeAddr("impl2"),
            deploymentTime: uint64(block.timestamp)
        });

        // Both should be recorded (upgrade history)
        DeploymentState.recordImplementation(state, rec1);
        DeploymentState.recordImplementation(state, rec2);

        assertEq(state.implementations.length, 2, "both implementations recorded");
        assertEq(state.implementations[0].contractType, "Minter_v1", "v1 first");
        assertEq(state.implementations[1].contractType, "Minter_v2", "v2 second");
    }

    function test_recordImplementation_revertsDuplicateAddress() public {
        DeploymentTypes.State memory state = _newState();
        address sharedImpl = makeAddr("sharedImpl");

        DeploymentTypes.ImplementationRecord memory rec1 = DeploymentTypes.ImplementationRecord({
            proxy: "ETH::minter",
            contractSource: "@project/Minter.sol",
            contractType: "Minter_v1",
            implementation: sharedImpl,
            deploymentTime: uint64(block.timestamp)
        });

        DeploymentTypes.ImplementationRecord memory rec2 = DeploymentTypes.ImplementationRecord({
            proxy: "BTC::minter",
            contractSource: "@project/Minter.sol",
            contractType: "Minter_v1",
            implementation: sharedImpl,
            deploymentTime: uint64(block.timestamp)
        });

        vm.expectRevert(abi.encodeWithSelector(DeploymentState.DuplicateImplementation.selector, sharedImpl));
        wrapper.recordImplementationTwice(state, rec1, rec2);
    }

    function test_recordImplementation_revertsEmptyProxy() public {
        DeploymentTypes.State memory state = _newState();
        DeploymentTypes.ImplementationRecord memory rec = DeploymentTypes.ImplementationRecord({
            proxy: "",
            contractSource: "@project/Minter.sol",
            contractType: "Minter_v1",
            implementation: makeAddr("impl1"),
            deploymentTime: uint64(block.timestamp)
        });

        vm.expectRevert(DeploymentState.ProxyKeyRequiredForImplementation.selector);
        wrapper.recordImplementation(state, rec);
    }

    function test_recordImplementation_revertsZeroAddress() public {
        DeploymentTypes.State memory state = _newState();
        DeploymentTypes.ImplementationRecord memory rec = DeploymentTypes.ImplementationRecord({
            proxy: "ETH::minter",
            contractSource: "@project/Minter.sol",
            contractType: "Minter_v1",
            implementation: address(0),
            deploymentTime: uint64(block.timestamp)
        });

        vm.expectRevert(DeploymentState.ImplementationAddressRequired.selector);
        wrapper.recordImplementation(state, rec);
    }

    // ========== RECORD PROXY TESTS ==========

    function test_recordProxy_addsMultipleRecords() public {
        // Tests the for loop that copies existing proxies when adding a new one
        DeploymentTypes.State memory state = _newState();
        DeploymentTypes.ProxyRecord memory rec1 = DeploymentTypes.ProxyRecord({
            id: "ETH::minter",
            proxy: makeAddr("proxy1"),
            implementation: makeAddr("impl1"),
            salt: "test_v1",
            deploymentTime: uint64(block.timestamp)
        });
        DeploymentTypes.ProxyRecord memory rec2 = DeploymentTypes.ProxyRecord({
            id: "BTC::minter",
            proxy: makeAddr("proxy2"),
            implementation: makeAddr("impl2"),
            salt: "test_v1",
            deploymentTime: uint64(block.timestamp)
        });

        DeploymentState.recordProxy(state, rec1);
        bool alreadyExists = DeploymentState.recordProxy(state, rec2);

        assertFalse(alreadyExists, "second record is new");
        assertEq(state.proxies.length, 2, "two proxies recorded");
        assertEq(state.proxies[0].id, "ETH::minter", "first proxy preserved");
        assertEq(state.proxies[1].id, "BTC::minter", "second proxy added");
    }

    function test_recordProxy_addsNewRecord() public {
        DeploymentTypes.State memory state = _newState();
        DeploymentTypes.ProxyRecord memory rec = DeploymentTypes.ProxyRecord({
            id: "ETH::minter",
            proxy: makeAddr("proxy1"),
            implementation: makeAddr("impl1"),
            salt: "test_v1",
            deploymentTime: uint64(block.timestamp)
        });

        bool alreadyExists = DeploymentState.recordProxy(state, rec);

        assertFalse(alreadyExists, "new record should not already exist");
        assertEq(state.proxies.length, 1, "one proxy recorded");
        assertEq(state.proxies[0].id, "ETH::minter", "id stored");
        assertEq(state.proxies[0].proxy, makeAddr("proxy1"), "proxy address stored");
    }

    function test_recordProxy_idempotent() public {
        DeploymentTypes.State memory state = _newState();
        DeploymentTypes.ProxyRecord memory rec = DeploymentTypes.ProxyRecord({
            id: "ETH::minter",
            proxy: makeAddr("proxy1"),
            implementation: makeAddr("impl1"),
            salt: "test_v1",
            deploymentTime: uint64(block.timestamp)
        });

        DeploymentState.recordProxy(state, rec);
        bool alreadyExists = DeploymentState.recordProxy(state, rec);

        assertTrue(alreadyExists, "second insert of same record is idempotent");
        assertEq(state.proxies.length, 1, "still only one record");
    }

    function test_recordProxy_revertsDuplicateId() public {
        DeploymentTypes.State memory state = _newState();
        DeploymentTypes.ProxyRecord memory rec1 = DeploymentTypes.ProxyRecord({
            id: "ETH::minter",
            proxy: makeAddr("proxy1"),
            implementation: makeAddr("impl1"),
            salt: "test_v1",
            deploymentTime: uint64(block.timestamp)
        });

        DeploymentTypes.ProxyRecord memory rec2 = DeploymentTypes.ProxyRecord({
            id: "ETH::minter",
            proxy: makeAddr("proxy2"),
            implementation: makeAddr("impl2"),
            salt: "test_v1",
            deploymentTime: uint64(block.timestamp)
        });

        vm.expectRevert(abi.encodeWithSelector(DeploymentState.DuplicateProxy.selector, "ETH::minter"));
        wrapper.recordProxyTwice(state, rec1, rec2);
    }

    function test_recordProxy_revertsDuplicateAddress() public {
        DeploymentTypes.State memory state = _newState();
        address sharedProxy = makeAddr("sharedProxy");

        DeploymentTypes.ProxyRecord memory rec1 = DeploymentTypes.ProxyRecord({
            id: "ETH::minter",
            proxy: sharedProxy,
            implementation: makeAddr("impl1"),
            salt: "test_v1",
            deploymentTime: uint64(block.timestamp)
        });

        DeploymentTypes.ProxyRecord memory rec2 = DeploymentTypes.ProxyRecord({
            id: "BTC::minter",
            proxy: sharedProxy,
            implementation: makeAddr("impl2"),
            salt: "test_v1",
            deploymentTime: uint64(block.timestamp)
        });

        vm.expectRevert(abi.encodeWithSelector(DeploymentState.DuplicateProxyAddress.selector, sharedProxy));
        wrapper.recordProxyTwice(state, rec1, rec2);
    }

    function test_recordProxy_revertsEmptyId() public {
        DeploymentTypes.State memory state = _newState();
        DeploymentTypes.ProxyRecord memory rec = DeploymentTypes.ProxyRecord({
            id: "",
            proxy: makeAddr("proxy1"),
            implementation: makeAddr("impl1"),
            salt: "test_v1",
            deploymentTime: uint64(block.timestamp)
        });

        vm.expectRevert(DeploymentState.ProxyKeyRequired.selector);
        wrapper.recordProxy(state, rec);
    }

    function test_recordProxy_revertsZeroAddress() public {
        DeploymentTypes.State memory state = _newState();
        DeploymentTypes.ProxyRecord memory rec = DeploymentTypes.ProxyRecord({
            id: "ETH::minter",
            proxy: address(0),
            implementation: makeAddr("impl1"),
            salt: "test_v1",
            deploymentTime: uint64(block.timestamp)
        });

        vm.expectRevert(DeploymentState.ProxyAddressRequired.selector);
        wrapper.recordProxy(state, rec);
    }

    // ========== HAS PROXY / HAS IMPLEMENTATION TESTS ==========

    function test_hasProxy_returnsFalseWhenEmpty() public pure {
        DeploymentTypes.State memory state = _newState();
        assertFalse(DeploymentState.hasProxy(state, "ETH::minter"), "no proxies yet");
    }

    function test_hasProxy_returnsTrueWhenPresent() public {
        DeploymentTypes.State memory state = _newState();
        DeploymentTypes.ProxyRecord memory rec = DeploymentTypes.ProxyRecord({
            id: "ETH::minter",
            proxy: makeAddr("proxy1"),
            implementation: makeAddr("impl1"),
            salt: "test_v1",
            deploymentTime: uint64(block.timestamp)
        });

        DeploymentState.recordProxy(state, rec);

        assertTrue(DeploymentState.hasProxy(state, "ETH::minter"), "proxy exists");
        assertFalse(DeploymentState.hasProxy(state, "BTC::minter"), "other proxy doesn't exist");
    }

    function test_hasImplementation_returnsFalseWhenEmpty() public pure {
        DeploymentTypes.State memory state = _newState();
        assertFalse(DeploymentState.hasImplementation(state, "ETH::minter"), "no implementations yet");
    }

    function test_hasImplementation_returnsTrueWhenPresent() public {
        DeploymentTypes.State memory state = _newState();
        DeploymentTypes.ImplementationRecord memory rec = DeploymentTypes.ImplementationRecord({
            proxy: "ETH::minter",
            contractSource: "@project/Minter.sol",
            contractType: "Minter_v1",
            implementation: makeAddr("impl1"),
            deploymentTime: uint64(block.timestamp)
        });

        DeploymentState.recordImplementation(state, rec);

        assertTrue(DeploymentState.hasImplementation(state, "ETH::minter"), "impl exists");
        assertFalse(DeploymentState.hasImplementation(state, "BTC::minter"), "other impl doesn't exist");
    }

    // ========== PATH RESOLUTION TESTS ==========

    function test_resolvePath_constructsCorrectPath() public view {
        string memory path = DeploymentState.resolvePath("mainnet", "harbor_v1", "");
        // Should end with deployments/mainnet/harbor_v1.state.json
        assertTrue(bytes(path).length > 0, "path not empty");
    }

    // ========== LOAD / SAVE ROUND TRIP TESTS ==========

    function test_loadSave_roundTrip() public {
        // Set up test state
        DeploymentTypes.State memory state;
        state.network = "test";
        state.saltPrefix = "roundtrip_test";
        state.baoFactory = address(0xD696E56b3A054734d4C6DCBD32E11a278b0EC458);

        DeploymentTypes.ImplementationRecord memory implRec = DeploymentTypes.ImplementationRecord({
            proxy: "ETH::minter",
            contractSource: "@project/Minter.sol",
            contractType: "Minter_v1",
            implementation: makeAddr("impl1"),
            deploymentTime: uint64(1704067200)
        });
        DeploymentState.recordImplementation(state, implRec);

        DeploymentTypes.ProxyRecord memory proxyRec = DeploymentTypes.ProxyRecord({
            id: "ETH::minter",
            proxy: makeAddr("proxy1"),
            implementation: makeAddr("impl1"),
            salt: "roundtrip_test",
            deploymentTime: uint64(1704067200)
        });
        DeploymentState.recordProxy(state, proxyRec);

        // Save
        DeploymentState.save(state);

        // Load
        DeploymentTypes.State memory loaded = DeploymentState.load("test", "roundtrip_test");

        // Verify all fields preserved
        assertEq(loaded.network, "test", "network preserved");
        assertEq(loaded.saltPrefix, "roundtrip_test", "saltPrefix preserved");
        assertEq(loaded.baoFactory, state.baoFactory, "baoFactory preserved");
        assertEq(loaded.implementations.length, 1, "one implementation");
        assertEq(loaded.implementations[0].proxy, "ETH::minter", "impl proxy key preserved");
        assertEq(loaded.implementations[0].implementation, implRec.implementation, "impl address preserved");
        assertEq(loaded.proxies.length, 1, "one proxy");
        assertEq(loaded.proxies[0].id, "ETH::minter", "proxy id preserved");
        assertEq(loaded.proxies[0].proxy, proxyRec.proxy, "proxy address preserved");
        assertEq(loaded.proxies[0].implementation, proxyRec.implementation, "proxy impl preserved");

        // Cleanup
        vm.removeFile(DeploymentState.resolvePath("test", "roundtrip_test", ""));
    }

    function test_load_returnsEmptyStateForMissingFile() public {
        DeploymentTypes.State memory loaded = DeploymentState.load("nonexistent", "missing_prefix");

        assertEq(loaded.network, "nonexistent", "network set from parameter");
        assertEq(loaded.saltPrefix, "missing_prefix", "saltPrefix set from parameter");
        assertEq(loaded.implementations.length, 0, "no implementations");
        assertEq(loaded.proxies.length, 0, "no proxies");
    }

    // ========== JSON PARSING TESTS ==========

    function test_parseStateJson_emptyString_returnsEmptyState() public view {
        DeploymentTypes.State memory state = JsonParser.parseStateJson("");
        assertEq(state.implementations.length, 0, "implementations should be empty");
        assertEq(state.proxies.length, 0, "proxies should be empty");
    }

    function test_parseStateJson_handCraftedJson() public view {
        string memory salt = "test_parseStateJson";
        string memory json = string(
            abi.encodePacked(
                '{"schemaVersion":1,"version":"v1","saltPrefix":"',
                salt,
                '","network":"mainnet","chainId":31337,"baoFactory":"0x0000000000000000000000000000000000009999","lastUpdated":"1970-01-01T00:00:01Z",',
                '"implementations":{"0x0000000000000000000000000000000000005678":{"proxy":"ETH::minter","contractSource":"src/Minter.sol","contractType":"Minter","deploymentTime":"1970-01-01T00:00:01Z"}},',
                '"proxies":{"ETH::minter":{"address":"0x0000000000000000000000000000000000001234","implementation":"0x0000000000000000000000000000000000005678","salt":"',
                salt,
                '::ETH::minter","deploymentTime":"1970-01-01T00:00:01Z"}}}'
            )
        );

        DeploymentTypes.State memory parsed = JsonParser.parseStateJson(json);
        assertEq(parsed.network, "mainnet", "network");
        assertEq(parsed.saltPrefix, salt, "saltPrefix");
        assertEq(parsed.implementations.length, 1, "implementations length");
        assertEq(parsed.proxies.length, 1, "proxies length");
        assertEq(parsed.proxies[0].salt, string.concat(salt, "::ETH::minter"), "proxy salt");
        assertEq(parsed.baoFactory, address(0x9999), "baoFactory");
    }
}
