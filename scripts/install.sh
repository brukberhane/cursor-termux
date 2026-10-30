#!/data/data/com.termux/files/usr/bin/bash
# bruk-cursor-termux: Cursor Agent CLI installer for this Termux (Android aarch64).
# Fresh download + Bionic glue (file-service, merkle, sqlite, tree-sitter stubs).
#
# Usage:
#   bruk-cursor-termux                 # wipe + reinstall + patch
#   bct --patch-only                   # patch existing tree
#   bruk-cursor-termux --no-deps       # skip pkg update
set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME="${HOME:-/data/data/com.termux/files/home}"
INSTALL_ROOT="${HOME}/.local/share/cursor-agent"
BIN_DIR="${HOME}/.local/bin"
LAUNCHER="${BIN_DIR}/cursor-agent"
PRELOAD_DST="${INSTALL_ROOT}/termux-preload.js"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PRELOAD_SRC="${PKG_ROOT}/lib/termux-preload.js"

PATCH_ONLY=0
NO_DEPS=0
for arg in "$@"; do
  case "$arg" in
    --patch-only) PATCH_ONLY=1 ;;
    --no-deps) NO_DEPS=1 ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
  esac
done

BLUE=$'\033[0;34m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
RED=$'\033[0;31m'
NC=$'\033[0m'
step() { printf '%s->%s %s\n' "$BLUE" "$NC" "$*"; }
ok() { printf '%sok%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s!%s %s\n' "$YELLOW" "$NC" "$*"; }
die() { printf '%serror%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

SHIM_DIR="${INSTALL_ROOT}/lib"

node_version() {
  node -e 'process.stdout.write(process.version)' 2>/dev/null || true
}

ensure_node_ok() {
  local ver err
  ver="$(node_version)"
  if [[ "$ver" == v* ]]; then
    return 0
  fi
  err="$(node -e 'process.stdout.write(process.version)' 2>&1 || true)"
  warn "node not runnable: ${err:-missing}"
  step "Upgrading libc++ (nodejs-lts 24 needs NDK r30; r29 missing __hash_memory)..."
  mkdir -p "$PREFIX/etc/apt"
  if [[ ! -s "$PREFIX/etc/apt/sources.list" ]]; then
    printf 'deb https://packages.termux.dev/apt/termux-main stable main\n' > "$PREFIX/etc/apt/sources.list"
  fi
  pkg update -y
  pkg install -y libc++ nodejs-lts
  ver="$(node_version)"
  [[ "$ver" == v* ]] || die "node still broken after libc++ upgrade. Run: pkg upgrade libc++ && pkg reinstall nodejs-lts
Last error: ${err:-unknown}"
  ok "node recovered ($ver)"
}

require_termux() {
  if [[ "${PREFIX}" != /data/data/com.termux/files/usr* ]] && [[ ! -d /data/data/com.termux/files/usr ]]; then
    die "Termux on Android only."
  fi
  local arch
  arch="$(uname -m)"
  [[ "$arch" == "aarch64" || "$arch" == "arm64" ]] || die "Need ARM64 (got: $arch)."
  [[ -f "$PRELOAD_SRC" ]] || die "Missing lib/termux-preload.js (broken package). Reinstall bruk-cursor-termux."
}

safe_rm_version_dir() {
  local dir="$1"
  [[ -e "$dir" || -L "$dir" ]] || return 0
  if [[ -d "$dir" && ! -L "$dir" ]]; then
    rm -f "$dir/node" "$dir/rg" 2>/dev/null || true
    rm -rf "$dir"
  else
    rm -f "$dir" 2>/dev/null || true
  fi
}

latest_version_dir() {
  local d
  d="$(ls -1d "${INSTALL_ROOT}/versions"/* 2>/dev/null | grep -v '\.old$' | sort | tail -n 1 || true)"
  [[ -n "$d" && -f "$d/index.js" ]] || return 1
  printf '%s\n' "$d"
}

# ---------------------------------------------------------------------------
# Enhanced preload: upstream cursor-termux glibc spoof + file-service/merkle
# stubs, plus tree-sitter / tree-sitter-bash JS Parser stubs (agent 2026.08.25+).
# ---------------------------------------------------------------------------
write_preload() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  [[ -f "$PRELOAD_SRC" ]] || die "Missing $PRELOAD_SRC"
  _cp_if_different "$PRELOAD_SRC" "$dest"
  node --check "$dest" || die "preload syntax check failed: $dest"
}

