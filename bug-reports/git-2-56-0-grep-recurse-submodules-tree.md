> **Status.** Sent to git@vger.kernel.org on 2026-10-29, copied to Patrick Steinhardt, who wrote the
> commit that caused it. No reply had come when this file was written. The thread's link in the list
> archive (https://lore.kernel.org/git/) is not recorded here yet. bao-base does not wait on a fix:
> `sources_at` in `bin/deployment_recovery.py` searches each repository at its own commit and does
> not use `--recurse-submodules`. The text below is the draft the message was sent from.

```text
To: git@vger.kernel.org
Cc: Patrick Steinhardt <ps@pks.im>
Subject: [BUG] grep --recurse-submodules <tree> dies on a directory inside a submodule

Since Git 2.56.0, "git grep --recurse-submodules <pattern> <tree>"
dies when it reaches a directory inside a submodule:

    fatal: unable to read tree (<id of that directory's tree>)

The working-tree form ("git grep --recurse-submodules <pattern>") is
not affected, and neither is a submodule with no directories. Our CI
passed the same case on 2.55.0.

What did you do before the bug happened? (Steps to reproduce your issue)

    #!/bin/sh
    set -e
    work=$(mktemp -d)
    cd "$work"

    git init -q sub
    mkdir sub/dir
    echo hello >sub/top
    echo hello >sub/dir/nested
    git -C sub add top dir/nested
    git -C sub -c user.name=t -c user.email=t@t commit -qm sub

    git init -q super
    git -C super -c protocol.file.allow=always \
        submodule --quiet add "$work/sub" sub
    git -C super -c user.name=t -c user.email=t@t commit -qm super

    git -C super grep --recurse-submodules -e hello HEAD

What did you expect to happen? (Expected behavior)

    HEAD:sub/dir/nested:hello
    HEAD:sub/top:hello

What happened instead? (Actual behavior)

    fatal: unable to read tree (935cff11a11f8734cf4e0d40955d1e0e5c12038e)

with exit status 128. The id is that of the tree of sub/dir.

What's different between what you expected and what actually happened?

The search dies instead of listing the matches. It dies at the first
directory inside the submodule, so nothing in that submodule is
searched from there on.

Anything else you want to add:

It starts with 93cd344e34 (builtin/grep: stop registering submodule
ODB as source, 2026-09-11). Built from source (with NO_RUST=1), its
parent a532feba89 prints the expected output above, and 93cd344e34
dies with the same message and the same tree id.

In grep_tree(), each subdirectory is read from the superproject's
object database (builtin/grep.c line 656 in v2.56.0):

    data = odb_read_object(the_repository->objects,
                           &entry.oid, &type, &size);

The function's repository is opt->repo, and grep_submodule() sets
that to the submodule. grep_submodule() reads the submodule's root
tree from subrepo->objects, which is why a submodule with no
directories is searched correctly. Before 93cd344e34 the submodule's
object database was registered as a source of the main one, so the
lookup above found the tree there.

On v2.56.0, reading from repo->objects on that line instead makes the
reproduction print the expected output. I have not run the test
suite with that change.

grep_cache() reads sparse-directory index entries the same way, on
line 563:

    data = odb_read_object(the_repository->objects, &ce->oid,
                           &type, &size);

I have not checked whether a submodule with a sparse index fails.

Both lines are unchanged on master, next and seen as of 2026-10-29.

We met this in CI: GitHub's ubuntu-22.04 runner image moved from git
2.55.0 to 2.56.0 between its 2026-10-12 and 2026-10-25 releases.

[System Info]
git version:
git version 2.56.0
cpu: x86_64
no commit associated with this build
sizeof-long: 8
sizeof-size_t: 8
shell-path: /bin/sh
rust: enabled
feature: fsmonitor--daemon
gettext: enabled
libcurl: 7.81.0
zlib: 1.2.11
SHA-1: SHA1_DC
SHA-256: SHA256_BLK
default-ref-format: files
default-hash: sha1
uname: Linux 7.0.0-38-generic #38~24.04.4-Ubuntu SMP PREEMPT_DYNAMIC Mon Sep 14 16:37:11 UTC 2 x86_64
compiler info: gnuc: 11.4
libc info: glibc: 2.35
$SHELL (typically, interactive shell): <unset>

(Ubuntu 22.04 in a container, git 2.56.0 from the git-core PPA; the
kernel line is the host's.)


[Enabled Hooks]
not run from a git repository - no hooks to show
```
