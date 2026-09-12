#!/usr/bin/env node
// pinned-pragma: every deployable declaration in a Solidity source pins one compiler version.
//
// A deployable declaration is a contract that is not abstract, or a library with a public or external
// function. A library of internal functions is compiled into the code that uses it and is never deployed on
// its own, and interfaces and abstract contracts are never deployed, so those may keep a version range. A
// pinned pragma names one exact version, `0.8.30` or `=0.8.30`; anything looser leaves the choice of compiler
// to whichever versions a machine has installed.
//
// The verdict comes from source text parsed by @solidity-parser/parser (the parser solhint and
// prettier-plugin-solidity are built on), never from a build: what a build produces depends on the compilers
// installed, and this check's verdict must not. bin/validate runs it before its build.
//
// Usage: node pinned-pragma.js [--ignore <file>]... [<root>...]      (roots default to src)
//
// `--ignore` carries a `pragma` entry from .validate-ignore: that file is exempt and reported as such, and an
// entry for a file that passes anyway is reported as stale and fails. A file that does not parse fails
// whether or not it is ignored.
//
// Exit 0 when every deployable declaration pins one version; 1 otherwise; 2 for a malformed command line.
"use strict";

const fs = require("fs");
const path = require("path");
const parser = require("@solidity-parser/parser");

const EXACT_VERSION = /^=?\s*\d+\.\d+\.\d+$/;

const paint = (code) => (text) => (process.stdout.isTTY ? `\x1b[${code}m${text}\x1b[0m` : text);
const red = paint("31");
const dim = paint("2");
const green = paint("32");

function solidityFiles(root) {
  return fs.readdirSync(root, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(root, entry.name);
    if (entry.isDirectory()) {
      return solidityFiles(full);
    }
    return entry.isFile() && entry.name.endsWith(".sol") ? [full] : [];
  });
}

function deployable(declaration) {
  if (declaration.kind === "contract") {
    return true;
  }
  return (
    declaration.kind === "library" &&
    declaration.subNodes.some(
      (node) => node.type === "FunctionDefinition" && ["public", "external"].includes(node.visibility),
    )
  );
}

// What is wrong with one source text: `unreadable` when it does not parse, otherwise one entry in `problems`
// per deployable declaration and loose version pragma. Both empty means the file passes.
function examine(text) {
  let ast;
  try {
    ast = parser.parse(text);
  } catch (error) {
    if (error instanceof parser.ParserError) {
      const [first] = error.errors;
      return { unreadable: `${first.message} (line ${first.line}, column ${first.column})`, problems: [] };
    }
    throw error;
  }
  const versions = ast.children
    .filter((node) => node.type === "PragmaDirective" && node.name === "solidity")
    .map((node) => node.value);
  const loose = versions.filter((value) => !EXACT_VERSION.test(value));
  const problems = [];
  for (const declaration of ast.children) {
    if (declaration.type !== "ContractDefinition" || !deployable(declaration)) {
      continue;
    }
    const subject = `deployable ${declaration.kind} '${declaration.name}'`;
    if (versions.length === 0) {
      problems.push(`${subject} has no solidity pragma`);
    }
    for (const value of loose) {
      problems.push(`${subject} has pragma '${value}', which allows more than one compiler version`);
    }
  }
  return { unreadable: null, problems };
}

function main(argv) {
  const ignored = new Set();
  const roots = [];
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] !== "--ignore") {
      roots.push(argv[index]);
      continue;
    }
    if (index + 1 === argv.length) {
      console.error("pinned-pragma: --ignore needs a file");
      return 2;
    }
    index += 1;
    ignored.add(path.normalize(argv[index]));
  }
  if (roots.length === 0) {
    roots.push("src");
  }

  const files = roots.flatMap(solidityFiles).sort();
  let failed = false;
  for (const file of files) {
    const { unreadable, problems } = examine(fs.readFileSync(file, "utf8"));
    if (unreadable) {
      console.log(red(`✗ ${file}: does not parse: ${unreadable}`));
      failed = true;
      continue;
    }
    if (ignored.has(path.normalize(file))) {
      if (problems.length === 0) {
        console.log(
          red(`✗ stale .validate-ignore entry: pragma "${file}" — check passes, remove from .validate-ignore`),
        );
        failed = true;
      } else {
        console.log(dim(`⚠ ${file}: pragma check ignored via .validate-ignore`));
      }
      continue;
    }
    for (const problem of problems) {
      console.log(red(`✗ ${file}: ${problem}`));
      failed = true;
    }
  }

  if (failed) {
    console.log(red("deployable code must pin one exact compiler version, for example: pragma solidity 0.8.30;"));
    return 1;
  }
  console.log(green(`✓ every deployable contract and library pins one compiler version (${files.length} files)`));
  return 0;
}

process.exitCode = main(process.argv.slice(2));
