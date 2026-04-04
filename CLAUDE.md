# CLAUDE.md

## Project Overview

Wayland client library for Jai. Bypasses libwayland entirely — speaks the wire protocol directly, uses runtime dlopen for any shared libraries, and generates bindings from Wayland protocol XML specs.

**Current status:** Phase 1 complete (XML parser + protocol data model). Phase 2 (code generator) is next.

## Build Commands

```bash
./build.sh            # Build main → build/main
./build.sh - test     # Build and run 22 tests → build_tests/xml_tests
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

**Tests** (`tests/xml_test.jai`): 22 tests covering pull parser, entity decoding, protocol parsing, edge cases.

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

1. **Code generator** — Read `Protocol` structs, emit Jai source with interface structs, opcode constants, function pointer tables. Use `#type_info_procedures_are_void_pointers` like Jai's GL bindings.
2. **Wire protocol** — Unix socket connect, message framing (header + args), fd passing via `sendmsg`/`recvmsg` with `SCM_RIGHTS`.
3. **Client API** — `wl_display` connect, `wl_registry` globals, surface management, input.
