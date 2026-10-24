# Third-party notices

zelbyn is under the MIT License in [LICENSE](LICENSE). It contains no third-party code or data apart from what this file describes.

## Kaitai Struct

zelbyn reads schemas written in [Kaitai Struct](https://kaitai.io/), the `.ksy` language and its expression language, which are the work of the Kaitai Project. zelbyn follows the language's documentation and the behaviour of the Kaitai Project's official compiler and runtimes, so that it decodes as they do. It is not affiliated with or endorsed by the Kaitai Project, and "Kaitai Struct" is used here only to name the language it reads.

### Kaitai Struct C++/STL runtime

`read_bits` in `zelbyn/data/reader.odin` is adapted from `read_bits_int_be` and `read_bits_int_le` of the [Kaitai Struct C++/STL runtime](https://github.com/kaitai-io/kaitai_struct_cpp_stl_runtime), version 0.11, under this license:

```
MIT License

Copyright (c) 2016-2025 Kaitai Project

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Development tools

These Kaitai Project works are used only by the development tools, are downloaded when those tools are set up, and are not part of this repository or of zelbyn's build:

| Work | License | Used by |
|---|---|---|
| [kaitai-struct-compiler](https://github.com/kaitai-io/kaitai_struct_compiler) 0.11.0, from npm | GPL-3.0-or-later | `tools/kaitai_compare` and `tools/bench/cpp`, which run it to generate parsers |
| [kaitai-struct](https://github.com/kaitai-io/kaitai_struct_javascript_runtime) 0.11.0, the JavaScript runtime, from npm | Apache-2.0 | `tools/kaitai_compare` |
| [kaitai_struct_cpp_stl_runtime](https://github.com/kaitai-io/kaitai_struct_cpp_stl_runtime) 0.11 | MIT | `tools/bench/cpp`, which compiles it into the C++ reference |
| [kaitai_struct_formats](https://github.com/kaitai-io/kaitai_struct_formats) | each schema's own, in its `meta/license` | `tools/ksy_corpus`, `tools/yaml_corpus`, and the examples in the documentation |
| [kaitai_struct_samples](https://github.com/kaitai-io/kaitai_struct_samples) | each sample's own, in its `.license` file | `tools/ksy_corpus --samples`, and the examples in the documentation |

`tools/kaitai_compare/package-lock.json` records the npm packages' versions and checksums. It contains none of their code.
