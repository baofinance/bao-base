# Dependencies: a cookbook

A repository's dependencies are git submodules in `lib/`. Every one of them is checked out, and so is every
dependency of a dependency, at every depth. They are managed with git's own commands. This page gives the
commands for each task.

In the commands below:

- `<name>` is a dependency, and `lib/<name>` is its folder.
- `<shared>` is a dependency that this repository and `<name>` both have.
- `<url>`, `<branch>`, `<tag>` and `<commit>` are what they say.

Type each command in the repository's top folder. Every command on this page was measured on git 2.43.

## Four things to know

1. **The repository records one commit of each dependency.** `git status` shows `lib/<name>` as modified
   while the folder is at another commit. Recording a different commit is a change that you commit, like any
   other.
2. **Nothing moves the folders for you.** After a pull, a merge or a branch switch, each folder stays where
   it was until you run the update command below. Until then the build uses the old commits.
3. **After a clone or an update, a folder is on no branch.** git calls this a detached HEAD. Put a folder on
   a branch before you commit in it. The next update leaves behind a commit that was made on no branch, and
   only `git reflog` finds it then.
4. **You work on a dependency in its folder.** `lib/<name>` is a full repository. The build reads it as it
   is, uncommitted edits included.

## Never

- **Do not set `submodule.recurse`, to any value.** With `true`, a branch switch discards an uncommitted
  edit inside `lib/` without a message. With `false`, git can stop making the push check described below.
- **Do not use forge's `install`, `update` or `remove`.** Measured on forge 1.9.0: `forge update` moves a
  folder that follows a branch to the remote's newest commit, and a commit of yours there that is not pushed
  is left on no branch. Where a `foundry.lock` exists, it also puts back a folder that git moved, without a
  message.
- **Do not run `git submodule update --remote` without a folder name.** A dependency that has no `branch`
  line in `.gitmodules` then moves to the newest commit of its remote's default branch.

## `git dep`: these procedures as commands

bao-base holds a script that runs procedures of this page, with the checks they ask you to make. It prints
each git command that changes something before it runs it. It never commits, and it never pushes the
repository you are in.

- **The first time in a clone, type `yarn setup`.** It runs the script by its path, with `setup`:
  `lib/bao-base/bin/git-dep setup`, and in bao-base itself `bin/git-dep setup`. That run writes the settings
  below, and an alias. From then on the command is `git dep`, from any folder of the clone. `setup` moves no
  folder, so it is safe at any time.
- `yarn setup` needs `yarn install` to have run: before it, yarn refuses every script with
  `Couldn't find the node_modules state file`. The path typed by hand needs only git and `python3`.
- A repository that uses bao-base has the line `"setup": "./lib/bao-base/run setup"` among the scripts of its
  `package.json`. Do not name such a script `init`: `yarn init` is a command of yarn's own, which writes a
  new `package.json` over the one that is there.
- `git dep help` lists the commands. `git dep cookbook` prints this page. `git dep --help` shows only the
  alias, because git answers that one itself.
- Typed inside a dependency folder, `git dep` runs that dependency's own copy of the script, and acts on that
  dependency.
- When git answers `fatal: cannot exec 'lib/bao-base/bin/git-dep'`, the script is not there: `lib/bao-base`
  is empty, or is at a commit from before the script. Use the plain commands of this page.

A section below names its command where it has one.

## Settings, once in each clone

```
git config push.recurseSubmodules check
git config diff.submodule log
git config status.submoduleSummary true
git submodule foreach --quiet --recursive 'git config push.recurseSubmodules check; git config diff.submodule log; git config status.submoduleSummary true'
```

- `push.recurseSubmodules check`: git refuses a push that records a dependency commit no remote has.
- `diff.submodule log` and `status.submoduleSummary true`: a folder at another commit is shown as the
  commits between the two.
- The last command writes the same three into every dependency folder, at every depth. Each folder is a
  repository with its own settings, and a push from inside it is checked in the same way.

**A folder that is checked out later has none of them.** Run the last command again whenever a folder has
been checked out for the first time: after you add a dependency, and after an update that brought one in.
It changes nothing in the folders that already have them.

