#!/usr/bin/env node
"use strict";

const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

function isTermux() {
  const prefix = process.env.PREFIX || "";
  return (
    prefix.includes("com.termux") ||
    fs.existsSync("/data/data/com.termux/files/usr")
  );
}

function main() {
  const args = process.argv.slice(2);
  if (args.includes("-h") || args.includes("--help")) {
    console.log(`bruk-cursor-termux (bct): install Cursor Agent CLI on this Termux (Android ARM64)

Tuned for one Termux setup (Bionic, tree-sitter stubs, no global LD_LIBRARY_PATH).
Public, but not a generic “any device” installer.

Usage:
  npm i -g bruk-cursor-termux
  bruk-cursor-termux
  bct --patch-only
  bruk-cursor-termux --no-deps

After install:
  hash -r
  source ~/.bashrc
  NO_OPEN_BROWSER=1 cursor-agent login
`);
    process.exit(0);
  }

  if (!isTermux()) {
    console.error(
      "bruk-cursor-termux must run inside Termux on Android ARM64.\n" +
        "Install Termux from F-Droid, then: npm i -g bruk-cursor-termux && bruk-cursor-termux"
    );
    process.exit(1);
  }

  if (process.arch !== "arm64") {
    console.error(`Need ARM64 Termux (got process.arch=${process.arch}).`);
    process.exit(1);
  }

  const script = path.join(__dirname, "..", "scripts", "install.sh");
  if (!fs.existsSync(script)) {
    console.error("Missing scripts/install.sh in package.");
    process.exit(1);
  }

  const child = spawn("bash", [script, ...args], {
    stdio: "inherit",
    env: process.env,
  });
  child.on("exit", (code, signal) => {
    if (signal) process.kill(process.pid, signal);
    process.exit(code ?? 1);
  });
}

main();
