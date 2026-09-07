### Status

Reported upstream as [crytic-compile#690](https://github.com/crytic/crytic-compile/issues/690) on
24 June 2026, with a fix proposed in [PR#691](https://github.com/crytic/crytic-compile/pull/691).
Both were still open, with no maintainer response, when checked on 7 September 2026; the code on
`master` is unchanged.

### Component

crytic-compile (reached through Slither)

### What version are you on?

crytic-compile 0.3.10, as pinned by `bin/slither/uv.lock` alongside slither-analyzer 0.11.3.
The reproduction below was run with slither 0.11.2; the `is_dependency` code quoted is identical on
crytic-compile `master`, so the version is not what decides it.

### What command(s) is the bug in?

`slither .` — and so `yarn slither`.

### Operating System

Linux

### Describe the bug

`Foundry.is_dependency()` decides whether a source file is third-party by looking for a path
component named `lib` **anywhere in the absolute path**. A project checked out *underneath* a
directory called `lib` — which is what every Foundry git submodule is — therefore has all of its own
sources classified as dependencies, and every dependency-aware detector skips them.

Nothing is reported. Slither still prints findings from detectors that do not consult
`is_dependency`, so the run does not look suppressed: it looks clean.

The result is a local-versus-CI divergence that points the wrong way. A developer running
`yarn slither` inside `<consumer>/lib/bao-base` gets a pass; CI, which checks the same repository out
at its own root, runs the detectors properly and fails. The tool is quietest exactly where someone is
working on the code.

## Minimal reproduction

Two copies of one project, differing only in the directory they sit under.

```bash
mkdir -p repro/outer/lib/proj/src repro/plain/proj/src && cd repro

cat > outer/lib/proj/foundry.toml <<'EOF'
[profile.default]
src = "src"
out = "out"
EOF

cat > outer/lib/proj/src/Dead.sol <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Dead {
    function neverCalled() internal pure returns (uint256) {
        return 1;
    }
}
EOF

cp outer/lib/proj/foundry.toml plain/proj/foundry.toml
cp outer/lib/proj/src/Dead.sol  plain/proj/src/Dead.sol

(cd outer/lib/proj && slither .)   # 1 result  — dead-code MISSING
(cd plain/proj    && slither .)    # 2 results — dead-code reported
```

Under `lib/`:

```
INFO:Slither:. analyzed (1 contracts with 100 detectors), 1 result(s) found
```

Outside it, from the same source:

```
Dead.neverCalled() (src/Dead.sol#5-7) is never used and should be removed
INFO:Slither:. analyzed (1 contracts with 100 detectors), 2 result(s) found
```

The one finding common to both is the `solc-version` detector, which does not consult
`is_dependency`. That is what makes the failure quiet rather than obvious — output is still produced.

## Cause

`crytic_compile/platform/foundry.py`:

```python
def is_dependency(self, path: str) -> bool:
    if path in self._cached_dependencies:
        return self._cached_dependencies[path]
    path_parts = Path(path).parts
    config = self._get_config()
    libs_path = (config.libs_path if config else None) or []
    ret = (
        "lib" in path_parts
        or "node_modules" in path_parts
        or any(lib in path_parts for lib in libs_path)
    )
    self._cached_dependencies[path] = ret
    return ret
```

`path` is absolute and `Path(path).parts` spans the whole filesystem path, so the test cannot tell
`<project>/lib/<dependency>` — which it means — from `<parent>/lib/<project>/src`, which it does not.
Any ancestor directory named `lib` or `node_modules` is enough.

### Expected behaviour

A project's own sources are analysed whatever directory the project happens to be checked out under.
Only `lib`/`node_modules` directories *within* the project mark dependencies.

The fix proposed in PR#691 classifies the path relative to `self._project_root` before looking for
those components, which is the smallest change that distinguishes the two cases.

### Actual behaviour

Every source file of a project nested under a `lib/` ancestor is treated as a dependency, and every
dependency-aware detector silently skips it.

## Impact

bao-base is consumed as a git submodule at `<consumer>/lib/bao-base`, so this is the normal way it is
worked on — the repository root is only ever *not* under a `lib/` component in CI. Local `yarn slither`
runs are therefore systematically weaker than CI, in a direction no one would guess from the output.

It cost real time here: local runs reported `0 result(s) found` for the OpenZeppelin 5.7.0 compat work
and were read as clean, while CI reported two `dead-code` findings against the same commit. The
divergence was initially attributed to the code rather than the tool.

`--filter-paths` cannot be used to work around it — the mechanism is the opposite of a filter, and
`bin/slither/run.sh` already uses an anchored `--filter-paths` in place of `--exclude-dependencies`
for a related reason. Until PR#691 lands, CI is the only trustworthy slither result for this
repository, and a local pass proves nothing.
