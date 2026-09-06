"""What `forge update` and `forge install` actually do to a submodule, its nested submodules, and
foundry.lock.

bin/update-submodule drives one of these two commands, and they are not interchangeable. Measured on
forge 1.8.1:

  forge install <url>@<ref>   acts on the dependency named, writes the lock, recurses into nested
                              submodules and repairs ones left off their recorded commit
  forge update <path>[@<ref>] acts on dependencies it was NOT given, silently does nothing for the one
                              it WAS given when that pin is a tag, and can leave the lock unwritten
                              while still exiting 0

So bin/update-submodule uses `forge install` exclusively, and treats forge's exit code as no evidence
that anything worked. These tests pin those behaviours: each one fails when forge changes, which is
the signal to revisit the wrapper rather than a reason to edit the assertion.

Everything runs against local repositories served over plain HTTP on an ephemeral port. `forge
install` refuses `file://`, `git://` and `http://` URLs - it prepends `https://github.com/` to
anything that is not already `https://<dotted-host>/<org>/<repo>` - so the project asks for an
`https://` URL and git's `insteadOf` rewriting sends it to the local server. That keeps the suite
offline without needing TLS, a privileged port or an /etc/hosts entry.

Two further parser defects were measured and are not covered here, because no code of ours depends on
them: a URL carrying a port has the port turned into a path segment
(`https://h:8443/o/r` -> `https://h/8443/o/r`), and a dotless host is rejected outright. Both corrupt
silently rather than failing.
"""

import json
import subprocess
import threading
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

import pytest

# forge only accepts https://<dotted-host>/<org>/<repo>, so the project always names this host and git
# rewrites it to the local server. The host never resolves and is never contacted.
FAKE_HOST = "https://forge-test.example/"

FOUNDRY_TOML = """\
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
"""

CONTRACT = """\
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract X {}
"""


def git(where, *arguments, check=True):
    return subprocess.run(["git", *arguments], cwd=where, capture_output=True, text=True, check=check)


class Remotes:
    """Fake dependency repositories, served so `forge install` can clone them.

    Each dependency is a working repository plus a bare copy under the served directory; `publish`
    pushes one to the other and refreshes the dumb-HTTP index that a bare repo needs before git can
    read it over plain HTTP.
    """

    def __init__(self, root):
        self.root = root
        self.work = root / "work"
        self.served = root / "served" / "testorg"
        self.work.mkdir(parents=True)
        self.served.mkdir(parents=True)
        handler = partial(SimpleHTTPRequestHandler, directory=str(root / "served"))
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.port = self.server.server_address[1]

    def create(self, name):
        """A dependency with one commit tagged v1.0.0 and a `main` branch that can advance."""
        source = self.work / name
        source.mkdir()
        git(source, "init", "-q", "-b", "main")
        git(source, "config", "user.email", "toolchain@test")
        git(source, "config", "user.name", "toolchain")
        (source / "A.sol").write_text(CONTRACT)
        git(source, "add", "-A")
        git(source, "commit", "-qm", "one")
        git(source, "tag", "v1.0.0")
        git(self.root, "clone", "-q", "--bare", str(source), str(self.served / name))
        self.publish(name)
        return source

    def commit(self, name, message):
        """Add a commit to the dependency's `main` and publish it."""
        source = self.work / name
        (source / "A.sol").write_text(CONTRACT + f"\n// {message}\n")
        git(source, "add", "-A")
        git(source, "commit", "-qm", message)
        self.publish(name)

    def tag(self, name, tag):
        git(self.work / name, "tag", tag)
        self.publish(name)

    def publish(self, name):
        bare = self.served / name
        git(self.work / name, "push", "-q", "--force", "--tags", str(bare), "main")
        # A bare repository is unreadable over dumb HTTP until this is regenerated, and it goes stale
        # on every push - so it belongs here rather than at creation.
        git(bare, "update-server-info")

    def url(self, name):
        return f"{FAKE_HOST}testorg/{name}"

    def rev(self, name, ref):
        return git(self.work / name, "rev-parse", ref).stdout.strip()

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


@pytest.fixture
def remotes(tmp_path, monkeypatch):
    """The fake dependencies, plus the git rewriting that makes the fake host reach them.

    The rewrite goes in the environment rather than any repository's config so that it reaches every
    git invocation - including the submodule clones forge makes, which inherit nothing from the
    project - without a repository having to be created first.
    """
    served = Remotes(tmp_path / "remotes")
    monkeypatch.setenv("GIT_CONFIG_COUNT", "1")
    monkeypatch.setenv("GIT_CONFIG_KEY_0", f"url.http://127.0.0.1:{served.port}/.insteadOf")
    monkeypatch.setenv("GIT_CONFIG_VALUE_0", FAKE_HOST)
    yield served
    served.stop()


