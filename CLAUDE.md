# CLAUDE.md

## Project Overview

Wayland client library for Jai. Bypasses libwayland entirely — speaks the wire protocol directly, uses runtime dlopen for any shared libraries, and generates bindings from Wayland protocol XML specs.

**Current status:** Phase 1 (XML parser), Phase 2 (code generator), and Phase 3 (wire protocol) complete. Phase 4 (client API) is next.

## Build Commands

```bash
./build.sh              # Build main → build/main
./build.sh - test       # Build and run 22 XML/protocol tests
./build.sh - gen_test   # Build and run 36 generator tests
./build.sh - wire_test  # Build and run 16 wire protocol tests
./build.sh - marshal_test  # Build and run 9 marshal macro tests
./build.sh - compile_test  # Build and run 9 compilation smoke tests (imports generated module)
./build.sh - generate   # Regenerate modules/wayland/ from protocol XML
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
- Per-interface files with: doc comments, struct (with `conn: *Connection`), opcodes, enums (regular + bitfield), event tagged unions, request arg structs, typed request functions with `marshal()`/`marshal_constructor()` calls, interface descriptor
- Naming transforms: `wl_surface` → `Wl_Surface` (type), `WL_SURFACE_ATTACH` (opcode), `wl_surface_attach` (function)
- Handles special cases: untyped `new_id` (polymorphic `$T`), destructors, cross-interface enum refs, numeric identifiers, reserved words
- Deduplicates protocols (core > stable > staging > unstable priority)
- Output: `modules/wayland/` — 56 protocols, 175 interfaces

**Wire protocol** (`modules/wayland/wire.jai`, `connection.jai`, `marshal.jai`):
- `wire.jai` — `inline` primitive writers (`write_u32`, `write_s32`, `read_u32`, `read_s32`), `pack_header`/`unpack_header`, `write_string`/`write_array` with 4-byte padding, `align4`
- `connection.jai` — `Connection` struct (socket fd, send/recv buffers, fd queues, object ID allocator), `wayland_connect`/`wayland_disconnect`, `connection_queue`/`connection_queue_fd`/`connection_flush` (sendmsg with SCM_RIGHTS), `connection_read` (recvmsg with SCM_RIGHTS), `connection_peek_message`/`connection_consume_message`/`connection_pop_fd`
- `marshal.jai` — compile-time marshal macro using `#expand` + `#insert #run generate_marshal_code(type_info(T))`. Walks request arg struct members at compile time, emits type-specific serialization code. Two paths: fixed-size (stack buffer) and variable-size (runtime computation for strings/arrays). `Fd` args (distinct s32) route to `connection_queue_fd` (SCM_RIGHTS out-of-band). Also `marshal_constructor` for new_id allocation.

**Generated module** (`modules/wayland/`):
- `module.jai` → `#load` chain → `types.jai`, `wire.jai`, `connection.jai`, `marshal.jai` → per-protocol directories → per-interface files
- `types.jai` — shared types: `Interface_Descriptor`, `Wire_Arg_Type`, `Fixed`, `Fd` (distinct s32), wire constants
- Request functions have real `marshal()` calls that serialize args into the connection buffer

**Tests:**
- `tests/xml_test.jai`: 22 tests (pull parser, entities, protocol parsing)
- `tests/generator_test.jai`: 36 tests (naming, enums, events, requests, assembly, end-to-end)
- `tests/wire_test.jai`: 16 tests (primitive writers, header pack/unpack, string/array encoding, buffer queueing)
- `tests/marshal_test.jai`: 9 tests (fixed args, fd, string, array, Fixed, empty, constructors)
- `tests/compile_test.jai`: 9 tests (imports generated module, verifies types/Fd/conn/arg structs compile)
- **Total: 92 tests across 5 test suites**

## Jai Toolchain

**MANDATORY:** Before writing or modifying ANY Jai code, invoke the `jai-language` skill using the Skill tool. This loads the comprehensive language reference.

Jai compiler expected at `~/jai/jai/`. Standard library at `~/jai/jai/modules/`. The `~/jai/jai/how_to/` directory has annotated examples of every feature.

## Key Patterns