write_tree_sitter_stubs() {
  local version_dir="$1"
  [[ -d "$version_dir" ]] || die "version dir missing: $version_dir"
  node - "$version_dir" <<'NODE'
const fs = require("fs");
const path = require("path");
const versionDir = process.argv[2];
const root = path.join(versionDir, "node_modules");
const parserJs = [
  "function N(){var n={type:\"program\",text:\"\",startIndex:0,endIndex:0,startPosition:{row:0,column:0},endPosition:{row:0,column:0},childCount:0,children:[],namedChildCount:0,namedChildren:[],parent:null};",
  "n.child=function(){return null};n.namedChild=function(){return null};n.descendantsOfType=function(){return []};",
  "n.walk=function(){return{currentNode:n,gotoFirstChild:function(){return false},gotoNextSibling:function(){return false},gotoParent:function(){return false}}};",
  "n.toString=function(){return \"(program)\"};return n;}",
  "function Parser(){}",
  "Parser.prototype.setLanguage=function(l){this.language=l};",
  "Parser.prototype.getLanguage=function(){return this.language};",
  "Parser.prototype.parse=function(){return{rootNode:N(),delete:function(){}}};",
  "Parser.prototype.reset=function(){};",
  "Parser.Language={load:async function(){return {}}};",
  "function Query(){}",
  "Query.prototype.captures=function(){return []};",
  "Query.prototype.matches=function(){return []};",
  "Parser.Query=Query;",
  "module.exports=Parser;",
].join("\n");
for (const [name, body] of [
  ["tree-sitter", parserJs],
  ["tree-sitter-bash", 'module.exports={name:"bash"};\n'],
]) {
  const dir = path.join(root, name);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "package.json"), JSON.stringify({
    name, version: "0.0.0-termux-stub", main: "index.js",
  }));
  fs.writeFileSync(path.join(dir, "index.js"), body);
}
console.log("tree-sitter stubs -> " + root);
NODE
}

_cp_if_different() {
  local src="$1" dest="$2" src_r dest_r
  src_r="$(readlink -f "$src" 2>/dev/null || echo "$src")"
  dest_r="$(readlink -f "$dest" 2>/dev/null || echo "$dest")"
  [[ "$src_r" == "$dest_r" ]] && return 0
  cp -f "$src" "$dest"
}

sync_npm_preload() {
  local npm_root preload
  npm_root="$(npm root -g 2>/dev/null || true)"
  preload="${npm_root}/bruk-cursor-termux/lib/termux-preload.js"
  if [[ -f "$preload" && -f "$PRELOAD_SRC" ]]; then
    _cp_if_different "$PRELOAD_SRC" "$preload"
  fi
}