@pytest.fixture
def project(tmp_path, remotes):
    """An empty foundry project whose git rewrites the fake host to the local server.

    The rewrite is passed through the environment rather than written into the project's config so it
    reaches the submodule clones that forge makes, which inherit nothing from this repository.
    """
    root = tmp_path / "project"
    (root / "src").mkdir(parents=True)
    (root / "foundry.toml").write_text(FOUNDRY_TOML)
    (root / "src" / "X.sol").write_text(CONTRACT)
    git(root, "init", "-q", "-b", "main")
    git(root, "config", "user.email", "toolchain@test")
    git(root, "config", "user.name", "toolchain")
    git(root, "add", "-A")
    git(root, "commit", "-qm", "init")
    return root


def forge(project, *arguments):
    """Run forge in `project`. The `remotes` fixture has put the git rewriting in the environment."""
    return subprocess.run(["forge", *arguments], cwd=project, capture_output=True, text=True)


def install(project, remotes, name, ref):
    result = forge(project, "install", f"{remotes.url(name)}@{ref}")
    assert result.returncode == 0, f"setup install of {name}@{ref} failed:\n{result.stderr}"
    git(project, "add", "-A")
    git(project, "commit", "-qm", f"install {name}@{ref}")
    return result


def remove(project, name):
    """Delete a dependency the way bin/update-submodule does, leaving nothing behind.

    The `.git/modules` gitdir must go too: git reuses it on the next add, so a reinstall that skipped
    it would restore the old configuration rather than a fresh clone.
    """
    git(project, "submodule", "deinit", "-f", f"lib/{name}")
    subprocess.run(["rm", "-rf", str(project / "lib" / name)], check=True)
    subprocess.run(["rm", "-rf", str(project / ".git" / "modules" / "lib" / name)], check=True)


def head(project, name):
    return git(project / "lib" / name, "rev-parse", "HEAD").stdout.strip()


def lock(project):
    return json.loads((project / "foundry.lock").read_text())


def test_update_without_ref_ignores_a_stationary_pin(project, remotes):
    # A tag pin cannot move on its own, so `forge update` has nothing to do - but it says nothing at
    # all, and exits 0, which reads exactly like a successful update. bin/update-submodule turns this
    # case into an error instead.
    remotes.create("dep")
    install(project, remotes, "dep", "v1.0.0")
    remotes.commit("dep", "two")
    remotes.tag("dep", "v1.2.0")
    pinned = head(project, "dep")
    # Without somewhere newer to go, "it did not move" would hold no matter what forge did.
    assert remotes.rev("dep", "v1.2.0") != pinned, "the dependency must start behind a newer tag"

    result = forge(project, "update", "lib/dep")

    assert result.returncode == 0
    assert head(project, "dep") == pinned, (
        "forge update now moves a tag-pinned dependency it was given. bin/update-submodule assumes "
        f"it does nothing here and errors instead - revisit that.\n{result.stdout}"
    )
    assert "lib/dep" not in result.stdout, (
        f"forge update now reports something for the dependency it was given.\n{result.stdout}"
    )


def test_update_without_ref_moves_unnamed_branch_deps(project, remotes):
    # The dependency named is not the dependency updated: every branch-pinned dependency moves to its
    # remote tip regardless of what was asked for. This is why bin/update-submodule never calls
    # forge update - a request to touch one dependency must not change the build of another.
    remotes.create("dep")
    remotes.create("other")
    install(project, remotes, "dep", "v1.0.0")
    install(project, remotes, "other", "main")
    # `other` is now behind its remote, so a spraying command has somewhere to move it to.
    remotes.commit("other", "moved on")
    before = head(project, "other")

    result = forge(project, "update", "lib/dep")

    assert result.returncode == 0
    assert head(project, "other") != before, (
        "forge update no longer moves dependencies it was not given. If that is fixed, the reason "
        f"bin/update-submodule avoids it is weaker - re-read this module.\n{result.stdout}"
    )
    assert head(project, "other") == remotes.rev("other", "main")


def test_update_with_ref_on_a_tag_pin_leaves_the_lock_unwritten(project, remotes):
    # The worst of the three: the working tree moves, the lock is left describing the old commit, and
    # the exit code is 0. Only a warning distinguishes it from success, so bin/update-submodule
    # verifies the resulting state instead of trusting the exit code.
    remotes.create("dep")
    install(project, remotes, "dep", "v1.0.0")
    remotes.tag("dep", "v1.2.0")
    locked = lock(project)["lib/dep"]["tag"]["rev"]

    result = forge(project, "update", "lib/dep@v1.2.0")

    assert result.returncode == 0, "the failure is silent - a non-zero exit would be an improvement"
    assert head(project, "dep") == remotes.rev("dep", "v1.2.0"), (
        f"forge update no longer moves the working tree in this case.\n{result.stdout}"
    )
    assert lock(project)["lib/dep"]["tag"]["rev"] == locked, (
        "forge update now writes the lock when overriding a tag pin, so the working tree and the "
        f"lock agree. bin/update-submodule's post-check would stop catching this.\n{result.stdout}"
    )


