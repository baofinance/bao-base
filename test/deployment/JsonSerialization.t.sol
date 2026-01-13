// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {JsonSerializer} from "@bao-script/deployment/JsonSerializer.sol";
import {JsonParser} from "@bao-script/deployment/JsonParser.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";

/// @dev Wrapper to test library reverts (vm.expectRevert requires external call)
contract JsonParserWrapper {
    function parseStateJson(string memory json) external view returns (DeploymentTypes.State memory) {
        return JsonParser.parseStateJson(json);
    }
}

contract JsonSerializerTest is Test {
    JsonParserWrapper wrapper;

    function setUp() public {
        wrapper = new JsonParserWrapper();
    }
    function test_renderState_emptyState() public view {
        DeploymentTypes.State memory state;
        state.network = "mainnet";
        state.saltPrefix = "test_v1";
        state.baoFactory = address(0xD696E56b3A054734d4C6DCBD32E11a278b0EC458);

        string memory json = JsonSerializer.renderState(state);

        // Should contain expected fields
        assertTrue(bytes(json).length > 0, "non-empty json");
        assertContains(json, '"schemaVersion":1');
        assertContains(json, '"saltPrefix":"test_v1"');
        assertContains(json, '"network":"mainnet"');
        assertContains(json, '"baoFactory":"0xd696e56b3a054734d4c6dcbd32e11a278b0ec458"');
    }

    function test_renderState_withImplementations() public {
        DeploymentTypes.State memory state;
        state.network = "mainnet";
        state.saltPrefix = "test_v1";
        state.baoFactory = address(0xD696E56b3A054734d4C6DCBD32E11a278b0EC458);

        state.implementations = new DeploymentTypes.ImplementationRecord[](1);
        state.implementations[0] = DeploymentTypes.ImplementationRecord({
            proxy: "ETH::minter",
            contractSource: "@project/Minter.sol",
            contractType: "Minter_v1",
            implementation: makeAddr("impl1"),
            deploymentTime: uint64(1704067200) // 2024-01-01T00:00:00Z
        });

        string memory json = JsonSerializer.renderState(state);

        assertContains(json, '"proxy":"ETH::minter"');
        assertContains(json, '"contractSource":"@project/Minter.sol"');
        assertContains(json, '"contractType":"Minter_v1"');
        assertContains(json, '"deploymentTime":"2024-01-01T00:00:00Z"');
    }

    function test_renderState_withProxies() public {
        DeploymentTypes.State memory state;
        state.network = "mainnet";
        state.saltPrefix = "test_v1";
        state.baoFactory = address(0xD696E56b3A054734d4C6DCBD32E11a278b0EC458);

        state.proxies = new DeploymentTypes.ProxyRecord[](1);
        state.proxies[0] = DeploymentTypes.ProxyRecord({
            id: "ETH::minter",
            proxy: makeAddr("proxy1"),
            implementation: makeAddr("impl1"),
            salt: "test_v1",
            deploymentTime: uint64(1704067200)
        });

        string memory json = JsonSerializer.renderState(state);

        assertContains(json, '"ETH::minter"');
        // Salt is combined: saltPrefix + "::" + id
        assertContains(json, '"salt":"test_v1::ETH::minter"');
    }

    // ========== JsonParser Tests ==========

    function test_parseStateJson_emptyString() public view {
        DeploymentTypes.State memory state = JsonParser.parseStateJson("");

        assertEq(state.implementations.length, 0, "no implementations");
        assertEq(state.proxies.length, 0, "no proxies");
    }

    function test_parseStateJson_basicState() public view {
        string
            memory json = '{"schemaVersion":1,"version":"v1","saltPrefix":"test_v1","network":"mainnet","chainId":1,"baoFactory":"0xD696E56b3A054734d4C6DCBD32E11a278b0EC458","lastUpdated":"2024-01-01T00:00:00Z","implementations":{},"proxies":{}}';

        DeploymentTypes.State memory state = JsonParser.parseStateJson(json);

        assertEq(state.network, "mainnet", "network parsed");
        assertEq(state.saltPrefix, "test_v1", "saltPrefix parsed");
        assertEq(state.baoFactory, 0xD696E56b3A054734d4C6DCBD32E11a278b0EC458, "baoFactory parsed");
    }

    function test_parseStateJson_revertsSchemaMismatch() public {
        string
            memory json = '{"schemaVersion":99,"saltPrefix":"test_v1","network":"mainnet","baoFactory":"0xD696E56b3A054734d4C6DCBD32E11a278b0EC458"}';

        vm.expectRevert(abi.encodeWithSelector(JsonParser.SchemaMismatch.selector, 1, 99));
        wrapper.parseStateJson(json);
    }

    function test_parseStateJson_revertsMissingSchema() public {
        string
            memory json = '{"saltPrefix":"test_v1","network":"mainnet","baoFactory":"0xD696E56b3A054734d4C6DCBD32E11a278b0EC458"}';

        vm.expectRevert(abi.encodeWithSelector(JsonParser.SchemaMismatch.selector, 1, 0));
        wrapper.parseStateJson(json);
    }

    function test_parseStateJson_revertsMissingNetwork() public {
        string
            memory json = '{"schemaVersion":1,"saltPrefix":"test_v1","network":"","baoFactory":"0xD696E56b3A054734d4C6DCBD32E11a278b0EC458"}';

        vm.expectRevert(abi.encodeWithSelector(JsonParser.MissingRequiredField.selector, "network"));
        wrapper.parseStateJson(json);
    }

    function test_parseStateJson_revertsMissingSaltPrefix() public {
        string
            memory json = '{"schemaVersion":1,"saltPrefix":"","network":"mainnet","baoFactory":"0xD696E56b3A054734d4C6DCBD32E11a278b0EC458"}';

        vm.expectRevert(abi.encodeWithSelector(JsonParser.MissingRequiredField.selector, "saltPrefix"));
        wrapper.parseStateJson(json);
    }

    // ========== Round-trip Tests ==========

    function test_serializeParseRoundTrip() public {
        // Create state with data
        DeploymentTypes.State memory original;
        original.network = "mainnet";
        original.saltPrefix = "roundtrip_test";
        original.baoFactory = address(0xD696E56b3A054734d4C6DCBD32E11a278b0EC458);

        original.implementations = new DeploymentTypes.ImplementationRecord[](1);
        original.implementations[0] = DeploymentTypes.ImplementationRecord({
            proxy: "ETH::minter",
            contractSource: "@project/Minter.sol",
            contractType: "Minter_v1",
            implementation: makeAddr("impl1"),
            deploymentTime: uint64(1704067200)
        });

        original.proxies = new DeploymentTypes.ProxyRecord[](1);
        original.proxies[0] = DeploymentTypes.ProxyRecord({
            id: "ETH::minter",
            proxy: makeAddr("proxy1"),
            implementation: makeAddr("impl1"),
            salt: "roundtrip_test",
            deploymentTime: uint64(1704067200)
        });

        // Serialize
        string memory json = JsonSerializer.renderState(original);

        // Parse
        DeploymentTypes.State memory parsed = JsonParser.parseStateJson(json);

        // Verify
        assertEq(parsed.network, original.network, "network preserved");
        assertEq(parsed.saltPrefix, original.saltPrefix, "saltPrefix preserved");
        assertEq(parsed.baoFactory, original.baoFactory, "baoFactory preserved");
        assertEq(parsed.implementations.length, 1, "one implementation");
        assertEq(parsed.implementations[0].proxy, "ETH::minter", "impl proxy preserved");
        assertEq(parsed.implementations[0].contractType, "Minter_v1", "impl type preserved");
        assertEq(parsed.implementations[0].deploymentTime, 1704067200, "impl time preserved");
        assertEq(parsed.proxies.length, 1, "one proxy");
        assertEq(parsed.proxies[0].id, "ETH::minter", "proxy id preserved");
        // Salt is combined during serialization: saltPrefix::id
        assertEq(parsed.proxies[0].salt, "roundtrip_test::ETH::minter", "proxy salt preserved");
    }

    // ========== Timestamp Formatting Tests ==========

    function test_timestampFormatting_knownValue() public view {
        DeploymentTypes.State memory state;
        state.network = "test";
        state.saltPrefix = "ts";
        state.baoFactory = address(1);

        state.implementations = new DeploymentTypes.ImplementationRecord[](1);
        state.implementations[0] = DeploymentTypes.ImplementationRecord({
            proxy: "test",
            contractSource: "test.sol",
            contractType: "Test",
            implementation: address(2),
            deploymentTime: uint64(1704067200) // 2024-01-01T00:00:00Z
        });

        string memory json = JsonSerializer.renderState(state);

        assertContains(json, '"deploymentTime":"2024-01-01T00:00:00Z"');
    }

    // ========== Sorting Branch Coverage ==========

    function test_renderState_multipleImplementations_sorted() public view {
        // Tests the sorting swap branch: if (minIndex != i)
        DeploymentTypes.State memory state;
        state.network = "mainnet";
        state.saltPrefix = "test_v1";
        state.baoFactory = address(1);

        // Add in reverse alphabetical order to force sorting swaps
        state.implementations = new DeploymentTypes.ImplementationRecord[](3);
        state.implementations[0] = DeploymentTypes.ImplementationRecord({
            proxy: "ZZZ::last",
            contractSource: "test.sol",
            contractType: "Test",
            implementation: address(3),
            deploymentTime: uint64(1704067200)
        });
        state.implementations[1] = DeploymentTypes.ImplementationRecord({
            proxy: "MMM::middle",
            contractSource: "test.sol",
            contractType: "Test",
            implementation: address(2),
            deploymentTime: uint64(1704067200)
        });
        state.implementations[2] = DeploymentTypes.ImplementationRecord({
            proxy: "AAA::first",
            contractSource: "test.sol",
            contractType: "Test",
            implementation: address(4),
            deploymentTime: uint64(1704067200)
        });

        string memory json = JsonSerializer.renderState(state);

        // All should be present in sorted order
        assertContains(json, '"proxy":"AAA::first"');
        assertContains(json, '"proxy":"MMM::middle"');
        assertContains(json, '"proxy":"ZZZ::last"');
    }

    function test_renderState_multipleProxies_sorted() public view {
        // Tests the proxy sorting swap branch
        DeploymentTypes.State memory state;
        state.network = "mainnet";
        state.saltPrefix = "test_v1";
        state.baoFactory = address(1);

        // Add in reverse alphabetical order
        state.proxies = new DeploymentTypes.ProxyRecord[](3);
        state.proxies[0] = DeploymentTypes.ProxyRecord({
            id: "ZZZ::last",
            proxy: address(3),
            implementation: address(10),
            salt: "s1",
            deploymentTime: uint64(1704067200)
        });
        state.proxies[1] = DeploymentTypes.ProxyRecord({
            id: "MMM::middle",
            proxy: address(2),
            implementation: address(11),
            salt: "s2",
            deploymentTime: uint64(1704067200)
        });
        state.proxies[2] = DeploymentTypes.ProxyRecord({
            id: "AAA::first",
            proxy: address(4),
            implementation: address(12),
            salt: "s3",
            deploymentTime: uint64(1704067200)
        });

        string memory json = JsonSerializer.renderState(state);

        // All should be present
        assertContains(json, '"AAA::first"');
        assertContains(json, '"MMM::middle"');
        assertContains(json, '"ZZZ::last"');
    }

    // ========== Quote Escaping Branch Coverage ==========

    function test_renderState_escapesQuotesInStrings() public view {
        // Tests the escape branch in _quote: if (char == '"' || char == '\\')
        DeploymentTypes.State memory state;
        state.network = 'main"net';
        state.saltPrefix = "test\\v1";
        state.baoFactory = address(1);

        string memory json = JsonSerializer.renderState(state);

        // Quotes and backslashes should be escaped
        assertContains(json, '"network":"main\\"net"');
        assertContains(json, '"saltPrefix":"test\\\\v1"');
    }

    // ========== Parser: Invalid Timestamp Branch Coverage ==========

    function test_parseStateJson_invalidTimestampFormat() public {
        // Tests _parseTimestamp with wrong format (not 20 chars or wrong separators)
        string
            memory json = '{"schemaVersion":1,"saltPrefix":"test_v1","network":"mainnet","baoFactory":"0xD696E56b3A054734d4C6DCBD32E11a278b0EC458","implementations":{"0x0000000000000000000000000000000000000001":{"proxy":"test","contractSource":"test.sol","contractType":"Test","deploymentTime":"invalid-time"}},"proxies":{}}';

        vm.expectRevert(abi.encodeWithSelector(JsonParser.InvalidTimestamp.selector, "invalid-time"));
        wrapper.parseStateJson(json);
    }

    function test_parseStateJson_invalidTimestampDigits() public {
        // Tests _parseDigits with non-numeric characters
        string
            memory json = '{"schemaVersion":1,"saltPrefix":"test_v1","network":"mainnet","baoFactory":"0xD696E56b3A054734d4C6DCBD32E11a278b0EC458","implementations":{"0x0000000000000000000000000000000000000001":{"proxy":"test","contractSource":"test.sol","contractType":"Test","deploymentTime":"20XX-01-01T00:00:00Z"}},"proxies":{}}';

        vm.expectRevert(abi.encodeWithSelector(JsonParser.InvalidTimestamp.selector, "20XX-01-01T00:00:00Z"));
        wrapper.parseStateJson(json);
    }

    function test_parseStateJson_emptyTimestamp() public view {
        // Tests _parseTimestamp with empty string -> returns 0
        string
            memory json = '{"schemaVersion":1,"saltPrefix":"test_v1","network":"mainnet","baoFactory":"0xD696E56b3A054734d4C6DCBD32E11a278b0EC458","implementations":{"0x0000000000000000000000000000000000000001":{"proxy":"test","contractSource":"test.sol","contractType":"Test","deploymentTime":""}},"proxies":{}}';

        DeploymentTypes.State memory state = JsonParser.parseStateJson(json);

        assertEq(state.implementations[0].deploymentTime, 0, "empty timestamp returns 0");
    }

    function test_parseStateJson_noImplementationsKey() public view {
        // Tests parseImplementations when .implementations key doesn't exist
        string
            memory json = '{"schemaVersion":1,"saltPrefix":"test_v1","network":"mainnet","baoFactory":"0xD696E56b3A054734d4C6DCBD32E11a278b0EC458","proxies":{}}';

        DeploymentTypes.State memory state = JsonParser.parseStateJson(json);

        assertEq(state.implementations.length, 0, "no implementations when key missing");
    }

    function test_parseStateJson_noProxiesKey() public view {
        // Tests parseProxies when .proxies key doesn't exist
        string
            memory json = '{"schemaVersion":1,"saltPrefix":"test_v1","network":"mainnet","baoFactory":"0xD696E56b3A054734d4C6DCBD32E11a278b0EC458","implementations":{}}';

        DeploymentTypes.State memory state = JsonParser.parseStateJson(json);

        assertEq(state.proxies.length, 0, "no proxies when key missing");
    }

    // ========== Helper Functions ==========

    function assertContains(string memory haystack, string memory needle) internal pure {
        bytes memory haystackBytes = bytes(haystack);
        bytes memory needleBytes = bytes(needle);

        if (needleBytes.length > haystackBytes.length) {
            revert(string.concat("String '", haystack, "' does not contain '", needle, "'"));
        }

        bool found = false;
        for (uint256 i = 0; i <= haystackBytes.length - needleBytes.length; i++) {
            bool match_ = true;
            for (uint256 j = 0; j < needleBytes.length; j++) {
                if (haystackBytes[i + j] != needleBytes[j]) {
                    match_ = false;
                    break;
                }
            }
            if (match_) {
                found = true;
                break;
            }
        }

        if (!found) {
            revert(string.concat("String does not contain expected substring: ", needle));
        }
    }
}