cleanup_previous() {
  step "Cleaning previous Cursor Agent / cursor-termux junk..."
  if command -v pkill >/dev/null 2>&1; then
    pkill -f "${INSTALL_ROOT}/versions/.*/index.js" 2>/dev/null || true
    pkill -f "/\\.local/bin/cursor-agent" 2>/dev/null || true
    sleep 0.3 2>/dev/null || true
  fi
  if [[ -d "${INSTALL_ROOT}/versions" ]]; then
    local d
    for d in "${INSTALL_ROOT}/versions"/* "${INSTALL_ROOT}/versions"/*.old; do
      [[ -e "$d" || -L "$d" ]] || continue
      safe_rm_version_dir "$d"
    done
  fi
  rm -f "${INSTALL_ROOT}/termux-preload.js" "${INSTALL_ROOT}/"*.bak "${INSTALL_ROOT}/"*.log 2>/dev/null || true
  rm -rf "${INSTALL_ROOT}/versions" "${INSTALL_ROOT}/.tmp" "${INSTALL_ROOT}/tmp" 2>/dev/null || true
  [[ -L "$LAUNCHER" || -f "$LAUNCHER" ]] && rm -f "$LAUNCHER"
  rm -rf "${HOME}/node_modules/@anysphere" 2>/dev/null || true
  if [[ -d "${HOME}/node_modules" ]] && [[ -z "$(ls -A "${HOME}/node_modules" 2>/dev/null || true)" ]]; then
    rmdir "${HOME}/node_modules" 2>/dev/null || true
  fi
  rm -rf "${HOME}/.cache/cursor-termux-stub.c" "${HOME}/.cache/cursor-termux" "${HOME}/empty-gnu-compat.c" 2>/dev/null || true
  if [[ -f "${HOME}/.bashrc" ]] && grep -q '# --- Cursor Agent (Termux) ---' "${HOME}/.bashrc" 2>/dev/null; then
    awk '
      $0=="# --- Cursor Agent (Termux) ---" {skip=1; next}
      $0=="# --- end Cursor Agent ---" {skip=0; next}
      !skip {print}
    ' "${HOME}/.bashrc" > "${HOME}/.bashrc.cursor-termux.tmp"
    mv "${HOME}/.bashrc.cursor-termux.tmp" "${HOME}/.bashrc"
  fi
  mkdir -p "${INSTALL_ROOT}/versions" "$BIN_DIR" "$HOME/tmp"
  ok "Cleanup done"
}

install_deps() {
  step "Installing Termux packages..."
  mkdir -p "$PREFIX/etc/apt"
  if [[ ! -s "$PREFIX/etc/apt/sources.list" ]]; then
    printf 'deb https://packages.termux.dev/apt/termux-main stable main\n' > "$PREFIX/etc/apt/sources.list"
  fi
  pkg update -y
  # libc++ must track nodejs-lts. Apt does not always upgrade libc++ 29 -> 30
  # when node is rebuilt against NDK r30, and node then dies with:
  #   cannot locate symbol "_ZNSt6__ndk113__hash_memoryEPKvm"
  pkg install -y libc++
  pkg install -y curl git nodejs-lts ripgrep python make clang pkg-config binutils openssl-tool tar which
  command -v node >/dev/null || die "node missing after pkg install"
  command -v rg >/dev/null || die "ripgrep missing after pkg install"
  ensure_node_ok
  ok "Dependencies ready (node $(node_version))"
}

detect_version() {
  step "Detecting current Cursor Agent version..."
  local installer ver
  installer="$(mktemp)"
  curl -fsSL "https://cursor.com/install" -o "$installer"
  ver="$(grep -E -o '[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[a-f0-9]{7,}' "$installer" | head -n 1 || true)"
  rm -f "$installer"
  [[ -n "$ver" ]] || die "Could not parse version from https://cursor.com/install"
  CURSOR_VERSION="$ver"
  ok "Version: $CURSOR_VERSION"
}

download_package() {
  local url tmp stage src
  VERSION_DIR="${INSTALL_ROOT}/versions/${CURSOR_VERSION}"
  mkdir -p "${INSTALL_ROOT}/versions"
  step "Downloading agent package..."
  url="https://downloads.cursor.com/lab/${CURSOR_VERSION}/linux/arm64/agent-cli-package.tar.gz"
  if curl -sfI "https://downloads.cursor.com/lab/${CURSOR_VERSION}/android/arm64/agent-cli-package.tar.gz" >/dev/null 2>&1; then
    url="https://downloads.cursor.com/lab/${CURSOR_VERSION}/android/arm64/agent-cli-package.tar.gz"
    ok "Using android/arm64 package"
  else
    ok "Using linux/arm64 package"
  fi
  tmp="$(mktemp -d)"
  stage="$(mktemp -d)"
  curl -fL --progress-bar "$url" | tar -xzf - -C "$tmp"
  if [[ -f "$tmp/index.js" ]]; then
    src="$tmp"
  else
    src="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    [[ -n "$src" ]] || die "Unexpected package layout"
  fi
  cp -a "$src"/. "$stage"/
  rm -f "$stage/node" "$stage/rg"
  safe_rm_version_dir "$VERSION_DIR"
  mv "$stage" "$VERSION_DIR"
  rm -rf "$tmp"
  [[ -f "$VERSION_DIR/index.js" ]] || die "index.js missing after extract"
  ok "Extracted to $VERSION_DIR"
}

swap_binaries() {
  step "Pointing bundled node/rg at Termux binaries..."
  rm -f "$VERSION_DIR/node" "$VERSION_DIR/rg"
  ln -s "$(command -v node)" "$VERSION_DIR/node"
  if command -v rg >/dev/null 2>&1; then
    ln -s "$(command -v rg)" "$VERSION_DIR/rg"
  fi
  ok "node -> $(command -v node)"
}

_scrub_prefix_gnu_stubs() {
  # Old installs dropped GNU-named stubs + glibc libgcc into $PREFIX/lib.
  # Bionic searches that dir by default, so Termux node/npm/pnpm can pick them up.
  local f p sz t
  for f in libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2; do
    p="$PREFIX/lib/$f"
    [[ -f "$p" && ! -L "$p" ]] || continue
    sz="$(stat -c %s "$p" 2>/dev/null || echo 0)"
    if [[ "$sz" -lt 20000 ]]; then
      rm -f "$p"
    fi
  done
  p="$PREFIX/lib/libgcc_s.so.1"
  if [[ -L "$p" ]]; then
    t="$(readlink -f "$p" 2>/dev/null || true)"
    if [[ "$t" == *"/glibc/lib/"* ]]; then
      rm -f "$p"
    fi
  fi
}

fix_tls_and_libs() {
  step "TLS + library shims..."
  mkdir -p "$PREFIX/etc/tls/certs" "$SHIM_DIR"
  if [[ -f "$PREFIX/etc/tls/cert.pem" ]]; then
    ln -sfn "$PREFIX/etc/tls/cert.pem" "$PREFIX/etc/tls/certs/cert.pem"
  fi
  _scrub_prefix_gnu_stubs
  # Harmless Bionic alias. Android resolves .node DT_NEEDED via node's RUNPATH
  # ($PREFIX/lib), not LD_LIBRARY_PATH — keep the name here AND in SHIM_DIR.
  if [[ -f "$PREFIX/lib/libc++_shared.so" ]]; then
    ln -sfn "$PREFIX/lib/libc++_shared.so" "$PREFIX/lib/libstdc++.so.6"
    ln -sfn "$PREFIX/lib/libc++_shared.so" "$PREFIX/lib/libstdc++.so"
    ln -sfn "$PREFIX/lib/libc++_shared.so" "$SHIM_DIR/libstdc++.so.6"
    ln -sfn "$PREFIX/lib/libc++_shared.so" "$SHIM_DIR/libstdc++.so"
  fi
  local stub_c="$HOME/.cache/cursor-termux/empty-gnu-compat.c"
  mkdir -p "$(dirname "$stub_c")"
  cat > "$stub_c" <<'C'
void __termux_gnu_compat_stub(void) {}
C
  clang -shared -fPIC -Wl,-soname,libm.so.6 "$stub_c" -o "$SHIM_DIR/libm.so.6" 2>/dev/null || true
  clang -shared -fPIC -Wl,-soname,libc.so.6 "$stub_c" -o "$SHIM_DIR/libc.so.6" 2>/dev/null || true
  clang -shared -fPIC -Wl,-soname,libpthread.so.0 "$stub_c" -o "$SHIM_DIR/libpthread.so.0" 2>/dev/null || true
  clang -shared -fPIC -Wl,-soname,libdl.so.2 "$stub_c" -o "$SHIM_DIR/libdl.so.2" 2>/dev/null || true
  if [[ -e "$PREFIX/glibc/lib/libgcc_s.so.1" ]]; then
    ln -sfn "$PREFIX/glibc/lib/libgcc_s.so.1" "$SHIM_DIR/libgcc_s.so.1"
  fi
  ok "Shims ready ($SHIM_DIR)"
}

rebuild_sqlite() {
  step "Rebuilding sqlite3 for Bionic (best effort)..."
  (
    cd "$VERSION_DIR"
    export LD_LIBRARY_PATH="${SHIM_DIR}:$PREFIX/lib:${LD_LIBRARY_PATH:-}"
    npm i sqlite3 --ignore-scripts >/dev/null 2>&1 || true
    if [[ ! -d node_modules/sqlite3 ]]; then
      warn "sqlite3 sources missing; skipping rebuild"
      return 0
    fi
    find node_modules/sqlite3 -type f \( -name '*.gyp' -o -name '*.gypi' \) -print0 2>/dev/null \
      | xargs -0 sed -i -E \
        -e 's/\bOS\s*==\s*"android"/OS=="never"/g' \
        -e 's/\btarget_os\s*==\s*"android"/target_os=="never"/g' \
        -e '/android_ndk_path/d' \
        -e '/ANDROID_/d' || true
    local jobs
    jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
    npx node-gyp configure -C node_modules/sqlite3 -- -DOS=linux -Dtarget_os=linux -Dandroid_ndk_path=/nonexistent >/dev/null 2>&1 || true
    make -C node_modules/sqlite3/build -j "$jobs" V=0 LINK=clang++ >/dev/null 2>&1 || true
    local built="node_modules/sqlite3/build/Release/node_sqlite3.node"
    if [[ -s "$built" ]]; then
      [[ -f node_sqlite3.node ]] && cp -f node_sqlite3.node "node_sqlite3.node.linux-gnu.bak" || true
      cp -f "$built" node_sqlite3.node
      [[ -d build ]] && cp -f "$built" build/node_sqlite3.node 2>/dev/null || true
      ok "sqlite3 rebuilt"
    else
      warn "sqlite3 rebuild failed; continuing"
    fi
  )
}

patch_merkle_stub() {
  step "Patching Merkle native binding -> JS stub..."
  local index_js="$VERSION_DIR/index.js"
  [[ -f "$index_js" ]] || die "index.js not found"
  cp -f "$index_js" "${index_js}.pre-merkle-bak"
  if node - "$index_js" <<'NODE'
const fs = require("fs");
const p = process.argv[2];
let src = fs.readFileSync(p, "utf8");
if (/if\(!(\w)\)\{\1=\{MerkleClient:class/.test(src)) {
  console.log("Merkle stub already present");
  process.exit(0);
}
const stub =
  '{MerkleClient:class{constructor(){}async build(){}async getTreeStructure(){return null}async getSimhash(){return[]}async getNumEmbeddableFiles(){return 0}async initWithRipgrepIgnore(){}},getParentProcessInfo:()=>null,MULTI_ROOT_ABSOLUTE_PATH:""}';

function apply(label, next) {
  fs.writeFileSync(p, next);
  console.log("Patched Merkle throw -> stub (" + label + ")");
  process.exit(0);
}

const exactFrom =
  "Original error: ${c&&c.stack?c.stack:c}`;throw new Error(n)}e.exports=u,e.exports.MerkleClient=u.MerkleClient";
if (src.includes(exactFrom)) {
  apply(
    "exact match",
    src.replace(
      exactFrom,
      "Original error: ${c&&c.stack?c.stack:c}`;u=" +
        stub +
        "}e.exports=u,e.exports.MerkleClient=u.MerkleClient"
    )
  );
}

// Nearest `if(!VAR){...throw new Error(X)}` before the native-binding throw.
// Agent 2026.10+ uses `if(!u){const t={platform map},e=...,r=\`Failed to load...\`;throw new Error(r)}`.
const marker = "Failed to load native binding for";
const mi = src.indexOf(marker);
if (mi >= 0) {
  const head = src.lastIndexOf("if(!", mi);
  if (head >= 0 && mi - head <= 4000) {
    const vm = src.slice(head, head + 24).match(/^if\(!(\w)\)\{/);
    const tm = vm ? src.slice(head).match(/throw new Error\(\w\)\}/) : null;
    if (vm && tm) {
      const end = head + tm.index + tm[0].length;
      apply(
        "near-marker " + vm[1],
        src.slice(0, head) + "if(!" + vm[1] + "){" + vm[1] + "=" + stub + "}" + src.slice(end)
      );
    }
  }
}

console.error("Could not locate Merkle failure path");
process.exit(2);
NODE
  then
    node --check "$index_js" || die "Patched index.js failed syntax check"
    ok "Merkle stub OK"
  else
    warn "Merkle patch skipped (pattern not found); preload dlopen stub still applies"
  fi
}

# Persist sessions mkdir `/tmp/cursor-agent-persist-<uid>` and set TMUX_TMPDIR to
# the same constant. Termux cannot create /tmp (EACCES). Point that constant at
# $PREFIX/tmp (Termux TMPDIR: .../files/usr/tmp). Short enough for the tmux
# socket path (sun_path max 108).
patch_persist_tmpdir() {
  step "Pointing persistent-session state off /tmp..."
  local index_js="$VERSION_DIR/index.js"
  local dest="${PREFIX}/tmp"
  [[ -f "$index_js" ]] || die "index.js not found"
  mkdir -p "$dest"
  local rc=0
  node - "$index_js" "$dest" <<'NODE' || rc=$?
const fs = require("fs");
const { spawnSync } = require("child_process");
const p = process.argv[2];
const dest = process.argv[3];
if (!dest || dest === "/tmp" || dest.startsWith("/tmp/")) {
  console.error("refusing persist dir under /tmp: " + dest);
  process.exit(1);
}
const src = fs.readFileSync(p, "utf8");
const mi = src.indexOf("TMUX_TMPDIR=");
if (mi < 0) {
  console.error("TMUX_TMPDIR assignment not found");
  process.exit(2);
}
const vm = src.slice(mi, mi + 64).match(/TMUX_TMPDIR=([A-Za-z_$][\w$]*)/);
if (!vm) {
  console.error("TMUX_TMPDIR is not a simple identifier");
  process.exit(2);
}
const name = vm[1];
const lit = JSON.stringify(dest);
const windowStart = Math.max(0, mi - 80000);
const region = src.slice(windowStart, mi);
const anchor = 'h="cursor-agent",' + name + "=";
let rel = region.lastIndexOf(anchor);
let abs;
let end;
if (rel >= 0) {
  abs = windowStart + rel + anchor.length;
  if (src[abs] !== '"') {
    console.error("persist tmp initializer is not a string");
    process.exit(2);
  }
  end = abs + 1;
  while (end < src.length) {
    if (src[end] === "\\") {
      end += 2;
      continue;
    }
    if (src[end] === '"') break;
    end++;
  }
  if (src[end] !== '"') {
    console.error("unterminated persist tmp string");
    process.exit(2);
  }
  const currentVal = JSON.parse(src.slice(abs, end + 1));
  if (currentVal === dest) {
    console.log("persist tmp already " + dest);
    process.exit(0);
  }
} else {
  const needle = name + '="/tmp"';
  rel = region.lastIndexOf(needle);
  if (rel < 0) {
    console.error("Could not find persist tmp root before TMUX_TMPDIR");
    process.exit(2);
  }
  const quoted = '"/tmp"';
  abs = windowStart + rel + needle.length - quoted.length;
  end = abs + quoted.length - 1;
  if (src.slice(abs, end + 1) !== quoted) {
    console.error("persist tmp root was not /tmp");
    process.exit(2);
  }
}
const next = src.slice(0, abs) + lit + src.slice(end + 1);
fs.writeFileSync(p, next);
const chk = spawnSync(process.execPath, ["--check", p], { encoding: "utf8" });
if (chk.status !== 0) {
  fs.writeFileSync(p, src);
  process.stderr.write(chk.stderr || chk.stdout || "");
  console.error("syntax check failed; restored index.js");
  process.exit(1);
}
console.log("persist tmp -> " + dest);
NODE
  if [[ "$rc" -eq 0 ]]; then
    ok "Persist state -> $dest"
  elif [[ "$rc" -eq 2 ]]; then
    warn "Persist /tmp patch skipped (pattern not found); sessions may still EACCES on /tmp"
  else
    die "Persist /tmp patch failed"
  fi
}

install_preload_and_launcher() {
  step "Installing preload + durable launcher..."
  mkdir -p "$BIN_DIR" "$HOME/tmp" "$INSTALL_ROOT"
  write_preload "$PRELOAD_DST"

  cat > "$LAUNCHER" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
PREFIX="\${PREFIX:-/data/data/com.termux/files/usr}"
HOME="\${HOME:-/data/data/com.termux/files/home}"
VERSION_DIR="${VERSION_DIR}"
if [[ ! -f "\${VERSION_DIR}/index.js" ]]; then
  echo "cursor-agent: missing agent tree at \${VERSION_DIR}" >&2
  echo "Run: bruk-cursor-termux   (or: bct)" >&2
  exit 1
fi
export CURSOR_AGENT_VERSION_DIR="\${VERSION_DIR}"
export NODE_PATH="\${VERSION_DIR}/node_modules\${NODE_PATH:+:\${NODE_PATH}}"
# Agent process only — never export this from bashrc (breaks Termux-X11).
# GNU-named stubs live under cursor-agent/lib, not \$PREFIX/lib (that path
# is on the default Bionic search and would break Termux node/npm/pnpm).
export LD_LIBRARY_PATH="\${HOME}/.local/share/cursor-agent/lib:\${PREFIX}/lib:\${LD_LIBRARY_PATH:-}"
# /tmp is not writable here. Persist state is patched onto \$PREFIX/tmp.
# TMPDIR covers os.tmpdir() (debug logs) when the parent left it unset or on /tmp.
mkdir -p "\${PREFIX}/tmp"
case "\${TMPDIR:-}" in
  ""|/tmp|/tmp/) export TMPDIR="\${PREFIX}/tmp" ;;
esac
PRELOAD="\${HOME}/.local/share/cursor-agent/termux-preload.js"
[[ -f "\${PRELOAD}" ]] || {
  echo "cursor-agent: missing termux-preload.js; re-run bruk-cursor-termux" >&2
  exit 1
}
case "\${NODE_OPTIONS:-}" in
  *termux-preload.js*) ;;
  *) export NODE_OPTIONS="--require=\${PRELOAD}\${NODE_OPTIONS:+ \${NODE_OPTIONS}}" ;;
esac
exec "\${PREFIX}/bin/node" -r "\${PRELOAD}" "\${VERSION_DIR}/index.js" "\$@"
EOF
  chmod +x "$LAUNCHER"

  local marker_begin="# --- Cursor Agent (Termux) ---"
  local marker_end="# --- end Cursor Agent ---"
  touch "$HOME/.bashrc"
  if grep -q "$marker_begin" "$HOME/.bashrc" 2>/dev/null; then
    awk -v b="$marker_begin" -v e="$marker_end" '
      $0==b {skip=1; next}
      $0==e {skip=0; next}
      !skip {print}
    ' "$HOME/.bashrc" > "$HOME/.bashrc.tmp"
    mv "$HOME/.bashrc.tmp" "$HOME/.bashrc"
  fi
  # PATH only. Do NOT export LD_LIBRARY_PATH here — it leaks into Termux-X11
  # and other Android/GUI processes. The launcher sets it for the agent only.
  cat >> "$HOME/.bashrc" <<BASHRC
${marker_begin}
export PATH="\$HOME/.local/bin:\$PATH"
${marker_end}
BASHRC
  if [[ -f "$HOME/.profile" ]] && ! grep -q '.bashrc' "$HOME/.profile" 2>/dev/null; then
    echo '[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"' >> "$HOME/.profile"
  fi

  ok "Launcher: $LAUNCHER"
  ok "Preload: $PRELOAD_DST"
}

smoke_test() {
  step "Smoke test (no global LD_LIBRARY_PATH)..."
  export PATH="$BIN_DIR:$PATH"
  env -u LD_LIBRARY_PATH "$LAUNCHER" --help >/dev/null
  ok "cursor-agent --help works"
}

apply_patches() {
  local vdir="${1:-}"
  if [[ -z "$vdir" ]]; then
    vdir="$(latest_version_dir)" || die "No installed agent version to patch."
  fi
  VERSION_DIR="$vdir"
  step "Patching $VERSION_DIR"
  fix_tls_and_libs
  write_preload "$PRELOAD_DST"
  patch_merkle_stub
  patch_persist_tmpdir
  write_tree_sitter_stubs "$VERSION_DIR"
  sync_npm_preload
  # Always refresh launcher + bashrc so LD_LIBRARY_PATH never leaks globally.
  install_preload_and_launcher
  ok "Patches applied"
}

main() {
  require_termux
  mkdir -p "$BIN_DIR" "$INSTALL_ROOT" "$SHIM_DIR" "$HOME/tmp"
  ensure_node_ok

  if [[ "$PATCH_ONLY" -eq 1 ]]; then
    apply_patches
    smoke_test
    ok "Patch-only done. hash -r ; cursor-agent about"
    exit 0
  fi

  [[ "$NO_DEPS" -eq 1 ]] || install_deps
  ensure_node_ok
  cleanup_previous
  detect_version
  download_package
  swap_binaries
  rebuild_sqlite
  apply_patches
  smoke_test

  cat <<MSG

ok Cursor Agent ready (this Termux).

  hash -r
  cursor-agent about
  NO_OPEN_BROWSER=1 cursor-agent login

After cursor-agent update:
  bct --patch-only

Fresh wipe + reinstall:
  bruk-cursor-termux

MSG
}

main "$@"
