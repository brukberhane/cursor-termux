"use strict";
/**
 * Termux preload for Cursor Agent.
 * - Spoof glibc (Termux looks like musl; Cursor then throws a fake musl MODULE_NOT_FOUND)
 * - Stub dlopen for glibc .node (file_service / merkle)
 * - Write JS stubs for tree-sitter + tree-sitter-bash (not shipped for Bionic)
 */
const fs = require("fs");
const path = require("path");
const Module = require("module");
const cp = require("child_process");
const workerThreads = require("worker_threads");

const versionDir =
  process.env.CURSOR_AGENT_VERSION_DIR ||
  path.dirname(process.argv[1] || "") ||
  process.cwd();
const preloadPath = __filename;

function fileServiceStub() {
  class FileService {
    constructor() {}
    async start() {
      return this;
    }
    async stop() {}
    async getFileStats() {
      return null;
    }
    async readFile() {
      return null;
    }
    async writeFile() {}
    async watch() {
      return { close() {} };
    }
  }
  const api = new Proxy(
    { FileService, fileService: new FileService(), default: FileService },
    {
      get(target, prop, recv) {
        if (prop in target) return Reflect.get(target, prop, recv);
        if (prop === "then") return undefined;
        if (typeof prop === "symbol") return undefined;
        return (..._args) => null;
      },
    }
  );
  return api;
}

function merkleStub() {
  class MerkleClient {
    constructor() {}
    async build() {}
    async getTreeStructure() {
      return null;
    }
    async getSimhash() {
      return [];
    }
    async getNumEmbeddableFiles() {
      return 0;
    }
    async initWithRipgrepIgnore() {}
  }
  return {
    MerkleClient,
    getParentProcessInfo: () => null,
    MULTI_ROOT_ABSOLUTE_PATH: "",
  };
}

