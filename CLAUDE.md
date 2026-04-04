# CLAUDE.md

## Project Overview

Wayland client library for Jai. Bypasses libwayland entirely — speaks the wire protocol directly, uses runtime dlopen for any shared libraries, and generates bindings from Wayland protocol XML specs.

**Current status:** Phase 1 (XML parser) and Phase 2 (code generator) complete. Phase 3 (wire protocol) is next.

## Build Commands

```bash
./build.sh              # Build main → build/main
./build.sh - test       # Build and run 22 XML/protocol tests
./build.sh - gen_test   # Build and run 36 generator tests
./build.sh - compile_test  # Build and run 6 compilation smoke tests (imports generated module)
./build.sh - generate   # Run code generator → modules/wayland/ (233 files)
```

Both delegate to `first.jai`, which uses Jai's compile-time metaprogramming to create compiler workspaces. The `-` separates compiler args from metaprogram args.

## Architecture

**Build metaprogram** (`first.jai`): Creates workspaces for the main build and test suites. Tests auto-run after compilation via `Autorun`.

**XML parser** (`src/xml.jai`):
- Zero-copy pull parser yielding `Xml_Event` values (OPEN_TAG, CLOSE_TAG, ATTRIBUTE, CHARACTER_DATA, COMMENT, PROCESSING_INSTRUCTION)
- `xml_parser_init(doc)` + `xml_next(*parser)` API
- Mode-based state machine: NORMAL → ATTRS → CHARS
- All returned strings are slices into the source buffer (no allocation)
- `xml_decode_entities()` handles `&amp;` `&lt;` `&gt;` `&quot;` `&apos;`

**Protocol model** (`src/protocol.jai`):
- Structs: `Protocol`, `Interface`, `Message`, `Arg`, `Arg_Type`, `Enum_Def`, `Entry`, `Description`
- `parse_protocol(xml_source)` drives the pull parser to build the data model
- Handles hex values (`0x20203843`), destructors, bitfield enums, nullable args, cross-interface enum refs (`wl_shm.format`)
- Validates against all 59 vendored protocol XML files

**Code generator** (`src/generator.jai` + `src/generate_main.jai`):
- Standalone tool reading Protocol structs, emitting Jai source files
- Per-interface files with: doc comments, struct, opcodes, enums (regular + bitfield), event tagged unions, typed request function stubs, interface descriptor
- Naming transforms: `wl_surface` → `Wl_Surface` (type), `WL_SURFACE_ATTACH` (opcode), `wl_surface_attach` (function)
- Handles special cases: untyped `new_id` (polymorphic `$T`), destructors, cross-interface enum refs, numeric identifiers, reserved words
- Deduplicates protocols (core > stable > staging > unstable priority)
- Output: `modules/wayland/` — 56 protocols, 189 interfaces, 233 `.jai` files

**Generated module** (`modules/wayland/`):
- `module.jai` → `#load` chain → per-protocol directories → per-interface files
- `types.jai` — shared types: `Interface_Descriptor`, `Wire_Arg_Type`, `Fixed`
- Request function bodies are stubs (`// TODO(Phase 3)`) — Phase 3 provides `marshal()`

**Tests:**
- `tests/xml_test.jai`: 22 tests (pull parser, entities, protocol parsing)
- `tests/generator_test.jai`: 36 tests (naming, enums, events, requests, assembly, end-to-end)
- `tests/compile_test.jai`: 6 tests (imports generated module, verifies types compile)

## Jai Toolchain

**MANDATORY:** Before writing or modifying ANY Jai code, invoke the `jai-language` skill using the Skill tool. This loads the comprehensive language reference.

Jai compiler expected at `~/jai/jai/`. Standard library at `~/jai/jai/modules/`. The `~/jai/jai/how_to/` directory has annotated examples of every feature.

## Key Patterns

- No external dependencies — only Jai standard library (Basic, File, String, File_Utilities, Compiler, Autorun)
- Zero-copy throughout: XML parser returns slices into the source buffer, protocol parser stores those slices
- Test pattern: named procedures with `assert()` + `print("  PASS: ...\n")`, called from `main()` in groups
- `first.jai` uses `build_and_run_test()` helper with `Autorun.run_build_result_of_workspace()` for test execution

## Vendored Files

- `vendor/wayland-protocols/` — 59 XML protocol definitions (core, stable, staging, unstable)
- `vendor/reference/zig-wayland/` — Zig Wayland bindings (reference for wire protocol and scanner)
- `vendor/reference/wayland-rs/` — Rust Wayland bindings (reference for code generator and backend)

## Next Steps

1. **Wire protocol** — Unix socket connect, message framing (header + args), fd passing via `sendmsg`/`recvmsg` with `SCM_RIGHTS`. Implement `marshal()` and `marshal_constructor()` to fill in the generated request stubs.
2. **Client API** — `wl_display` connect, `wl_registry` globals, surface management, input.
3. **Rendering integration** — EGL/Vulkan WSI for GPU buffers, `wl_shm` for CPU buffers.