**As a command:** `git dep setup`. It writes the three settings, and the alias for `git dep`, in the clone
and in every dependency folder. It moves no folder.

## A new clone

```
git clone --recurse-submodules <url>
```

Then write the settings above. Every folder is checked out, each on no branch.

For a clone made without `--recurse-submodules`, run the update command of the next section.

**As a command:** `yarn setup`, typed after the clone and `yarn install`, writes the settings. So does
`lib/bao-base/bin/git-dep setup`, which needs no install.

## After a pull, a merge or a branch switch

```
git submodule update --init --recursive
```

This puts every folder, at every depth, at the commit now recorded for it. It also checks out a dependency
that is new.

- **Look first.** The first command under "See where things stand" names a commit that this update would
  leave behind.
- **A folder that is on a branch** is put at the recorded commit, on no branch, unless the branch's newest
  commit is the recorded one. The branch keeps its commits. `git -C lib/<name> switch <branch>` goes back to
  it.
- **To leave a folder you are working in where it is,** name the other folders:
  `git submodule update --init --recursive -- lib/<a> lib/<b>`. Then, for the folders beneath the one you
  left: `git -C lib/<name> submodule update --init --recursive`.
- **A new dependency.** `git pull` prints `Could not access submodule 'lib/<name>'` when the pull brings one
  in, because its folder is not there yet. The update checks it out. Then run the last settings command.
- **An uncommitted edit is kept.** Where the move would overwrite it, git stops for that folder with
  `Your local changes to the following files would be overwritten by checkout`, and the edit is intact. The
  other folders are still moved, and the command ends with an error status.

**As a command:** `git dep update`. It differs from the plain command in three ways:

- It stops, before it moves anything, where a folder that is on no branch is at a commit that no branch and
  no remote has. It names the folder and the command that puts the commit on a branch.
- It leaves a folder that is on a branch where it is, and names it. The folders beneath that folder are still
  put at the commits it records.
- It writes the settings last, so a folder that was checked out for the first time has them.

It also names a folder that git skipped because of an `update = none` setting, with the command that takes
the setting out.

Like the plain command, it puts back a folder that you moved on purpose and have not staged, such as an
upgrade in progress. Nothing is deleted, but the folder is at the recorded commit again.

## See where things stand

```
git status --short
git submodule status --recursive
```

- `git status --short` marks a folder that is at another commit with `M`, and a folder that holds a change
  somewhere beneath it with `m`.
- `git submodule status --recursive` lists every folder with its commit. A `-` in front marks a folder that
  is not checked out. A `+` marks one that is not at the recorded commit.
- `git -C lib/<name> status -sb` shows the folder's branch, or `HEAD (no branch)`.
- `git -C lib/<name> log HEAD --branches --not --remotes --oneline` lists the commits that only this
  computer has.

Two commands look at every folder, at every depth. Each prints nothing when there is nothing to report:

```
git submodule foreach --quiet --recursive 'test -z "$(git rev-list -n 1 HEAD --not --branches --remotes)" || echo "a commit on no branch in $displaypath"'
git submodule foreach --quiet --recursive 'git diff --quiet --ignore-submodules HEAD || echo "uncommitted changes in $displaypath"'
```

The first names each folder whose current commit is on no branch and on no remote. An update would leave
that commit behind. Put it on a branch first: `git -C <folder> switch -c <branch>`. The second names each
folder that holds an uncommitted change. That is work in progress, and nothing is wrong with it.

**As a command:** `git dep status`. It names each folder that is not checked out, is on a branch, is not at
the recorded commit, is at a commit that no branch and no remote has, holds commits that no remote has, or
holds uncommitted changes. A file that git does not track counts as an uncommitted change there. It counts
the folders. It changes nothing and fetches nothing.

## Add a dependency

```
git submodule add -b <branch> <url> lib/<name>
git -C lib/<name> switch --detach
git -C lib/<name> submodule update --init --recursive
git add lib/<name>
```

Then run the last settings command. Add the dependency's remappings to `foundry.toml` and to `wake.toml`,
each under a prefix of its own, such as `@<name>/`. Commit.

- `-b <branch>` is for a repository of your own, which follows a branch. It writes a `branch` line in
  `.gitmodules`. Check the name first: for a branch the remote does not have, git stops only after it has
  cloned. "What can go wrong" has the way out.