function treeSitterParserJs() {
  return [
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
}

function ensureJsPackages() {
  const root = path.join(versionDir, "node_modules", "@anysphere");
  for (const name of [
    "file-service-linux-arm64-musl",
    "file-service-linux-arm64-gnu",
  ]) {
    const dir = path.join(root, name);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(
      path.join(dir, "package.json"),
      JSON.stringify({
        name: `@anysphere/${name}`,
        version: "0.0.0-termux-stub",
        main: "index.js",
      })
    );
    fs.writeFileSync(
      path.join(dir, "index.js"),
      `"use strict";\nmodule.exports = (${fileServiceStub.toString()})();\n`
    );
  }
  const parent = path.join(root, "file-service");
  fs.mkdirSync(parent, { recursive: true });
  fs.writeFileSync(
    path.join(parent, "package.json"),
    JSON.stringify({
      name: "@anysphere/file-service",
      version: "0.0.0-termux-stub",
      main: "index.js",
    })
  );
  fs.writeFileSync(
    path.join(parent, "index.js"),
    `"use strict";\nmodule.exports = require("../file-service-linux-arm64-gnu");\n`
  );
}

function ensureTreeSitter() {
  const root = path.join(versionDir, "node_modules");
  const parserJs = treeSitterParserJs();
  const pkgs = [
    ["tree-sitter", parserJs],
    ["tree-sitter-bash", 'module.exports={name:"bash"};\n'],
  ];
  for (const [name, body] of pkgs) {
    const dir = path.join(root, name);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(
      path.join(dir, "package.json"),
      JSON.stringify({
        name: name,
        version: "0.0.0-termux-stub",
        main: "index.js",
      })
    );
    fs.writeFileSync(path.join(dir, "index.js"), body);
  }
}

ensureJsPackages();
ensureTreeSitter();

try {
  if (process.report && typeof process.report.getReport === "function") {
    const orig = process.report.getReport.bind(process.report);
    process.report.getReport = function patchedReport(...args) {
      const r = orig(...args) || {};
      r.header = Object.assign({}, r.header || {}, {
        glibcVersionRuntime: "2.38",
      });
      if (!Array.isArray(r.sharedObjects)) r.sharedObjects = [];
      return r;
    };
  }
} catch (_) {}

const origReadFileSync = fs.readFileSync;
fs.readFileSync = function (p, opts) {
  const s = String(p);
  if (s.includes("/ldd") || s.endsWith("ldd")) {
    return opts && String(opts).includes("utf")
      ? "ldd (GNU libc) 2.38\n"
      : Buffer.from("ldd (GNU libc) 2.38\n");
  }
  return origReadFileSync.apply(this, arguments);
};

const origExecSync = cp.execSync;
cp.execSync = function (cmd, opts) {
  const c = String(cmd);
  if (c.includes("ldd")) {
    const out = "ldd (GNU libc) 2.38\n";
    if (opts && (opts.encoding === "utf8" || opts.encoding === "utf-8")) return out;
    return Buffer.from(out);
  }
  return origExecSync.apply(this, arguments);
};

const origExists = fs.existsSync;
fs.existsSync = function (p) {
  if (String(p) === "/usr/bin/ldd") return true;
  return origExists.apply(this, arguments);
};

const origDlopen = process.dlopen;
process.dlopen = function (mod, filename, ...rest) {
  const f = String(filename || "");
  try {
    if (f.includes("file_service") || f.includes("file-service")) {
      mod.exports = fileServiceStub();
      return;
    }
    if (f.includes("merkle-tree-napi") || f.includes("merkle_tree")) {
      mod.exports = merkleStub();
      return;
    }
  } catch (_) {}
  return origDlopen.call(this, mod, filename, ...rest);
};

function mapRequest(request) {
  if (typeof request !== "string") return null;
  if (request === "tree-sitter" || request === "tree-sitter-bash") {
    return path.join(versionDir, "node_modules", request, "index.js");
  }
  if (!request.includes("@anysphere/file-service")) return null;
  if (request === "@anysphere/file-service") {
    return path.join(versionDir, "node_modules/@anysphere/file-service/index.js");
  }
  if (request.includes("gnu")) {
    return path.join(
      versionDir,
      "node_modules/@anysphere/file-service-linux-arm64-gnu/index.js"
    );
  }
  return path.join(
    versionDir,
    "node_modules/@anysphere/file-service-linux-arm64-musl/index.js"
  );
}

const origResolve = Module._resolveFilename;
Module._resolveFilename = function (request, parent, isMain, options) {
  if (typeof request === "string" && request.startsWith("tree-sitter")) {
    try {
      ensureTreeSitter();
    } catch (_) {}
  }
  const mapped = mapRequest(request);
  if (mapped && fs.existsSync(mapped)) return mapped;
  return origResolve.call(this, request, parent, isMain, options);
};

const origLoad = Module._load;
Module._load = function (request, parent, isMain) {
  const mapped = mapRequest(request);
  if (mapped) return origLoad.call(this, mapped, parent, isMain);
  try {
    return origLoad.call(this, request, parent, isMain);
  } catch (e) {
    if (
      e &&
      e.code === "MODULE_NOT_FOUND" &&
      typeof request === "string" &&
      (request === "tree-sitter" || request.startsWith("tree-sitter-"))
    ) {
      try {
        ensureTreeSitter();
      } catch (_) {}
      const retry = mapRequest(request);
      if (retry && fs.existsSync(retry)) return origLoad.call(this, retry, parent, isMain);
    }
    throw e;
  }
};

function injectPreload(execArgv) {
  const argv = Array.isArray(execArgv) ? execArgv.slice() : [];
  const has = argv.some((a) => String(a).includes("termux-preload.js"));
  if (!has) argv.unshift("-r", preloadPath);
  return argv;
}

const RealWorker = workerThreads.Worker;
function HookedWorker(file, opts) {
  const options = Object.assign({}, opts || {});
  const base =
    options.execArgv != null ? options.execArgv : process.execArgv || [];
  options.execArgv = injectPreload(base);
  options.env = Object.assign({}, process.env, options.env || {}, {
    CURSOR_AGENT_VERSION_DIR: versionDir,
  });
  return new RealWorker(file, options);
}
HookedWorker.prototype = RealWorker.prototype;
Object.setPrototypeOf(HookedWorker, RealWorker);
workerThreads.Worker = HookedWorker;

const origFork = cp.fork;
cp.fork = function (modulePath, args, opts) {
  if (opts === undefined && args && !Array.isArray(args)) {
    opts = args;
    args = undefined;
  }
  opts = Object.assign({}, opts || {});
  opts.execArgv = injectPreload(
    opts.execArgv != null ? opts.execArgv : process.execArgv || []
  );
  opts.env = Object.assign({}, process.env, opts.env || {}, {
    CURSOR_AGENT_VERSION_DIR: versionDir,
  });
  return args === undefined
    ? origFork.call(this, modulePath, opts)
    : origFork.call(this, modulePath, args, opts);
};
