#!/usr/bin/env node
"use strict";
if (process.env.npm_config_global === "true" || process.env.npm_config_global === "") {
  console.log(`
bruk-cursor-termux installed.

  bruk-cursor-termux          # fresh Cursor Agent + Termux patches
  bct --patch-only            # after cursor-agent update

Need clang/make/python/nodejs-lts first:
  pkg install nodejs-lts clang make python git curl ripgrep
`);
}