- `git submodule add` leaves the new folder on a branch, where every folder from a clone is on none. The
  second command takes it off, at the same commit.
- For a library at a release tag, leave `-b <branch>` out, and type `git -C lib/<name> checkout <tag>` in
  place of the second command. That also leaves the folder on no branch.
- The third command is typed for the folder itself, with `-C`. After the checkout of a tag,
  `git submodule update` typed for the repository puts the folder back at the commit that
  `git submodule add` chose.

**As a command:** `git dep add <url> [<name>] [--branch <branch> | --tag <tag>]`. It runs the commands above,
then writes the settings. It differs from them in three ways:

- Left out, `<name>` is the last part of the url, without `.git`.
- It asks the remote for the branch or the tag before it changes anything, and stops when the remote has none
  of that name. It does not ask about a url that starts with `./` or `../`: git reads such a url from the
  repository's own remote.
- Its last line says what is left to you: the remappings and the commit.

## Remove a dependency

First look for work that only this computer has, in the folder and in every folder beneath it:

```
git -C lib/<name> status --short; git -C lib/<name> log HEAD --branches --not --remotes --oneline; git -C lib/<name> stash list
git -C lib/<name> submodule foreach --quiet --recursive 'git status --short; git log HEAD --branches --not --remotes --oneline; git stash list'
```

Both print nothing when there is none: no uncommitted change, no commit that no remote has, no stash. Then:

```
git rm lib/<name>
rm -rf .git/modules/lib/<name>
git config --remove-section submodule.lib/<name>
```

Remove the dependency's remappings from `foundry.toml` and from `wake.toml`. Commit.

- `git rm` deletes the folder and its entry in `.gitmodules`. It refuses while the folder, or a folder
  beneath it, holds an uncommitted change or is not at its recorded commit.
- `git rm` also refuses a dependency that was added and is not committed yet, with
  `the following file has changes staged in the index`. To undo such an add, type `git rm -f lib/<name>` in
  place of the first command.
- `git rm` does not look at branches or stashes. The `rm -rf` deletes the repository git keeps for the
  dependency, and theirs beneath it, with every branch and stash in them. That is why the look comes first.
- The two commands of the look reach the folders that are checked out. `.git/modules/lib/<name>` can also
  hold the repository of a folder that is gone, such as one that an earlier version of the dependency had.
- The last command deletes the line git leaves in `.git/config`. For a folder that is not checked out, git
  has taken the line out already, and the command ends with `no such section`.
- The last two commands use the dependency's name in `.gitmodules`. It differs from the folder only where
  the folder was moved with `git mv`.

**As a command:** `git dep remove <name>`. It makes the look itself, and stops before it removes anything
where it finds work that only this computer has. It names each folder that holds some, with the command that
lists it. It also looks at each repository git keeps for a folder that is gone. Then it runs the three
commands, and its last line says what is left to you: the remappings and the commit. It runs `git rm` as it
is, without `-f`: where git refuses, nothing is removed.

## Upgrade a dependency

To a release tag:

```
git -C lib/<name> fetch --tags
git -C lib/<name> checkout <tag>
git -C lib/<name> submodule update --init --recursive
git add lib/<name>
```

The third command brings the folders beneath `lib/<name>` to the commits the new version records, and checks
out one that the new version adds. Run the last settings command when it added one. Commit.

Give a tag or a commit where `<tag>` stands, never the name of a branch. A folder from a clone has a branch of
its own, named as the remote's main branch is, and left at the remote's newest commit of the day of the clone.
`git -C lib/<name> checkout main` puts the folder on that branch, at that older commit. For the remote's
newest commit, type `git -C lib/<name> checkout --detach origin/main`.

To the newest commit of the branch it follows, for a dependency with a `branch` line in `.gitmodules`:

```
git submodule update --remote lib/<name>
git -C lib/<name> submodule update --init --recursive
git add lib/<name>
```

**As a command:** `git dep upgrade <name> <version>`, where `<version>` is a tag or a commit, and
`git dep upgrade <name>` for the newest commit of the branch the dependency follows. It runs the commands
above, then writes the settings. It differs from them in these ways:

