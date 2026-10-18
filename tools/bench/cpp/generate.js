// Generates a C++ parser from a .ksy schema with the official Kaitai Struct
// compiler, the one pinned in tools/kaitai_compare/package.json, for
// build.py:
//
//     node generate.js <schema.json> <out_dir>
//
// schema.json is the .ksy file converted to JSON. Writes the generated
// files (<id>.h and <id>.cpp) to out_dir.

"use strict";

const fs = require("fs");
const path = require("path");
const compiler = require(path.join(__dirname, "..", "..", "kaitai_compare", "node_modules", "kaitai-struct-compiler"));

async function main() {
  const [schemaPath, outDir] = process.argv.slice(2);
  if (!schemaPath || !outDir) {
    console.error("usage: node generate.js <schema.json> <out_dir>");
    process.exit(2);
  }

  const ksy = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
  const sources = await compiler.compile("cpp_stl", ksy, null, false);
  for (const [name, source] of Object.entries(sources)) {
    fs.writeFileSync(path.join(outDir, name), source);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
