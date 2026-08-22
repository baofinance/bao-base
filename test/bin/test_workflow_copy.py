"""Tests for bin/workflow_copy.py — the check `doctor` lists and the action runs on its own.

A consumer cannot point `uses:` at bao-base's workflow, so it holds a hand-copy. The copy may differ
in ONE way — where the action lives — and must match in every other, in both directions: a line it is
missing is an upstream fix that never arrived, and a line only it has is an addition upstream never
took.

conftest puts bin/ on sys.path, so this imports the module directly.
"""

import workflow_copy

# The action step as each side spells it: bao-base reaches its own action directly, a consumer
# reaches the same directory through the submodule.
_CANONICAL_ACTION = "      - uses: ./.github/actions/test-foundry"
_CONSUMER_ACTION = "      - uses: ./lib/bao-base/.github/actions/test-foundry"


def _workflow_pair(tmp_path, canonical_body, consumer_body, name="CI-test.yml"):
    """Build a consumer repo with bao-base vendored inside it, each holding a workflow, and return
    (repo_root, bao_base_root). A body of None means that side does not have the file at all."""
    repo_root = tmp_path / "host"
    bao_base_root = repo_root / "lib" / "bao-base"
    for root, body in ((repo_root, consumer_body), (bao_base_root, canonical_body)):
        if body is None:
            continue
        workflows = root / ".github" / "workflows"
        workflows.mkdir(parents=True, exist_ok=True)
        (workflows / name).write_text(body)
    bao_base_root.mkdir(parents=True, exist_ok=True)
    return repo_root, bao_base_root


def test_copy_matching_but_for_the_action_path_is_clean(tmp_path):
    # The one difference a copy is entitled to. Normalising it away is what makes every OTHER
    # difference meaningful, so this passing is the precondition for the rest of these tests.
    repo, bao_base = _workflow_pair(
        tmp_path,
        f"name: test\njobs:\n  build:\n    steps:\n{_CANONICAL_ACTION}\n",
        f"name: test\njobs:\n  build:\n    steps:\n{_CONSUMER_ACTION}\n",
    )
    assert workflow_copy.problems(repo, bao_base) == []


def test_copy_missing_an_upstream_line_is_reported(tmp_path):
    # The failure that actually happened: bao-base added GITHUB_TOKEN to fix a macOS foundry-install
    # rate limit, and neither consumer picked it up. Drift where the copy is STALE is the direction
    # that costs something, because the fix is already written and simply is not here.
    repo, bao_base = _workflow_pair(
        tmp_path,
        f"name: test\nenv:\n  GITHUB_TOKEN: secret\njobs:\n  build:\n    steps:\n{_CANONICAL_ACTION}\n",
        f"name: test\nenv:\njobs:\n  build:\n    steps:\n{_CONSUMER_ACTION}\n",
    )
    problems = workflow_copy.problems(repo, bao_base)
    assert len(problems) == 1
    assert "in bao-base and missing here" in problems[0]
    assert "GITHUB_TOKEN: secret" in problems[0]


def test_copy_with_an_extra_line_is_reported(tmp_path):
    # The other direction: a consumer-side addition upstream never took. It is not automatically
    # wrong, but it is undocumented drift, and the check's job is to make someone decide.
    repo, bao_base = _workflow_pair(
        tmp_path,
        f"name: test\njobs:\n  build:\n    steps:\n{_CANONICAL_ACTION}\n",
        f"name: test\njobs:\n  build:\n    steps:\n{_CONSUMER_ACTION}\n        with:\n          fetch-depth: 0\n",
    )
    problems = workflow_copy.problems(repo, bao_base)
    assert len(problems) == 1
    assert "here and not in bao-base" in problems[0]
    assert "fetch-depth: 0" in problems[0]


def test_both_directions_are_reported_at_once(tmp_path):
    # Real drift is rarely one-sided, and fixing one side then re-running to discover the other
    # wastes a round trip — the same reason the permission check reports every reason a rule fails.
    repo, bao_base = _workflow_pair(
        tmp_path,
        f"name: test\nenv:\n  GITHUB_TOKEN: secret\njobs:\n  build:\n    steps:\n{_CANONICAL_ACTION}\n",
        f"name: test\nenv:\n  OTHER_TOKEN: secret\njobs:\n  build:\n    steps:\n{_CONSUMER_ACTION}\n",
    )
    problems = workflow_copy.problems(repo, bao_base)
    assert len(problems) == 1
    assert "GITHUB_TOKEN: secret" in problems[0]
    assert "OTHER_TOKEN: secret" in problems[0]


def test_leading_comment_block_is_not_drift(tmp_path):
    # The copy's header is where it records that it IS a copy, so it exists on one side only and is
    # not a difference in what the workflow DOES. Comments further down are content and are compared.
    repo, bao_base = _workflow_pair(
        tmp_path,
        f"name: test\njobs:\n  build:\n    steps:\n{_CANONICAL_ACTION}\n",
        f"# this file is a copy of bao-base's\n# TODO: check it is up to date\n\n"
        f"name: test\njobs:\n  build:\n    steps:\n{_CONSUMER_ACTION}\n",
    )
    assert workflow_copy.problems(repo, bao_base) == []


def test_workflow_only_this_repo_has_is_not_compared(tmp_path):
    # A repo's own workflow is its own business — there is no original to have drifted from.
    repo, bao_base = _workflow_pair(tmp_path, None, "name: mine\njobs: {}\n")
    assert workflow_copy.problems(repo, bao_base) == []


def test_workflow_only_bao_base_has_is_not_demanded(tmp_path):
    # Opt-in by presence: adopting one of bao-base's workflows is a deliberate act, so carrying one
    # of three is not a failure. Keeping an adopted one current is what is not optional.
    repo, bao_base = _workflow_pair(tmp_path, "name: theirs\njobs: {}\n", None)
    assert workflow_copy.problems(repo, bao_base) == []


def test_inside_bao_base_there_is_nothing_to_compare(tmp_path):
    # Run in bao-base the two roots are one, and it holds the originals: comparing it against itself
    # would either be vacuous or — once the action path normalisation applied to both sides — report
    # bao-base as having drifted from itself.
    repo, _ = _workflow_pair(
        tmp_path,
        f"name: test\njobs:\n  build:\n    steps:\n{_CANONICAL_ACTION}\n",
        f"name: test\njobs:\n  build:\n    steps:\n{_CANONICAL_ACTION}\n",
    )
    assert workflow_copy.problems(repo, repo) == []


def test_says_so_when_bao_base_is_outside_the_repo(tmp_path):
    # Neither equal nor nested: there is no relative path a copy in this repo could be expected to
    # spell, so the check reports that fact rather than raising on the relative_to.
    repo, _ = _workflow_pair(tmp_path, None, "name: mine\njobs: {}\n")
    problems = workflow_copy.problems(repo, tmp_path / "elsewhere" / "bao-base")
    assert len(problems) == 1
    assert "outside the repo" in problems[0]


def test_the_check_carries_the_problems_it_found(tmp_path):
    # `check` is what both entrypoints report, so it must actually run `problems` rather than
    # describe it — a Check with the right name and an empty problems list would read as passing.
    repo, _ = _workflow_pair(tmp_path, None, "name: mine\njobs: {}\n")
    check = workflow_copy.check(repo)
    assert "workflows copied from bao-base" in check.name
    assert check.problems == workflow_copy.problems(repo, workflow_copy.BAO_BASE_ROOT)