- It stops, before it fetches or moves anything, where the folder or a folder beneath it is on no branch, at
  a commit that no branch and no remote has. It names the folder and the command that puts the commit on a
  branch.
- It stops where `<version>` names a branch of the folder's own, and names the command for the remote's
  branch. It stops where the folder has no tag and no commit of that name after the fetch.
- With no version, it stops for a dependency that has no `branch` line. git alone would move that one to the
  newest commit of its remote's default branch.
- It leaves the dependency's folder on no branch. It leaves a folder beneath it that is on a branch where it
  is, and names it.
- Its last line says whether a commit is left to you. After it, it names a folder beneath the dependency that
  git skipped because of an `update = none` setting.

## A nested folder that a new version no longer uses

When an upgrade moves `lib/<name>` to a version that no longer has one of its own dependencies, git leaves
that folder behind. It prints `warning: unable to rmdir 'lib/<gone>': Directory not empty`, and
`git -C lib/<name> status` then lists `lib/<gone>/` as untracked. Nothing uses the folder any more.

First look for work that only this computer has in it:

```
git -C lib/<name>/lib/<gone> status --short; git -C lib/<name>/lib/<gone> log HEAD --branches --not --remotes --oneline; git -C lib/<name>/lib/<gone> stash list
```

It prints nothing when there is none. Then:

```
git -C lib/<name> clean -ffd -- lib/<gone>
rm -rf .git/modules/lib/<name>/modules/lib/<gone>
git -C lib/<name> config --remove-section submodule.lib/<gone>
```

- The first command deletes the folder. It needs both `f`s: with one, git leaves a folder that is a
  repository where it is, and says nothing.
- The second deletes the repository git keeps for it, with every branch and stash in it.
- The third deletes the lines git leaves in the settings of `lib/<name>`.

## Work in a dependency

**Start.** On a new branch, at the commit the repository records:

```
git -C lib/<name> switch -c <branch>
```

On a branch that exists on the remote:

```
git -C lib/<name> fetch
git -C lib/<name> switch <branch>
git -C lib/<name> submodule update --init --recursive
```

Without the fetch, git answers `invalid reference` for a branch it has not seen. The third command brings the
folders beneath `lib/<name>` to the commits that branch records.

**Build this repository against the work.** There is nothing to do. The build reads `lib/<name>` as it is.

**Take newer upstream work into your branch,** for a dependency with a `branch` line in `.gitmodules`:

```
git submodule update --remote --merge lib/<name>
git -C lib/<name> submodule update --init --recursive
```

The first merges the newest commit of the branch the dependency follows into the branch you are on. The
folder stays on your branch. The second moves the folders beneath it to the commits the merge records.

**Record the work in this repository.** Commit everything in the folder first: a change that is not
committed is not recorded, although the build has been using it.

```
git -C lib/<name> push -u origin <branch>
git add lib/<name>
git commit
git push
```

git refuses the last push while the commit recorded for `lib/<name>` is on no remote. Its message begins
`The following submodule paths contain changes that can not be found on any remote`.

When the branch has been merged upstream, upgrade the dependency to the newest commit of the branch it
follows, as above.

## A shared dependency, in every place that has it

Make the change in `lib/<shared>`, on a branch, and push it:

```
git -C lib/<shared> switch -c <branch>
git -C lib/<shared> commit
git -C lib/<shared> push -u origin <branch>
```

Then in each `<name>` that has `<shared>`, with `lib/<name>` on a branch. `<commit>` is the commit
`lib/<shared>` is now at:

```
git -C lib/<name>/lib/<shared> fetch origin
git -C lib/<name>/lib/<shared> checkout <commit>
git -C lib/<name>/lib/<shared> submodule update --init --recursive
git -C lib/<name> add lib/<shared>
git -C lib/<name> commit
git -C lib/<name> push -u origin <branch>
```

Then in this repository:

```
git add lib/<shared> lib/<name>
git commit
git push
```

There are two working copies of `<shared>` in the tree: `lib/<shared>` and `lib/<name>/lib/<shared>`. Edit
only the first. The second only follows, by the checkout above.

## A merge where both branches moved a dependency

This holds for a merge in the repository, and for a merge inside a dependency whose branches both moved a
folder beneath it.

