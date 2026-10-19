// Decodes files with the official Kaitai Struct compiler and JavaScript
// runtime, for compare.py:
//
//     node decode.js <schema.json> [--imports <imports.json>] <file>...
//
// schema.json is a .ksy file converted to JSON. imports.json maps each
// import, as the compiler asks for it ("rel:" or "abs:" and its name, with
// no / at the start of an absolute one), to its schema. For each file, prints one
// line of JSON in the shape of gnrcrdr's --dump json: a set instance is an
// object of its seq fields in read order, then its parse instances
// (instances with pos), each an array of its values (one for a field read
// once), with byte arrays as lowercase hex. The runtime reads a parse
// instance when it is first accessed, so each is accessed here. Fields
// that were not read, value instances and the runtime's own members (_io,
// _parent, _root, _raw_*, _m_*) are left out; names are as the generated
// code spells them (lowerCamelCase). A file that fails to decode prints
// {"error": "..."}.

"use strict";

const fs = require("fs");
const compiler = require("kaitai-struct-compiler");
const KaitaiStream = require("kaitai-struct/KaitaiStream");

// A .ksy name as the generated code spells a type (UpperCamelCase) or a
// field (lowerCamelCase).
function upperCamel(name) {
  return name.split("_").map((p) => p.slice(0, 1).toUpperCase() + p.slice(1)).join("");
}

function lowerCamel(name) {
  const u = upperCamel(name);
  return u.slice(0, 1).toLowerCase() + u.slice(1);
}

// The names of the parse instances of each type in spec, by the name of
// its generated class, added to out. Types of the same name share a list.
function parseInstances(spec, name, out) {
  const cls = upperCamel(name);
  out[cls] = out[cls] || [];
  for (const [id, inst] of Object.entries(spec.instances || {})) {
    if (inst.value === undefined) out[cls].push(lowerCamel(id));
  }
  for (const [id, type] of Object.entries(spec.types || {})) parseInstances(type, id, out);
  return out;
}

let PARSE_INSTANCES = {};

function value(v) {
  if (v instanceof Uint8Array) return Buffer.from(v).toString("hex");
  if (typeof v === "object" && v !== null) return instance(v);
  return v;
}

function instance(obj) {
  const out = {};
  for (const key of Object.keys(obj)) {
    const v = obj[key];
    if (key.startsWith("_") || v === undefined || v === null) continue;
    out[key] = Array.isArray(v) ? v.map(value) : [value(v)];
  }
  for (const key of PARSE_INSTANCES[obj.constructor.name] || []) {
    const v = obj[key];
    if (v === undefined || v === null) continue;
    out[key] = Array.isArray(v) ? v.map(value) : [value(v)];
  }
  return out;
}

async function main() {
  const args = process.argv.slice(2);
  const schemaPath = args.shift();
  let imports = {};
  if (args[0] === "--imports") {
    imports = JSON.parse(fs.readFileSync(args[1], "utf8"));
    args.splice(0, 2);
  }
  const files = args;
  if (!schemaPath || files.length === 0) {
    console.error("usage: node decode.js <schema.json> [--imports <imports.json>] <file>...");
    process.exit(2);
  }

  const ksy = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
  PARSE_INSTANCES = parseInstances(ksy, ksy.meta.id, {});
  for (const spec of Object.values(imports)) parseInstances(spec, spec.meta.id, PARSE_INSTANCES);
  const importer = {
    importYaml(name, mode) {
      const spec = imports[mode + ":" + name];
      return spec ? Promise.resolve(spec) : Promise.reject(new Error("no schema for import " + name));
    },
  };
  const sources = await compiler.compile("javascript", ksy, importer, false);

  // each generated file is a module, which requires those of its imports
  const modules = {};
  const load = (name) => {
    if (name === "kaitai-struct/KaitaiStream") return KaitaiStream;
    const file = name.replace(/^\.\//, "") + ".js";
    if (!(file in sources)) return require(name);
    if (!(file in modules)) {
      const module = { exports: {} };
      modules[file] = module.exports;
      new Function("module", "exports", "require", sources[file])(module, module.exports, load);
    }
    return modules[file];
  };
  const rootName = upperCamel(ksy.meta.id);
  const Root = load("./" + rootName)[rootName];

  for (const file of files) {
    try {
      const root = new Root(new KaitaiStream(fs.readFileSync(file)));
      console.log(JSON.stringify(instance(root)));
    } catch (e) {
      console.log(JSON.stringify({ error: String(e) }));
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
