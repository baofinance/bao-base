"""Pytest configuration shared by every test under `tests/`.

The identity is set at import time - BEFORE test modules are collected - so it is already in place
for anything a module does at import, not only inside a fixture.
"""

import os

# Fixtures here build real git repositories and commit into them, and some of those repositories are
# created by GIT, not by the fixture: a submodule checkout under `.git/modules/`, a `git clone`. No
# `git config` call in a fixture reaches those, so their identity comes from the global config - and
# whether that is present is the difference between the machines this suite runs on.
#
# With nothing configured, git composes an identity from the user and the hostname, then REFUSES it
# when the hostname carries no domain: it becomes `user@host.(none)`, which git marks bogus and
# rejects with "fatal: unable to auto-detect e-mail address". A GitHub ubuntu runner has a bare
# hostname and so fails; a macOS runner's ends in `.local` and so is accepted, as is any developer
# machine with a global `user.email`. Hence a suite that passes everywhere except ubuntu CI.
#
# Naming the identity in the environment settles it for every repository at once, whoever created it,
# including any git command the tools under test run themselves.
os.environ["GIT_AUTHOR_NAME"] = "bao-base tests"
os.environ["GIT_AUTHOR_EMAIL"] = "tests@bao-base.invalid"
os.environ["GIT_COMMITTER_NAME"] = os.environ["GIT_AUTHOR_NAME"]
os.environ["GIT_COMMITTER_EMAIL"] = os.environ["GIT_AUTHOR_EMAIL"]
