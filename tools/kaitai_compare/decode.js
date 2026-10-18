// Decodes files with the official Kaitai Struct compiler and JavaScript
// runtime, for compare.py:
//
//     node decode.js <schema.json> <file>...
//
// schema.json is a .ksy file converted to JSON. For each file, prints one
// line of JSON in the shape of gnrcrdr's --dump json: a set instance is an
// object of its seq fields in read order, each an array of its values
// (one for a field read once), with byte arrays as lowercase hex. Fields
// that were not read, value instances and the runtime's own members (_io,
// _parent, _root, _raw_*, _m_*) are left out; names are as the generated
// code spells them (lowerCamelCase). A file that fails to decode prints
// {"error": "..."}.

"use strict";

const fs = require("fs");
const compiler = require("kaitai-struct-compiler");
const KaitaiStream = require("kaitai-struct/KaitaiStream");

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
  return out;
}

async function main() {
  const [schemaPath, ...files] = process.argv.slice(2);
  if (!schemaPath || files.length === 0) {
    console.error("usage: node decode.js <schema.json> <file>...");
    process.exit(2);
  }

  const ksy = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
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
