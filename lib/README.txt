The bao-base directory here is a symbolic link to the containing bao-base directory.

This results in a circular structure which means that it doesn't matter what project
the files are called from (either from one that has a dependency on bao-base or from
bao-base itself).

This allows files here to reference themselves in the same way that a containing project
would.

It also allows content of, e.g. package.json, to be copied from bao-base without change.

This simplifies maintenance for a small, albeit hacky, overheadof having this symbolic link.

*** All manner of things will break if the symbolic link is removed ***