- No external dependencies — only Jai standard library (Basic, File, String, File_Utilities, Compiler, Autorun, Socket, POSIX)
- Zero-copy throughout: XML parser returns slices into the source buffer, protocol parser stores those slices
- Test pattern: named procedures with `assert()` + `print("  PASS: ...\n")`, called from `main()` in groups
- `first.jai` uses `build_and_run_test()` helper with `Autorun.run_build_result_of_workspace()` for test execution
- Generator returns temp-allocated strings via `String_Builder` with `sb.allocator = temp`; file writer uses `write_entire_file(path, *sb)` which accepts `*String_Builder` directly
- Compile-time code generation: `marshal` macro uses `#expand` + `#insert #run` to walk struct type_info and emit serialization code. Debug expansions in `.build/.added_strings_wN.jai`

## Wire Protocol Design

**Compile-time marshalling:** The `marshal` macro walks request arg struct fields via `type_info` at compile time and emits type-specific byte-packing code. `#inline` primitive writers ensure zero-overhead — the optimizer sees only raw stores. This is the "Lisp-like macro" pattern from `csv_write_row` in jai-http.

**Type-to-wire mapping (all 4-byte aligned, native-endian):**
- `u32`/`s32` → 4 bytes direct
- `Fixed` → 4 bytes (write `.raw` as s32)
- `string` → u32 length (incl NUL) + data + NUL + pad to 4
- `[] u8` (array) → u32 length + data + pad to 4
- `*Interface` (object) → 4 bytes (write `.id`)
- `Fd` (`#type,distinct s32`) → NOT on wire, passed via SCM_RIGHTS out-of-band

**Message header:** 8 bytes — `[object_id: u32][(size << 16) | opcode: u32]`

## Generator Special Cases

These edge cases were discovered during the compilation smoke test against all 59 protocol XMLs:

- **Numeric identifiers:** `wl_output.transform` has entries `90`, `180`, `270` — prefixed with `_` since bare numbers aren't valid Jai identifiers
- **Reserved words as field names:** Some protocol args use Jai reserved words (e.g., `context`) — suffixed with `_`
- **Self-referencing #load:** Some protocols have an interface with the same name as the protocol (e.g., `ext_image_capture_source_v1`) — interface filename gets `_interface` suffix to avoid the loader `#load`-ing itself
- **Protocol deduplication:** Stable/staging versions supersede unstable versions (e.g., `xdg_shell` vs `xdg_shell_unstable_v5`). Generator sorts by priority (core > stable > staging > unstable) and skips protocols whose interface names collide. 3 unstable protocols are skipped.
- **Tagged union constraint:** Jai's `.TAG ,, field` syntax supports only one field per variant. Multi-arg events use wrapper structs (e.g., `Wl_Pointer_Motion_Args`). Zero-arg events use empty structs.

## Vendored Files

- `vendor/wayland-protocols/` — 59 XML protocol definitions (core, stable, staging, unstable)
- `vendor/reference/zig-wayland/` — Zig Wayland bindings (reference for wire protocol and scanner)
- `vendor/reference/wayland-rs/` — Rust Wayland bindings (reference for code generator and backend)

## Design Documents

- `docs/plans/2026-04-03-xml-parser-design.md` — Phase 1 XML parser design
- `docs/plans/2026-04-03-xml-parser-impl.md` — Phase 1 implementation plan (7 tasks)
- `docs/plans/2026-04-03-code-generator-design.md` — Phase 2 code generator design (hybrid approach: typed stubs + shared marshal core)
- `docs/plans/2026-04-03-code-generator-impl.md` — Phase 2 implementation plan (12 tasks)
- `docs/plans/2026-04-04-wire-protocol-impl.md` — Phase 3 wire protocol implementation plan (11 tasks)

## Next Steps

1. **Client API (Phase 4)** — Object map (id → proxy with dispatch table), event dispatch to typed `*_Event` tagged unions, `wl_display` connect handshake, `wl_registry` globals, proxy lifecycle management. Complete the TODO(Phase 4) stubs: proper proxy allocation in `marshal_constructor`, `destroy_proxy` in destructors. Untyped `new_id` wire encoding for `wl_registry.bind`.
2. **Rendering integration** — EGL/Vulkan WSI for GPU buffers, `wl_shm` for CPU buffers. Must work with OpenGL, Vulkan, and plain shared-memory buffers.
