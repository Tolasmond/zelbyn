// Decodes files with the official Kaitai Struct compiler and JavaScript
// runtime, for compare.py:
//
//     node decode.js <schema.json> <file>...
//
// schema.json is a .ksy file converted to JSON. For each file, prints one
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
  const [schemaPath, ...files] = process.argv.slice(2);
  if (!schemaPath || files.length === 0) {
    console.error("usage: node decode.js <schema.json> <file>...");
    process.exit(2);
  }

  const ksy = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
  PARSE_INSTANCES = parseInstances(ksy, ksy.meta.id, {});
  const sources = await compiler.compile("javascript", ksy, null, false);
  const module = { exports: {} };
  const load = (name) => (name === "kaitai-struct/KaitaiStream" ? KaitaiStream : require(name));
  for (const source of Object.values(sources)) {
    new Function("module", "exports", "require", source)(module, module.exports, load);
  }
  const Root = Object.values(module.exports)[0];

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
