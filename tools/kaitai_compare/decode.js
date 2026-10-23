// Decodes files with the official Kaitai Struct compiler and JavaScript
// runtime, for compare.py:
//
//     node decode.js <schema.json> [--imports <imports.json>] [--params <json>] [--offsets] <file>...
//
// schema.json is a .ksy file converted to JSON. imports.json maps each
// import, as the compiler asks for it ("rel:" or "abs:" and its name, with
// no / at the start of an absolute one), to its schema. --params gives the
// arguments of the params of the top-level type, as a JSON array, with
// byte arrays as arrays of integers, and the argument of a param of a user
// type as {"type": its name, "bytes": an array of integers}, from which it
// is made. For each file, prints one
// line of JSON in the shape of gnrcrdr's --dump json: a set instance is an
// object of its seq fields in read order, then its parse instances
// (instances with pos), each an array of its values (one for a field read
// once), with byte arrays as lowercase hex. The runtime reads a parse
// instance when it is first accessed, so each is accessed here. Fields
// that were not read, value instances, params and the runtime's own
// members (_io, _parent, _root, _raw_*, _m_*) are left out; names are as
// the generated code spells them (lowerCamelCase, and _unnamed and its
// index for an attribute without an id). A file that fails to
// decode prints {"error": "..."}.
//
// With --offsets, the schema is compiled in debug mode, and each line maps
// the path of every value that is not a set instance, as gnrcrdr's text
// dump writes it (root[0].field[i]...), to the offset in the file that
// the runtime's debug record gives it: where the read of the value
// started. The runtime copies the bytes of a substream whose pad-right it
// removes or that it cuts at a terminator, and decompresses those of one
// with process: zlib; a debug record in such a stream gives offsets from
// its start, which is taken to be where its field starts, as gnrcrdr does.

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

// The names of the parse instances, of those of them with io, and of the
// params of each type in spec, by the name of its generated class, added to
// out. Types of the same name share their lists.
function members(spec, name, out) {
  const cls = upperCamel(name);
  out[cls] = out[cls] || { parseInstances: [], withIo: new Set(), params: new Set() };
  for (const [id, inst] of Object.entries(spec.instances || {})) {
    if (inst.value === undefined) out[cls].parseInstances.push(lowerCamel(id));
    if (inst.value === undefined && inst.io !== undefined) out[cls].withIo.add(lowerCamel(id));
  }
  for (const p of spec.params || []) out[cls].params.add(lowerCamel(p.id));
  for (const [id, type] of Object.entries(spec.types || {})) members(type, id, out);
  return out;
}

let MEMBERS = {};

// The name the compiler gives an attribute without an id: _unnamed and its
// index in seq.
const UNNAMED = /^_unnamed\d+$/;

function value(v) {
  if (v instanceof Uint8Array) return Buffer.from(v).toString("hex");
  if (typeof v === "object" && v !== null) return instance(v);
  return v;
}

// Whether io is a substream of the input that root is read from: a view of
// its bytes. Node takes small buffers, such as the bytes that zlib
// decompresses, from a shared pool, so one can share the input's
// ArrayBuffer without being part of it.
function inInput(io, root) {
  const base = root._io.byteOffset;
  return io._buffer === root._io._buffer && io.byteOffset >= base && io.byteOffset <= base + root._io.size;
}

// Adds the offset of every value of obj, whose stream starts at offset pos
// in the file, to out, by its path. root is the root of the tree.
function offsets(obj, path, pos, root, out) {
  const m = MEMBERS[obj.constructor.name] || { parseInstances: [], withIo: new Set(), params: new Set() };
  const base = root._io.byteOffset;
  const keys = Object.keys(obj).filter((k) => (!k.startsWith("_") || UNNAMED.test(k)) && !m.params.has(k));
  for (const key of keys.concat(m.parseInstances)) {
    const v = obj[key];
    if (v === undefined || v === null) continue;
    const debug = obj._debug[key] || obj._debug["_m_" + key];
    const values = Array.isArray(v) ? v : [v];
    // the records of an array are by element, also of a repeated switch-on
    // whose elements no case chose, which read nothing and add no value
    let records = Array.isArray(v) ? debug.arr : null;
    if (records && records.length > v.length) {
      const read = records.filter((r) => r.end > r.start);
      if (read.length === v.length) records = read;
    }
    values.forEach((x, i) => {
      const d = records ? records[i] : debug;
      const p = path + "." + key + "[" + i + "]";
      // a parse instance with io is read in another stream, which is not a
      // copy
      const start = (m.withIo.has(key) ? d.ioOffset - base : pos) + d.start;
      if (typeof x !== "object" || x instanceof Uint8Array) {
        out[p] = start;
      } else if (x._io === obj._io) {
        offsets(x, p, pos, root, out);
      } else {
        // a copy, or bytes that process made, starts where its field does
        offsets(x, p, inInput(x._io, root) ? x._io.byteOffset - base : start, root, out);
      }
    });
  }
  return out;
}

function instance(obj) {
  const m = MEMBERS[obj.constructor.name] || { parseInstances: [], params: new Set() };
  const out = {};
  for (const key of Object.keys(obj)) {
    const v = obj[key];
    if ((key.startsWith("_") && !UNNAMED.test(key)) || m.params.has(key) || v === undefined || v === null) continue;
    out[key] = Array.isArray(v) ? v.map(value) : [value(v)];
  }
  for (const key of m.parseInstances) {
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
  let params = [];
  if (args[0] === "--params") {
    params = JSON.parse(args[1]);
    args.splice(0, 2);
  }
  const withOffsets = args[0] === "--offsets";
  if (withOffsets) args.shift();
  const files = args;
  if (!schemaPath || files.length === 0) {
    console.error("usage: node decode.js <schema.json> [--imports <imports.json>] [--params <json>] [--offsets] <file>...");
    process.exit(2);
  }

  const ksy = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
  MEMBERS = members(ksy, ksy.meta.id, {});
  for (const spec of Object.values(imports)) members(spec, spec.meta.id, MEMBERS);
  const importer = {
    importYaml(name, mode) {
      const spec = imports[mode + ":" + name];
      return spec ? Promise.resolve(spec) : Promise.reject(new Error("no schema for import " + name));
    },
  };
  const sources = await compiler.compile("javascript", ksy, importer, withOffsets);

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
  // byte arrays, and the argument of a param of a user type, made of its
  // bytes as the caller of the runtime makes it: an imported schema's
  // top-level type, or by path, a type declared in another
  params = params.map((v) => {
    if (Array.isArray(v)) return new Uint8Array(v);
    if (v === null || typeof v !== "object") return v;
    const path = v.type.split("::").map(upperCamel);
    let cls = path[0] + ".js" in sources ? load("./" + path[0])[path[0]] : Root[path[0]];
    for (const name of path.slice(1)) cls = cls[name];
    const arg = new cls(new KaitaiStream(new Uint8Array(v.bytes)), null, null);
    // in debug mode, the constructor does not read
    if (withOffsets) arg._read();
    return arg;
  });

  for (const file of files) {
    try {
      const root = new Root(new KaitaiStream(fs.readFileSync(file)), null, null, ...params);
      if (withOffsets) {
        // in debug mode, the constructor does not read
        root._read();
        console.log(JSON.stringify(offsets(root, lowerCamel(ksy.meta.id) + "[0]", 0, root, {})));
      } else {
        console.log(JSON.stringify(instance(root)));
      }
    } catch (e) {
      console.log(JSON.stringify({ error: String(e) }));
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
