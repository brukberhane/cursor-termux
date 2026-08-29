# bruk-cursor-termux

Unofficial installer for the official **Cursor Agent CLI** on **this Termux** (Android aarch64 / Bionic).

Public npm/git, written for one machine’s needs (tree-sitter stubs, Termux-X11-safe env). Not a generic “any Android” product. Not affiliated with Anysphere / Cursor. The agent binary is proprietary; this repo only ships Termux glue.

Inspired by [cursor-termux](https://github.com/Afnanksalal/cursor-termux) (MIT). Extra patches that 1.0.2 does not apply:

| Failure | What we do |
|--------|------------|
| Bundled `node` / `rg` are glibc ELFs | Symlink Termux `node` and `rg` |
| Termux looks like musl → fake file-service musl module | Preload spoofs glibc + stubs file-service |
| `node_sqlite3` glibc addon | Rebuild sqlite3 for Bionic when possible |
| Merkle native `.node` crash | Patch failure path + `dlopen` stub |
| Agent `2026.08.25+` `require("tree-sitter")` | JS Parser stubs (`tree-sitter`, `tree-sitter-bash`) |
| Global `LD_LIBRARY_PATH` in `~/.bashrc` | **Not set.** Launcher-only so Termux-X11 is untouched |

## Install (fresh Termux)

```bash
pkg update
pkg install nodejs-lts clang make python git curl ripgrep pkg-config binutils
npm install -g bruk-cursor-termux
bruk-cursor-termux
hash -r
source ~/.bashrc
NO_OPEN_BROWSER=1 cursor-agent login
```

From this repo without npm publish:

```bash
cd ~/projects/nodejs/cursor-termux   # or clone
npm install -g .
bruk-cursor-termux
```

## Commands

| Command | Meaning |
|---------|---------|
| `bruk-cursor-termux` | Wipe previous agent tree, download current CLI, patch, smoke-test |
| `bct` | Same binary |
| `bct --patch-only` | Re-apply preload / stubs / launcher / PATH-only bashrc on the newest version |
| `bruk-cursor-termux --no-deps` | Skip `pkg update` / `pkg install` |

Then: `cursor-agent about`, `cursor-agent --help`.

`--help` works without a global `LD_LIBRARY_PATH`. If an old shell still has that export: `unset LD_LIBRARY_PATH` or open a new session.

## After `cursor-agent update`

New version dir has **no** patches:

```bash
bct --patch-only
```

## What install does

1. Termux + ARM64 check  
2. `pkg install` build/runtime deps  
3. Cleanup old `~/.local/share/cursor-agent` (unlink `node`/`rg` first so Termux node is not deleted)  
4. Parse version from `https://cursor.com/install`  
5. Download `android/arm64` tarball if present, else `linux/arm64`  
6. Symlink Termux `node` + `rg`  
7. TLS certs + empty glibc-named `.so` stubs under `$PREFIX/lib` (not via bashrc)  
8. sqlite3 node-gyp rebuild (best-effort)  
9. Merkle `index.js` patch  
10. Copy `lib/termux-preload.js`, write `~/.local/bin/cursor-agent`, PATH-only bashrc block  
11. Write tree-sitter JS stubs; preload recreates them on every launch  
12. Smoke: `env -u LD_LIBRARY_PATH cursor-agent --help`

## Layout

```
~/.local/bin/cursor-agent
~/.local/share/cursor-agent/termux-preload.js
~/.local/share/cursor-agent/versions/<YYYY.MM.DD-sha>/
```

## Environment

| Variable | Where | Why |
|----------|--------|-----|
| `PATH` (`~/.local/bin`) | `~/.bashrc` marker | `cursor-agent` on PATH |
| `LD_LIBRARY_PATH=$PREFIX/lib` | **launcher only** | agent / leftover .so |
| `CURSOR_AGENT_VERSION_DIR` | launcher | preload finds the tree |
| `NODE_OPTIONS=--require=preload` | launcher | workers inherit shims |

Do not export `LD_LIBRARY_PATH` from bashrc — it breaks Termux-X11.

## Limits

- tree-sitter is a JS stub; shell AST analysis is weaker  
- file-service / Merkle natives are stubbed  
- sqlite rebuild can fail; agent still runs  
- ARM64 Termux only  

## License

MIT for this glue. Cursor Agent remains Cursor’s. See `NOTICE`.