def test_install_over_an_existing_clone_cannot_reach_a_new_ref(project, remotes):
    # forge install resolves the ref against the clone already on disk and never fetches, so a tag
    # published after that clone is simply "not found" - no network request is even made. This is why
    # bin/update-submodule deletes the dependency before installing rather than installing over it.
    remotes.create("dep")
    install(project, remotes, "dep", "v1.0.0")
    remotes.tag("dep", "v1.2.0")

    result = forge(project, "install", f"{remotes.url('dep')}@v1.2.0")

    assert result.returncode != 0, (
        "forge install now fetches before resolving a ref, so installing over an existing clone "
        f"works. Deleting first is then belt-and-braces rather than required.\n{result.stdout}"
    )
    assert "not found" in result.stderr, (
        f"forge install failed for some other reason than the ref being unreachable.\n{result.stderr}"
    )


def test_install_moves_only_the_named_dependency(project, remotes):
    # The property that makes `forge install` usable where `forge update` is not: a sibling that is
    # behind its remote stays exactly where it is. Run through delete-then-install, which is the
    # sequence bin/update-submodule uses.
    remotes.create("dep")
    remotes.create("other")
    install(project, remotes, "dep", "v1.0.0")
    install(project, remotes, "other", "main")
    # `other` is now behind its remote, so a spraying command would visibly advance it.
    remotes.commit("other", "moved on")
    untouched = head(project, "other")
    remotes.tag("dep", "v1.2.0")

    remove(project, "dep")
    result = forge(project, "install", f"{remotes.url('dep')}@v1.2.0")

    assert result.returncode == 0, result.stderr
    assert head(project, "dep") == remotes.rev("dep", "v1.2.0")
    assert head(project, "other") == untouched, (
        f"forge install now moves dependencies it was not given.\n{result.stdout}"
    )


def test_install_repairs_a_nested_submodule(project, remotes):
    # bin/update-submodule deletes and reinstalls rather than repairing, and relies on the reinstall
    # leaving nested submodules at their recorded commits - not merely populating them on a fresh
    # clone. A dependency whose own submodule is off its pin must come back correct.
    remotes.create("dep")
    remotes.create("inner")
    source = remotes.work / "dep"
    git(source, "submodule", "add", "-q", remotes.url("inner"), "lib/inner")
    git(source, "commit", "-qm", "add inner")
    remotes.publish("dep")
    install(project, remotes, "dep", "main")

    recorded = head(project / "lib" / "dep", "inner")
    remotes.commit("inner", "inner moved")
    git(project / "lib" / "dep" / "lib" / "inner", "fetch", "-q", "origin", "main")
    git(project / "lib" / "dep" / "lib" / "inner", "checkout", "-q", "FETCH_HEAD")
    assert head(project / "lib" / "dep", "inner") != recorded, "the nested submodule must start broken"

    result = forge(project, "install", f"{remotes.url('dep')}@main")

    assert result.returncode == 0, result.stderr
    assert head(project / "lib" / "dep", "inner") == recorded, (
        "forge install no longer restores a nested submodule to its recorded commit, so a reinstall "
        f"is not enough on its own.\n{result.stdout}"
    )


@pytest.mark.parametrize(
    "ref_name, expected_kind",
    [("v1.0.0", "tag"), ("main", "branch")],
)
def test_install_pin_kind_follows_the_ref(project, remotes, ref_name, expected_kind):
    # The lock records what KIND of thing was asked for, which is what tells bin/update-submodule
    # whether a later bare `yarn update` may move the dependency (branch) or must be told a ref (tag).
    remotes.create("dep")

    install(project, remotes, "dep", ref_name)

    entry = lock(project)["lib/dep"]
    assert expected_kind in entry, (
        f"asking for {ref_name!r} no longer records a {expected_kind!r} pin; got {entry!r}. "
        "The stationary/moving distinction bin/update-submodule reads comes from this."
    )
    assert entry[expected_kind]["name"] == ref_name
    assert entry[expected_kind]["rev"] == remotes.rev("dep", ref_name)


def test_install_records_a_bare_commit_as_a_rev_pin(project, remotes):
    # The third pin kind, and the one with no name to follow: a commit is stationary but names no ref,
    # so a later bare `yarn update` has nothing to resolve and must error just as a tag does.
    remotes.create("dep")
    remotes.commit("dep", "two")
    sha = remotes.rev("dep", "main")

    install(project, remotes, "dep", sha)

    entry = lock(project)["lib/dep"]
    assert "rev" in entry and entry["rev"] == sha, (
        f"asking for a bare commit no longer records a rev pin; got {entry!r}."
    )
