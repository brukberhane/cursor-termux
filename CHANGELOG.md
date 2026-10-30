# Changelog

## 1.0.2

- Install/upgrade `libc++` with `nodejs-lts`. Node 24 against NDK r29 dies with `cannot locate symbol "_ZNSt6__ndk113__hash_memoryEPKvm"` and takes npm/pnpm with it
- Recover that linker break at start of install / `--patch-only` (`pkg install libc++ nodejs-lts`)
- Keep GNU `.so` stubs under `~/.local/share/cursor-agent/lib`, not `$PREFIX/lib` (Bionic default search was poisoning Termux node)
- Merkle stub matches agent `2026.10+` loader (`if(!u){const t={...};throw new Error(r)}`) and `--patch-only` reapplies it
- Preload stubs glibc `node_sqlite3.node` (Android linker rejects VERNEED `libstdc++.so.6`); `--help` no longer dies at import

## 1.0.1

- Skip `cp` when npm global preload is already `PRELOAD_SRC` (`bct --patch-only` no longer dies with "same file")

## 1.0.0

- First public package (`bruk-cursor-termux` / `bct`)
- Tree-sitter + tree-sitter-bash JS stubs for agent 2026.08.25+
- Launcher-only `LD_LIBRARY_PATH` (no bashrc leak into Termux-X11)
- Merkle patch, sqlite Bionic rebuild, file-service musl spoof (cursor-termux-style)
