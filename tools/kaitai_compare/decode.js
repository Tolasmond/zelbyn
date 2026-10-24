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
// is made. For each file, prints one line of JSON, {"value": v, "f4": [...]},
// or for a file that fails to decode, {"error": "..."}. f4 lists the paths
// (root.field[i].field[j]...) of the floats read as f4s, by the width of
// their debug records, as the schema is always compiled in debug mode. v is
// in the shape of zelbyn's --dump json: a set instance is an
// object of its seq fields in read order, then its parse instances
// (instances with pos), each an array of its values (one for a field read
// once), with byte arrays as lowercase hex. The runtime reads a parse
// instance when it is first accessed, so each is accessed here. Fields
// that were not read, value instances, params and the runtime's own
// members (_io, _parent, _root, _raw_*, _m_*) are left out. Names are as
// zelbyn writes them: an attribute's -orig-id, or else its id (or _unnamed
// and its index, for an attribute without one), found in the spec of the
// type of the object, by its generated class, so that two types can give
// one -orig-id to different attributes, or use as an id another's -orig-id.
// A name can be any string, constructor, __proto__ and error among them,
// so the objects that hold fields have no prototype, and the envelope
// keeps a field named error apart from an error.
//
// With --offsets, v maps
// the path of every value that is not a set instance, as zelbyn's text
// dump writes it (root[0].field[i]..., the root by its meta -orig-id or
// id), to the offset in the file that the runtime's debug record gives it:
// where the read of the value
// started. The runtime copies the bytes of a substream whose pad-right it
// removes or that it cuts at a terminator, and decompresses those of one
// with process: zlib; a debug record in such a stream gives offsets from
// its start, which is taken to be where its field starts, as zelbyn does.

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

// The name zelbyn shows for an attribute, an instance or a schema's meta:
// its -orig-id, unless it has none or a list of them, else its id.
function displayName(spec, id) {
  const orig = spec && spec["-orig-id"];
  return typeof orig === "string" && orig !== "" ? orig : id;
}

// Whether an attribute of type type, a type name or a switch-on, can have
// float values: f4 or f8, in either byte order, or a switch-on with a case
// of one.
function isFloat(type) {
  if (typeof type === "string") return /^f[48](le|be)?$/.test(type.trim());
  return typeof type === "object" && type !== null && Object.values(type.cases || {}).some(isFloat);
}

// The members of each generated class: the names its fields have in
// zelbyn's dump, by their names in the class (names), those of them that
// can have float values (floats), and the names in the class of its parse
// instances, of those of them with io, and of its params. They are those of the spec the class was generated from, found
// by the class itself, as nested and imported types can share a name.
const CLASSES = new Map();

// Adds the members of cls, generated from spec, and of the classes of the
// types declared in spec, which are properties of cls.
function addClass(cls, spec) {
  if (typeof cls !== "function") throw new Error("no generated class for a type of " + JSON.stringify(Object.keys(spec)));
  const m = { names: new Map(), floats: new Set(), parseInstances: [], withIo: new Set(), params: new Set() };
  (spec.seq || []).forEach((a, i) => {
    const key = a.id === undefined ? "_unnamed" + i : lowerCamel(a.id);
    m.names.set(key, a.id === undefined ? "_unnamed" + i : displayName(a, a.id));
    if (isFloat(a.type)) m.floats.add(key);
  });
  for (const [id, inst] of Object.entries(spec.instances || {})) {
    if (inst.value !== undefined) continue;
    m.names.set(lowerCamel(id), displayName(inst, id));
    if (isFloat(inst.type)) m.floats.add(lowerCamel(id));
    m.parseInstances.push(lowerCamel(id));
    if (inst.io !== undefined) m.withIo.add(lowerCamel(id));
  }
  for (const p of spec.params || []) m.params.add(lowerCamel(p.id));
  CLASSES.set(cls, m);
  for (const [id, type] of Object.entries(spec.types || {})) addClass(cls[upperCamel(id)], type);
}

// The members of the class of obj; an object of a class that no spec gave
// would be compared by names that are not zelbyn's, so it is an error. The
// class is found through the prototype, as a field with the id
// constructor would hide obj.constructor.
function membersOf(obj) {
  const cls = Object.getPrototypeOf(obj).constructor;
  const m = CLASSES.get(cls);
  if (!m) throw new Error("no spec for generated class " + cls.name);
  return m;
}

// The name zelbyn shows for key, a member of a class with members m.
function shown(m, key) {
  const n = m.names.get(key);
  if (n === undefined) throw new Error("no attribute or parse instance for member " + key);
  return n;
}

// The name the compiler gives an attribute without an id: _unnamed and its
// index in seq.
const UNNAMED = /^_unnamed\d+$/;

