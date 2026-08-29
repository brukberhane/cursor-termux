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
  cp -f "$PRELOAD_SRC" "$dest"
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

sync_npm_preload() {
  local npm_root preload
  npm_root="$(npm root -g 2>/dev/null || true)"
  preload="${npm_root}/bruk-cursor-termux/lib/termux-preload.js"
  if [[ -f "$preload" && -f "$PRELOAD_SRC" ]]; then
    cp -f "$PRELOAD_SRC" "$preload"
    ok "Synced npm bruk-cursor-termux preload"
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
  pkg install -y curl git nodejs-lts ripgrep python make clang pkg-config binutils openssl-tool tar which
  command -v node >/dev/null || die "node missing after pkg install"
  command -v rg >/dev/null || die "ripgrep missing after pkg install"
  ok "Dependencies ready (node $(node -v))"
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

fix_tls_and_libs() {
  step "TLS + library shims..."
  mkdir -p "$PREFIX/etc/tls/certs"
  if [[ -f "$PREFIX/etc/tls/cert.pem" ]]; then
    ln -sfn "$PREFIX/etc/tls/cert.pem" "$PREFIX/etc/tls/certs/cert.pem"
  fi
  if [[ -f "$PREFIX/lib/libc++_shared.so" ]]; then
    ln -sfn "$PREFIX/lib/libc++_shared.so" "$PREFIX/lib/libstdc++.so.6"
    ln -sfn "$PREFIX/lib/libc++_shared.so" "$PREFIX/lib/libstdc++.so"
  fi
  local stub_c="$HOME/.cache/cursor-termux/empty-gnu-compat.c"
  mkdir -p "$(dirname "$stub_c")"
  cat > "$stub_c" <<'C'
void __termux_gnu_compat_stub(void) {}
C
  clang -shared -fPIC -Wl,-soname,libm.so.6 "$stub_c" -o "$PREFIX/lib/libm.so.6" 2>/dev/null || true
  clang -shared -fPIC -Wl,-soname,libc.so.6 "$stub_c" -o "$PREFIX/lib/libc.so.6" 2>/dev/null || true
  clang -shared -fPIC -Wl,-soname,libpthread.so.0 "$stub_c" -o "$PREFIX/lib/libpthread.so.0" 2>/dev/null || true
  clang -shared -fPIC -Wl,-soname,libdl.so.2 "$stub_c" -o "$PREFIX/lib/libdl.so.2" 2>/dev/null || true
  if [[ -e "$PREFIX/glibc/lib/libgcc_s.so.1" ]]; then
    ln -sfn "$PREFIX/glibc/lib/libgcc_s.so.1" "$PREFIX/lib/libgcc_s.so.1"
  fi
  ok "Shims ready"
}

rebuild_sqlite() {
  step "Rebuilding sqlite3 for Bionic (best effort)..."
  (
    cd "$VERSION_DIR"
    export LD_LIBRARY_PATH="$PREFIX/lib:${LD_LIBRARY_PATH:-}"
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
if (src.includes("MerkleClient:class{constructor(){}}")) {
  console.log("Merkle stub already present");
  process.exit(0);
}
const stub =
  '{MerkleClient:class{constructor(){}async build(){}async getTreeStructure(){return null}async getSimhash(){return[]}async getNumEmbeddableFiles(){return 0}},getParentProcessInfo:()=>null,MULTI_ROOT_ABSOLUTE_PATH:""}';
const exactFrom =
  "Original error: ${c&&c.stack?c.stack:c}`;throw new Error(n)}e.exports=u,e.exports.MerkleClient=u.MerkleClient";
const exactTo =
  "Original error: ${c&&c.stack?c.stack:c}`;u=" +
  stub +
  "}e.exports=u,e.exports.MerkleClient=u.MerkleClient";
if (src.includes(exactFrom)) {
  src = src.replace(exactFrom, exactTo);
  fs.writeFileSync(p, src);
  console.log("Patched Merkle throw -> stub (exact match)");
  process.exit(0);
}
const re = /if\(!\w\)\{let \w="Failed to load native binding for ".+?throw new Error\(\w\)\}/s;
if (re.test(src)) {
  src = src.replace(re, "if(!c){c=" + stub + ";}");
  fs.writeFileSync(p, src);
  console.log("Patched Merkle throw -> stub (regex fallback)");
  process.exit(0);
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
export LD_LIBRARY_PATH="\${PREFIX}/lib:\${LD_LIBRARY_PATH:-}"
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
  write_preload "$PRELOAD_DST"
  write_tree_sitter_stubs "$VERSION_DIR"
  sync_npm_preload
  # Always refresh launcher + bashrc so LD_LIBRARY_PATH never leaks globally.
  install_preload_and_launcher
  ok "Patches applied"
}

main() {
  require_termux
  mkdir -p "$BIN_DIR" "$INSTALL_ROOT" "$HOME/tmp"

  if [[ "$PATCH_ONLY" -eq 1 ]]; then
    apply_patches
    smoke_test
    ok "Patch-only done. hash -r ; cursor-agent about"
    exit 0
  fi

  [[ "$NO_DEPS" -eq 1 ]] || install_deps
  cleanup_previous
  detect_version
  download_package
  swap_binaries
  fix_tls_and_libs
  rebuild_sqlite
  patch_merkle_stub
  install_preload_and_launcher
  write_tree_sitter_stubs "$VERSION_DIR"
  sync_npm_preload
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
