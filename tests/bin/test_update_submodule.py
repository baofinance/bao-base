"""bin/update-submodule brings ONE named dependency to a version, and leaves nothing half-done.

It converges a checklist rather than running a fixed sequence, so what it does depends on what is
already true: a bump someone made in the VSCode GUI needs only the lock rewritten and the move
staged, while an untouched dependency needs the whole row. That is what makes it safe to run twice,
and able to finish a job something else started.

It moves the dependency with git and writes foundry.lock itself. `forge install` deletes the
dependency's working tree whenever it fails - including when it fails because git refused to
overwrite an uncommitted edit - so using it would make the refusal itself destructive. Tests here
therefore assert what the TREE looks like afterwards rather than which command was invoked: the
guarantee is about the state, not the mechanism.

`--check` reports and changes nothing. `--force` is the user's answer to a refusal, so the tool never
warns-and-proceeds: it either says nothing or it stops.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

BAO_BASE = Path(__file__).resolve().parents[2]
UPDATE_SUBMODULE = BAO_BASE / "bin" / "update-submodule"

# Cloning a submodule from a path on disk is refused by default (CVE-2022-39253). Allowing it for
# the fixture's git calls only keeps the user's own git config untouched.
GIT_ENV = {
    **os.environ,
    "GIT_CONFIG_COUNT": "1",
    "GIT_CONFIG_KEY_0": "protocol.file.allow",
    "GIT_CONFIG_VALUE_0": "always",
}


def git(*args: str, cwd: Path):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, env=GIT_ENV)


def make_dependency(root: Path, name: str) -> Path:
    """A committed repo plus the bare clone a submodule can be added from."""
    source = root / name
    source.mkdir()
    git("init", "-q", "-b", "main", ".", cwd=source)
    (source / "README.md").write_text(f"{name}\n")
    git("add", "-A", cwd=source)
    git("commit", "-qm", "initial", cwd=source)

    bare = root / f"{name}.git"
    git("clone", "-q", "--bare", str(source), str(bare), cwd=root)
    return bare


@pytest.fixture
def project(tmp_path, monkeypatch):
    """A throwaway superproject with two submodules under lib/, both clean and fully pushed.

    Two, not one, so the argument loop is exercised at more than a single iteration - and so a test
    can name one dependency and confirm the other is left out of the report.
    """
    root = tmp_path / "root"
    root.mkdir()
    first = make_dependency(root, "dep")
    second = make_dependency(root, "other")

    project = root / "project"
    project.mkdir()
    git("init", "-q", "-b", "main", ".", cwd=project)
    (project / "foundry.toml").write_text('[profile.default]\nlibs = ["lib"]\n')
    git("add", "-A", cwd=project)
    git("commit", "-qm", "initial", cwd=project)
    git("submodule", "add", "-q", str(first), "lib/dep", cwd=project)
    git("submodule", "add", "-q", str(second), "lib/other", cwd=project)
    git("commit", "-qm", "add submodules", cwd=project)

    monkeypatch.chdir(project)
    return project


def update_submodule(*args: str, path_prefix: Path | None = None) -> subprocess.CompletedProcess:
    """Run bin/update-submodule in the current directory.

    Invoked directly rather than through `run`, which would resolve BAO_BASE_DIR against the
    throwaway project.
    """
    env = dict(GIT_ENV)
    if path_prefix is not None:
        env["PATH"] = f"{path_prefix}{os.pathsep}{env['PATH']}"
    return subprocess.run([str(UPDATE_SUBMODULE), *args], capture_output=True, text=True, env=env)


def head(project: Path, name: str) -> str:
    return subprocess.run(
        ["git", "-C", str(project / "lib" / name), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


# ── locating the dependency: the ref must never make the lookup fail ──────────────────────────────


def test_a_bare_name_is_located_under_lib(project):
    # `yarn update dep@main` - the name is not a path, and the ref is not part of it
    result = update_submodule("--check", "dep@main")
    assert result.returncode == 0, result.stderr
    assert "lib/dep" in result.stdout


def test_a_path_is_accepted_as_well_as_a_name(project):
    result = update_submodule("--check", "lib/dep@main")
    assert result.returncode == 0, result.stderr
    assert "lib/dep" in result.stdout


def test_a_ref_containing_a_slash_does_not_break_the_lookup(project):
    # A tag or branch may itself contain a slash - deploy/harbor-1.2, feature/x. The dependency is
    # still found; the complaint must be about the ref, not about the path.
    result = update_submodule("--check", "dep@deploy/harbor-1.2")
    assert "lib/dep" in result.stdout
    assert "no submodule" not in result.stdout + result.stderr
    assert "not a tag, branch or commit" in result.stdout


def test_every_named_dependency_is_processed(project):
    result = update_submodule("--check", "dep@main", "other@main")
    assert result.returncode == 0, result.stderr
    assert "lib/dep" in result.stdout and "lib/other" in result.stdout


def test_only_the_named_dependency_is_touched(project):
    # The report must describe what was actually inspected, not claim the whole project.
    result = update_submodule("--check", "dep@main")
    assert result.returncode == 0, result.stderr
    assert "lib/other" not in result.stdout


def test_an_unknown_dependency_is_reported_by_its_path(project):
    result = update_submodule("--check", "nosuch@main")
    assert result.returncode != 0
    assert "nosuch" in result.stderr and "no submodule" in result.stderr


# ── naming nothing is an error, not a request to update everything ────────────────────────────────


def test_naming_no_dependency_is_refused(project):
    # The shape that lets one request change dependencies nobody asked about. `forge update` has it
    # and the old wrapper mirrored it deliberately; this one does not.
    result = update_submodule("--check")
    assert result.returncode != 0
    assert "name at least one dependency" in result.stderr


def test_a_stationary_pin_without_a_ref_is_refused_with_a_candidate(project):
    # Two pins can disagree and the tool cannot know which was meant, so it asks - and carries the
    # version the working tree is actually on, which turns the refusal into a one-line fix.
    (project / "foundry.lock").write_text(json.dumps({"lib/dep": {"tag": {"name": "v1", "rev": "0" * 40}}}))
    git("tag", "v1", cwd=project / "lib" / "dep")

    result = update_submodule("--check", "dep")

    assert result.returncode != 0
    assert "cannot move on its own" in result.stdout
    assert "yarn update dep@v1" in result.stdout


# ── nothing is touched until the checklist says it may be ─────────────────────────────────────────


def test_an_uncommitted_edit_stops_the_update_before_anything_moves(project):
    before = head(project, "dep")
    (project / "lib" / "dep" / "README.md").write_text("edited\n")

    result = update_submodule("dep@main")

    assert result.returncode != 0
    assert "exists nowhere else" in result.stdout
    assert "README.md" in result.stdout, "the refusal must name what it found"
    assert head(project, "dep") == before, "nothing may move"
    assert (project / "lib" / "dep" / "README.md").read_text() == "edited\n", "the edit must survive"


def test_force_is_the_answer_to_a_refusal(project):
    # --force is a decision the user makes after being told what is at stake, which is why the tool
    # stops rather than warning and proceeding.
    (project / "lib" / "dep" / "untracked.txt").write_text("scratch\n")

    refused = update_submodule("dep@main")
    assert refused.returncode != 0

    forced = update_submodule("--force", "dep@main")
    assert forced.returncode == 0, forced.stdout + forced.stderr


def test_check_changes_nothing_at_all(project):
    before = head(project, "dep")
    lock = project / "foundry.lock"

    result = update_submodule("--check", "dep@main")

    assert result.returncode == 0, result.stderr
    assert head(project, "dep") == before
    assert not lock.exists(), "--check must not write the lock either"


# ── converging: only what is undone is done ───────────────────────────────────────────────────────


def test_an_already_correct_dependency_is_left_alone(project):
    # The property that lets it finish someone else's job: when the working tree is already at the
    # ref, nothing is fetched, moved or re-cloned - only the lock and the staging remain.
    update_submodule("dep@main")
    before = head(project, "dep")

    result = update_submodule("dep@main")

    assert result.returncode == 0, result.stdout + result.stderr
    assert head(project, "dep") == before
    assert "[x] 2." in result.stdout, "stage 2 must already be satisfied"


def test_the_lock_is_written_and_then_verified(project):
    result = update_submodule("dep@main")

    assert result.returncode == 0, result.stdout + result.stderr
    entry = json.loads((project / "foundry.lock").read_text())["lib/dep"]
    assert entry == {"branch": {"name": "main", "rev": head(project, "dep")}}, entry
    assert "[x] 5." in result.stdout, "and re-read afterwards rather than assumed"


def test_staging_and_committing_are_printed_not_run(project):
    result = update_submodule("dep@main")

    assert result.returncode == 0, result.stdout + result.stderr
    assert "git add lib/dep" in result.stdout
    staged = subprocess.run(
        ["git", "diff", "--cached", "--name-only"], cwd=project, capture_output=True, text=True
    ).stdout
    assert staged.strip() == "", "the superproject's git is the user's"


def test_a_stranded_directory_is_removed(project, tmp_path):
    # When a dependency moves to a version that no longer declares one of its own submodules, git
    # cannot delete the populated directory - it reports "unable to rmdir" and carries on, leaving a
    # repository nothing tracks. Clearing it is stage 4, and it is safe here precisely because stage 0
    # has already established that nothing under it exists only there.
    stranded = project / "lib" / "dep" / "stranded"
    git("clone", "-q", str(tmp_path / "root" / "other.git"), str(stranded), cwd=project)
    assert stranded.is_dir()

    result = update_submodule("dep@main")

    assert result.returncode == 0, result.stdout + result.stderr
    assert not stranded.exists(), "the stranded directory must be gone"
    assert "removed lib/dep/stranded" in result.stdout, "and said so"


def test_a_nested_dependency_does_not_gain_an_entry_in_our_lock(project, tmp_path):
    # Litter can be stranded one level down - a dependency's own dependency moving to a version that
    # declares fewer submodules - so a repair must be able to name that nested path. foundry.lock
    # records only what THIS repository depends on, and forge never writes another repository's
    # dependency into it, so an entry for a nested path pins nothing and is reported as stale by the
    # mirror check. Sweeping it must leave the lock alone.
    git(
        "-c",
        "protocol.file.allow=always",
        "submodule",
        "add",
        "-q",
        str(tmp_path / "root" / "other.git"),
        "lib/inner",
        cwd=project / "lib" / "dep",
    )
    git("commit", "-qm", "add inner", cwd=project / "lib" / "dep")
    stranded = project / "lib" / "dep" / "lib" / "inner" / "stranded"
    git("clone", "-q", str(tmp_path / "root" / "other.git"), str(stranded), cwd=project)
    before = (project / "foundry.lock").read_text() if (project / "foundry.lock").is_file() else ""

    result = update_submodule("--sweep", "lib/dep/lib/inner")

    assert result.returncode == 0, result.stdout + result.stderr
    assert not stranded.exists(), "the stranded directory must still be swept"
    after = (project / "foundry.lock").read_text() if (project / "foundry.lock").is_file() else ""
    assert "lib/dep/lib/inner" not in after, f"our lock must not pin someone else's dependency: {after}"
    assert after == before, "and must not be rewritten at all for a submodule we do not own"


def test_a_stranded_directory_holding_work_is_not_removed(project, tmp_path):
    # The other half. A directory that looks identical but holds a commit no remote has is stopped
    # on, not swept up - the difference is not what it is but whether losing it matters.
    stranded = project / "lib" / "dep" / "stranded"
    git("clone", "-q", str(tmp_path / "root" / "other.git"), str(stranded), cwd=project)
    (stranded / "mine.txt").write_text("a day of work\n")
    git("add", "-A", cwd=stranded)
    git("commit", "-qm", "unpushed", cwd=stranded)

    result = update_submodule("dep@main")

    assert result.returncode != 0
    assert stranded.is_dir(), "it must still be there"
    assert (stranded / "mine.txt").is_file()
    assert "exists nowhere else" in result.stdout


@pytest.mark.parametrize("stop_after", ["nothing", "stage", "commit"])
def test_doctor_advises_exactly_what_update_would_do_next(project, stop_after):
    # The two tools must not give different answers about the same tree. Doctor's Repair line is taken
    # from the same checklist `yarn update` converges, so whatever update reports as its first undone
    # stage is what doctor tells the user to run - across every point a bump can be abandoned at.
    sys.path.insert(0, str(BAO_BASE / "bin"))
    import doctor

    git("fetch", "-q", "origin", cwd=project / "lib" / "dep")
    update_submodule("dep@main")  # brings the working tree and the lock into line
    if stop_after in ("stage", "commit"):
        git("add", "lib/dep", "foundry.lock", cwd=project)
    if stop_after == "commit":
        git("commit", "-qm", "record dep", cwd=project)

    findings = [p for p in sum(doctor.submodule_problems(project), []) if p.startswith("lib/dep:")]
    checked = update_submodule("--check", "dep@main")

    if not findings:
        assert "[ ]" not in checked.stdout, "doctor is quiet, so update must have nothing left"
        return
    advice = next(line.split("Repair: ", 1)[1] for line in findings[0].splitlines() if "Repair: " in line)
    first_undone = next(line.strip() for line in checked.stdout.splitlines() if line.strip().startswith("[ ]"))
    assert advice in checked.stdout, f"doctor advises {advice!r}, which update never mentions"
    assert first_undone, "and update must actually have something undone"


# ── --relock: the lock follows the tree, instead of the tree following a ref ──────────────────────
#
# The reverse direction. `converge` moves a dependency to a ref the caller names; this records where
# the dependency already is - a bump made in a GUI, or a fleet converged by hand. Its risk is the
# mirror of its use: it blesses whatever is checked out, so it insists the tree has settled first.


def bump_and_stage(project: Path, tmp_path: Path, name: str = "dep") -> str:
    """Move a dependency to a new upstream commit and stage it, without touching foundry.lock."""
    source = tmp_path / "root" / name
    (source / "README.md").write_text("moved on\n")
    git("add", "-A", cwd=source)
    git("commit", "-qm", "moved on", cwd=source)
    # The fixture's sources have no remote of their own; the bare clone the submodule points at sits
    # beside them, so it is named by path.
    git("push", "-q", str(tmp_path / "root" / f"{name}.git"), "main", cwd=source)
    git("fetch", "-q", "origin", cwd=project / "lib" / name)
    git("checkout", "-q", "origin/main", cwd=project / "lib" / name)
    git("add", f"lib/{name}", cwd=project)
    return head(project, name)


def test_relock_records_the_commit_already_staged(project, tmp_path):
    # No lock entry to preserve, and the new commit carries no tag, so a bare rev is what records it.
    moved = bump_and_stage(project, tmp_path)

    result = update_submodule("--relock", "dep")

    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads((project / "foundry.lock").read_text())["lib/dep"]["rev"] == moved
    assert head(project, "dep") == moved, "and it must not have moved the dependency"


def test_relock_keeps_a_branch_pin_on_its_branch(project, tmp_path):
    # Following the branch is what a branch pin is for, so the name stays and only the commit moves.
    (project / "foundry.lock").write_text(json.dumps({"lib/dep": {"branch": {"name": "main", "rev": "0" * 40}}}))
    moved = bump_and_stage(project, tmp_path)

    update_submodule("--relock", "dep")

    entry = json.loads((project / "foundry.lock").read_text())["lib/dep"]
    assert entry["branch"] == {"name": "main", "rev": moved}


def test_relock_does_not_keep_a_tag_pin_the_commit_has_left(project, tmp_path):
    # A tag names one commit. Once the commit moves the old tag is simply wrong, so it cannot be
    # carried forward the way a branch name can - it becomes the new commit's tag, or a bare rev.
    (project / "foundry.lock").write_text(json.dumps({"lib/dep": {"tag": {"name": "v1", "rev": "0" * 40}}}))
    moved = bump_and_stage(project, tmp_path)

    update_submodule("--relock", "dep")

    entry = json.loads((project / "foundry.lock").read_text())["lib/dep"]
    assert entry == {"rev": moved}, "a stale tag must not survive the commit it named"


def test_relock_refuses_a_move_that_is_not_staged(project, tmp_path):
    # An unstaged checkout is not yet a decision. Recording it would turn a stray `git checkout` into
    # the pin everyone else gets, and remove the disagreement that would have shown it up.
    before = (project / "foundry.lock").read_text() if (project / "foundry.lock").is_file() else ""
    bump_and_stage(project, tmp_path)
    git("restore", "--staged", "lib/dep", cwd=project)

    result = update_submodule("--relock", "dep")

    assert result.returncode != 0
    assert "stage the move first" in result.stdout
    after = (project / "foundry.lock").read_text() if (project / "foundry.lock").is_file() else ""
    assert after == before, "and it must not have written anything"


def test_relock_check_reports_without_writing(project, tmp_path):
    bump_and_stage(project, tmp_path)
    before = (project / "foundry.lock").read_text() if (project / "foundry.lock").is_file() else ""

    result = update_submodule("--relock", "--check", "dep")

    assert result.returncode == 0
    assert "would become" in result.stdout
    after = (project / "foundry.lock").read_text() if (project / "foundry.lock").is_file() else ""
    assert after == before


def test_relock_all_covers_every_dependency_without_naming_them(project, tmp_path):
    # The one place an "all" form is admitted: it moves nothing, so it cannot change a dependency
    # nobody asked about - it only records where they already are.
    bump_and_stage(project, tmp_path, "dep")
    bump_and_stage(project, tmp_path, "other")

    result = update_submodule("--relock", "--all")

    assert result.returncode == 0, result.stdout + result.stderr
    locked = json.loads((project / "foundry.lock").read_text())
    assert locked["lib/dep"]["rev"] == head(project, "dep")
    assert locked["lib/other"]["rev"] == head(project, "other")


def test_all_is_refused_for_a_form_that_moves_dependencies(project):
    # The ban this preserves: `forge update` sprays every branch-pinned dependency, and the wrapper
    # exists partly to refuse that shape.
    result = update_submodule("--all", "dep@main")

    assert result.returncode != 0
    assert "only for --relock" in result.stderr