function value(v) {
  if (v instanceof Uint8Array) return Buffer.from(v).toString("hex");
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
// The debug record of each value of member key of obj, whose values are
// v, in order.
function records(obj, key, v) {
  const debug = obj._debug[key] || obj._debug["_m_" + key];
  if (!Array.isArray(v)) return [debug];
  // the records of an array are by element, also of a repeated switch-on
  // whose elements no case chose, which read nothing and add no value
  if (debug.arr.length > v.length) {
    const read = debug.arr.filter((r) => r.end > r.start);
    if (read.length === v.length) return read;
  }
  return debug.arr;
}

function offsets(obj, path, pos, root, out) {
  const m = membersOf(obj);
  const base = root._io.byteOffset;
  const keys = Object.keys(obj).filter((k) => (!k.startsWith("_") || UNNAMED.test(k)) && !m.params.has(k));
  for (const key of keys.concat(m.parseInstances)) {
    const v = obj[key];
    if (v === undefined || v === null) continue;
    const values = Array.isArray(v) ? v : [v];
    const rs = records(obj, key, v);
    values.forEach((x, i) => {
      const d = rs[i];
      const p = path + "." + shown(m, key) + "[" + i + "]";
      // a parse instance with io is read in another stream, which is not a
      // copy
      const start = (m.withIo.has(key) ? d.ioOffset - base : pos) + d.start;
      if (typeof x !== "object" || x instanceof Uint8Array) {
        if (p in out) throw new Error("two values are at " + p);
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

// Sets out[name] to values. Attributes of one type can share an -orig-id
// (elf.ksy's flags32 and flags64, read under exclusive conditions), and
// zelbyn writes the values of the one read: two with values have no name
// that tells them apart, which is an error.
function put(out, name, values) {
  if (name in out && out[name].length > 0 && values.length > 0) throw new Error("two fields are named " + name + ", and both have values");
  if (!(name in out) || values.length > 0) out[name] = values;
}

// obj, a set instance at path (as compare.py's first_difference writes
// paths: the root's name, then .name[i] for each value), in the shape of
// zelbyn's --dump json, with the path of every value that was read as an
// f4 added to f4. A float field's values are f4 or f8 as the runtime read
// them, 4 or 8 bytes by their debug records, which also tells the cases of
// a switch-on with both (minecraft_nbt.ksy's tag::float and tag::double).
function instance(obj, path, f4) {
  const m = membersOf(obj);
  const out = Object.create(null);
  const keys = Object.keys(obj).filter((k) => !(k.startsWith("_") && !UNNAMED.test(k)) && !m.params.has(k));
  for (const key of keys.concat(m.parseInstances)) {
    const v = obj[key];
    if (v === undefined || v === null) continue;
    const name = shown(m, key);
    const values = Array.isArray(v) ? v : [v];
    const rs = m.floats.has(key) ? records(obj, key, v) : null;
    put(out, name, values.map((x, i) => {
      const p = path + "." + name + "[" + i + "]";
      if (rs && typeof x === "number") {
        const width = rs.length === values.length ? rs[i].end - rs[i].start : -1;
        if (width !== 4 && width !== 8) throw new Error("no f4 or f8 read for the float at " + p);
        if (width === 4) f4.push(p);
      }
      return typeof x === "object" && x !== null && !(x instanceof Uint8Array) ? instance(x, p, f4) : value(x);
    }));
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
  const importer = {
    importYaml(name, mode) {
      const spec = imports[mode + ":" + name];
      return spec ? Promise.resolve(spec) : Promise.reject(new Error("no schema for import " + name));
    },
  };
  // in debug mode, which records where each value was read, and so the
  // width of each float
  const sources = await compiler.compile("javascript", ksy, importer, true);

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
  addClass(Root, ksy);
  // each imported schema's top-level type is the class of its own module
  for (const spec of Object.values(imports)) {
    const name = upperCamel(spec.meta.id);
    if (!(name + ".js" in sources)) throw new Error("no generated module for import " + spec.meta.id);
    const cls = load("./" + name)[name];
    if (!CLASSES.has(cls)) addClass(cls, spec);
  }
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
    arg._read();
    return arg;
  });

  for (const file of files) {
    try {
      const root = new Root(new KaitaiStream(fs.readFileSync(file)), null, null, ...params);
      // in debug mode, the constructor does not read
      root._read();
      const rootName = displayName(ksy.meta, ksy.meta.id);
      if (withOffsets) {
        console.log(JSON.stringify({ value: offsets(root, rootName + "[0]", 0, root, Object.create(null)) }));
      } else {
        const f4 = [];
        const v = instance(root, rootName, f4);
        console.log(JSON.stringify({ value: v, f4 }));
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
