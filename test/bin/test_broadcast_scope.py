"""Unit tests for the RULE in bin/broadcast-scope.py (violations).

The rule: a config object created between `vm.startBroadcast()` and `vm.stopBroadcast()` — or on the
line following a single-shot `vm.broadcast()` — is deployed as a real transaction, and is rejected.
The same creation outside that region is correct and must pass.

Two properties decide whether the check is worth having, and both fail silently when broken:

  - It must not fire on code that is not live: a commented-out creation, or a config name appearing
    inside a string literal, would each be a false alarm that trains people to ignore the check.
  - It must not miss a creation that IS in scope. The single-shot `vm.broadcast()` form is the easy
    one to get wrong, because its scope is one call, not a region.

So both directions are pinned here on synthetic sources rather than checked by eye.
"""

import importlib.util
import pathlib


def load_module():
    module_path = pathlib.Path(__file__).resolve().parents[2] / "bin" / "broadcast-scope.py"
    spec = importlib.util.spec_from_file_location("broadcast_scope", module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


mod = load_module()


def lines_flagged(source):
    return [lineno for lineno, _ in mod.violations(source)]


# ── creations inside a broadcast region are rejected ────────────────────────────────────────────


def test_factory_helper_inside_broadcast_is_flagged():
    source = "\n".join(
        [
            "vm.startBroadcast();",
            "(, markets) = createBTCMintersConfig();",
            "vm.stopBroadcast();",
        ]
    )
    assert lines_flagged(source) == [2]


def test_new_config_inside_broadcast_is_flagged():
    source = "\n".join(
        [
            "vm.startBroadcast();",
            "peg = new ConfigPeg_ETH();",
            "vm.stopBroadcast();",
        ]
    )
    assert lines_flagged(source) == [2]


def test_every_creation_in_the_region_is_reported():
    source = "\n".join(
        [
            "vm.startBroadcast();",
            "(, btc) = createBTCMintersConfig();",
            "_doOneMinter(state, btc);",
            "(, eth) = createETHMintersConfig();",
            "vm.stopBroadcast();",
        ]
    )
    assert lines_flagged(source) == [2, 4]


def test_violation_reports_the_original_line_text():
    source = "vm.startBroadcast();\n    (, markets) = createETHMintersConfig();\n"
    assert mod.violations(source) == [(2, "    (, markets) = createETHMintersConfig();")]


# ── creations outside a broadcast region are accepted ───────────────────────────────────────────


def test_creation_before_the_broadcast_is_accepted():
    source = "\n".join(
        [
            "(, markets) = createBTCMintersConfig();",
            "vm.startBroadcast();",
            "_doOneMinter(state, markets);",
            "vm.stopBroadcast();",
        ]
    )
    assert lines_flagged(source) == []


def test_creation_after_the_broadcast_is_accepted():
    source = "\n".join(
        [
            "vm.startBroadcast();",
            "_doOneMinter(state, markets);",
            "vm.stopBroadcast();",
            "(, markets) = createBTCMintersConfig();",
        ]
    )
    assert lines_flagged(source) == []


def test_source_with_no_broadcast_is_accepted():
    source = "(, markets) = createBTCMintersConfig();\npeg = new ConfigPeg_ETH();\n"
    assert lines_flagged(source) == []


def test_second_region_is_tracked_independently():
    source = "\n".join(
        [
            "vm.startBroadcast();",
            "vm.stopBroadcast();",
            "(, markets) = createBTCMintersConfig();",
            "vm.startBroadcast();",
            "peg = new ConfigPeg_ETH();",
            "vm.stopBroadcast();",
        ]
    )
    assert lines_flagged(source) == [5]


# ── single-shot vm.broadcast() puts only the next call in scope ─────────────────────────────────


def test_creation_after_single_shot_broadcast_is_flagged():
    source = "vm.broadcast();\n(, markets) = createBTCMintersConfig();\n"
    assert lines_flagged(source) == [2]


def test_single_shot_broadcast_scope_ends_after_one_call():
    source = "\n".join(
        [
            "vm.broadcast();",
            "impl = address(new Thing());",
            "(, markets) = createBTCMintersConfig();",
        ]
    )
    assert lines_flagged(source) == []


def test_blank_and_comment_lines_do_not_consume_the_single_shot_scope():
    source = "\n".join(
        [
            "vm.broadcast();",
            "",
            "// the creation is still the next call",
            "(, markets) = createBTCMintersConfig();",
        ]
    )
    assert lines_flagged(source) == [4]


# ── code that is not live must not fire ─────────────────────────────────────────────────────────


def test_line_commented_creation_is_not_flagged():
    source = "\n".join(
        [
            "vm.startBroadcast();",
            "// (, markets) = createBTCMintersConfig();",
            "vm.stopBroadcast();",
        ]
    )
    assert lines_flagged(source) == []


def test_trailing_comment_creation_is_not_flagged():
    source = "vm.startBroadcast();\n_doOneMinter(state); // was createBTCMintersConfig();\n"
    assert lines_flagged(source) == []


def test_block_commented_creation_is_not_flagged():
    source = "\n".join(
        [
            "vm.startBroadcast();",
            "/*",
            "(, markets) = createBTCMintersConfig();",
            "*/",
            "vm.stopBroadcast();",
        ]
    )
    assert lines_flagged(source) == []


def test_creation_after_a_block_comment_closes_is_flagged():
    source = "\n".join(
        [
            "vm.startBroadcast();",
            "/* disabled */ (, markets) = createBTCMintersConfig();",
            "vm.stopBroadcast();",
        ]
    )
    assert lines_flagged(source) == [2]


def test_config_name_inside_a_string_literal_is_not_flagged():
    source = 'vm.startBroadcast();\nconsole.log("call createBTCMintersConfig() first");\n'
    assert lines_flagged(source) == []


def test_double_slash_inside_a_string_does_not_comment_out_the_rest_of_the_line():
    source = "\n".join(
        [
            "vm.startBroadcast();",
            'log("https://bao.finance"); (, markets) = createBTCMintersConfig();',
            "vm.stopBroadcast();",
        ]
    )
    assert lines_flagged(source) == [2]