- **One commit follows the other.** git takes the later one, and prints
  `Note: Fast-forwarding submodule lib/<name>`. The folder stays at the old commit until the update command.
- **Neither follows the other.** git stops with `CONFLICT (submodule): Merge conflict in lib/<name>`. Choose
  the commit to record, then:

```
git -C lib/<name> checkout <commit>
git add lib/<name>
git commit
```

For a merge inside `lib/<name>`, where the folder in conflict is `lib/<name>/lib/<shared>`, the same three
commands are `git -C lib/<name>/lib/<shared> checkout <commit>`, `git -C lib/<name> add lib/<shared>` and
`git -C lib/<name> commit`.

## Fetch a dependency's deployment tags

```
git -C lib/<name> fetch origin '+refs/tags/deploy/*:refs/tags/deploy/*'
```

The update command does not fetch a tag that was made after the clone. This command does. It also replaces a
local deployment tag with the remote's tag of the same name, which `git fetch --tags` refuses to do.

## What can go wrong

| What you see | What it means | What to do |
|---|---|---|
| The build uses old code after a pull | The folders are still at the old commits | The update command |
| A commit you made in a folder is gone after an update | It was made on no branch | `git -C lib/<name> reflog` finds it. `git -C lib/<name> switch -c <branch> <commit>` puts it on a branch |
| A folder you were working in is on no branch after an update | The repository records another commit than the branch's newest | `git -C lib/<name> switch <branch>` |
| `git push` ends with `changes that can not be found on any remote` | The repository records a dependency commit that is not pushed | Push that dependency's branch, then push again |
| `git pull` prints `Could not access submodule` | The pull brought in a dependency whose folder is not there yet | The update command, then the last settings command |
| A folder is empty, and `git submodule status` shows a `-` in front of it | It is not checked out | The update command |
| After an upgrade, git warns `unable to rmdir`, and a folder inside the dependency is listed as untracked | The new version no longer uses that folder | "A nested folder that a new version no longer uses" |
| `git submodule add -b <branch>` ends with `is not a commit and a branch '<branch>' cannot be created from it` | The remote has no such branch. git has cloned already: it leaves `lib/<name>`, holding nothing but `.git`, and `.git/modules/lib/<name>`. Typed again with the right branch, the add stages the folder as it is, with no file in it | `rm -rf lib/<name> .git/modules/lib/<name>`, then add again |
| `git rm lib/<name>` ends with `the following file has changes staged in the index` | The dependency was added, or its new commit was staged, and that is not committed | To undo an add: `git rm -f lib/<name>`, then the other two commands of "Remove a dependency" |
| After `git -C lib/<name> checkout main`, the folder is on a branch, at an older commit | That is the folder's own branch, left where the remote was on the day of the clone | `git -C lib/<name> checkout --detach origin/main` |
| A merge stops with `Failed to merge submodule lib/<name> (not checked out)` | The folder is empty | The update command, then merge again |
| A merge stops with `Failed to merge submodule lib/<name> (commits don't follow merge-base)`, although one commit follows the other | Seen once on git 2.43, where the folder's repository held commit-graph files. What sets it off is not known | `git -c core.commitGraph=false merge <branch>` merged it |
| A branch switch discarded an edit inside `lib/` | `submodule.recurse` is set to `true` on this computer | Take the setting out. `git config --show-scope --show-origin --get-regexp '^(push\.recursesubmodules\|submodule\.recurse)$'` lists each file that sets it or the push check, in the order git reads them |

## A clone that `yarn dep` managed

`yarn dep` is gone from bao-base. It checked out only the folders the build reads, and wrote an
`update = none` setting for each of the others. git skips those folders: the update command prints
`Skipping submodule` and leaves them empty.

An older bao-base, such as the copy inside a dependency, still has `yarn dep`. Do not run it in a clone set
up as this page describes: its `sync` leaves only the folders the build reads checked out.

Take the settings out, once:

```
find .git -name config -type f | while read -r f; do git config --file "$f" --name-only --get-regexp '^submodule\..*\.update$' '^none$' | while read -r key; do git config --file "$f" --unset "$key"; done; done
```

Then follow "After a pull, a merge or a branch switch", and write the settings.
