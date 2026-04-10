# CLAUDE.md

## Project Overview

Wayland client library for Jai. Bypasses libwayland entirely — speaks the wire protocol directly, uses runtime dlopen for any shared libraries, and generates bindings from Wayland protocol XML specs.

**Current status:** Phases 1-4 complete, unmarshal + screen/keyboard discovery + dynamic resize + keyboard input done. Working Wayland client — connects to compositor, discovers globals and outputs, displays resizable windows via wl_shm with pooled buffers, handles keyboard input. No libwayland dependency.

## Build Commands

```bash
./build.sh              # Build main → build/main
./build.sh - test       # Build and run 22 XML/protocol tests
./build.sh - gen_test   # Build and run 36 generator tests
./build.sh - wire_test  # Build and run 22 wire protocol tests
./build.sh - marshal_test  # Build and run 9 marshal macro tests
./build.sh - unmarshal_test  # Build and run 12 unmarshal macro tests
./build.sh - compile_test  # Build and run 8 compilation smoke tests (imports generated module)
./build.sh - generate   # Regenerate modules/wayland/ from protocol XML
./build.sh - hello_globals  # Build and run hello_globals example (live compositor)
./build.sh - hello_screens  # Build and run hello_screens example (output discovery)
./build.sh - hello_window   # Build and run hello_window example (resizable window)
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
- Per-interface files with: doc comments, struct (`id: u32` + `version: u32` with compile-time default), opcodes, enums (regular + bitfield), event tagged unions, request arg structs, typed request functions with `marshal()`/`marshal_constructor()` calls, interface descriptor
- Request functions take `batch: *MessageBuilder` as first param (string builder pattern)
- Naming transforms: `wl_surface` → `Wl_Surface` (type), `WL_SURFACE_ATTACH` (opcode), `wl_surface_attach` (function)
- Handles special cases: untyped `new_id` (polymorphic `$T`), destructors, cross-interface enum refs, numeric identifiers, reserved words
- Deduplicates protocols (core > stable > staging > unstable priority)
- Output: `modules/wayland/` — 56 protocols, 175 interfaces

**Wire protocol** (`modules/wayland/wire.jai`, `connection.jai`, `marshal.jai`):
- `wire.jai` — `inline` primitive writers (`write_u32`, `write_s32`, `read_u32`, `read_s32`), `pack_header`/`unpack_header`, `write_string`/`write_array` with 4-byte padding, `align4`
- `connection.jai` — Three types: `Connection` (socket fd + object ID allocator), `MessageBuilder` (polymorphic outgoing batch buffer), `ReceiveBuffer` (polymorphic incoming buffer). `wayland_connect`/`wayland_disconnect`, `wayland_send(conn, batch)`/`wayland_receive(conn, buf)`/`wayland_send_receive`. `message_queue`/`message_queue_fd` for building messages, `receive_peek_message`/`receive_consume_message`/`receive_pop_fd` for reading.
- `marshal.jai` — compile-time marshal macro using `#expand` + `#insert #run generate_marshal_code(type_info(T))`. Walks request arg struct members at compile time, emits type-specific serialization code. Two paths: fixed-size (stack buffer) and variable-size (runtime computation for strings/arrays). `Fd` args (distinct s32) route to `message_queue_fd` (SCM_RIGHTS out-of-band). Takes `*MessageBuilder` as target. Also `marshal_constructor` for new_id allocation.
- `unmarshal.jai` — compile-time unmarshal macro (mirror of marshal). `unmarshal(*args, payload, recv)` fills a single event args struct; `unmarshal_event(*event, opcode, payload, recv)` dispatches opcode into a tagged union. Walks type_info at compile time, emits type-specific reads. Handles all 8 wire types: u32, s32, Fixed, string, `[] u8`, Fd (via `receive_pop_fd`), `*Interface` (`New(T,, temp)`), `*void`. For tagged unions, walks `tagged_union_bindings` to generate opcode→variant dispatch.

**Generated module** (`modules/wayland/`):
- `module.jai` → `#load` chain → `types.jai`, `wire.jai`, `connection.jai`, `marshal.jai`, `unmarshal.jai`, `shm.jai`, `registry.jai`, `session.jai`, `output.jai`, `input.jai` → per-protocol directories → per-interface files
- `types.jai` — shared types: `Interface_Descriptor`, `Wire_Arg_Type`, `Fixed`, `Fd` (distinct s32), wire constants
- Interface structs: `id: u32` + `version: u32 = #run DESCRIPTOR.version` (no `conn` field, version defaulted)
- Request functions take `batch: *MessageBuilder` as first param, then `self: *Interface`, then protocol args. Use `marshal()` calls that serialize args into the MessageBuilder.
- Constructor functions take `new_id: u32` from caller — no internal allocation, no return value

**Client API** (`modules/wayland/registry.jai`, `session.jai`, `shm.jai`):
- `session.jai` — `WaylandSession` struct (Connection, ReceiveBuffer, globals, bound objects). Lives in `#add_context wayland_session: *WaylandSession;`. `init_wayland_session()` connects, discovers globals, binds compositor/wm_base. `for_expansion` on `*WaylandSession` iterates incoming messages, handles ping/pong and `wl_display.error` transparently (uses `defer` for message consume so `continue` is safe in loop bodies), yields `WaylandMessageHeader`, exposes `recv: *ReceiveBuffer` via backtick binding (for `unmarshal` Fd support). Context-based convenience overloads: `allocate_id()`, `wayland_send(*batch, drain=)`, `session()`, `connection()`, `registry()`, `compositor()`, `wm_base()`, `globals()`.
- `registry.jai` — `discover_globals(conn)` performs get_registry + sync roundtrip using MessageBuilder/ReceiveBuffer, returns `[] Global_Info` + registry ID. Context-based overload stores into session. `find_global(globals, name)` / `find_global(name)` lookups. `init_display(conn)` creates wl_display proxy (always ID 1).
- `shm.jai` — `memfd_create(name, flags)` thin wrapper over Linux syscall for anonymous shared memory.
- `output.jai` — `Mode_Info`, `Screen_Info` structs, `get_screens_info()` discovers all compositor outputs via wl_output bind + sync roundtrip + `unmarshal_event`. Returns `[] Screen_Info` with name, modes, current_mode, scale_factor, geometry.
- `input.jai` — `Keyboard_Info` struct (seat, keyboard, keymap_fd, keymap_size), `get_keyboard_info()` binds wl_seat, checks capabilities, acquires wl_keyboard, receives keymap event. Returns keyboard info + bool.
- **Design: no inversion of control.** Application owns the event loop via `for session() { ... }`, switches on object IDs, decodes events with `unmarshal`/`unmarshal_event` or inline `read_u32`/`read_string`. No callbacks, no dispatch tables, no event queues.
- **Message-shaped API:** Requests are batched into a `MessageBuilder` (string builder pattern), sent explicitly with `wayland_send`. No hidden flush state.
- Wire read helpers: `read_string(src) -> string, u32` and `read_array(src) -> [] u8, u32` — mirrors of write_string/write_array.

**Examples** (`examples/`):
- `hello_globals.jai` — 20 lines, connects and prints all compositor globals. First live test.
- `hello_screens.jai` — ~30 lines, calls `get_screens_info()` and prints output name, modes, scale, geometry.
- `hello_window.jai` — ~180 lines, discovers screen resolution + keyboard via helpers, allocates one shm pool sized to native resolution, creates surface/xdg_surface/toplevel, handles dynamic resize + keyboard input (r/g/b switch gradient color, q quits). Uses `defer` for repaint consolidation — handlers set `needs_repaint`, defer does paint+attach+damage+commit+send.

**Tests:**
- `tests/xml_test.jai`: 22 tests (pull parser, entities, protocol parsing)
- `tests/generator_test.jai`: 36 tests (naming, enums, events, requests, assembly, end-to-end)
- `tests/wire_test.jai`: 22 tests (primitive writers/readers, header pack/unpack, string/array read/write, MessageBuilder queueing, ReceiveBuffer peek/consume/pop_fd)
- `tests/marshal_test.jai`: 9 tests (fixed args, fd, string, array, Fixed, empty, constructors — all target MessageBuilder)
- `tests/unmarshal_test.jai`: 12 tests (round-trip fixed/string/array/Fixed/fd/empty, *void, *Interface temp alloc, tagged union dispatch with real Wl_Output_Event)
- `tests/compile_test.jai`: 8 tests (imports generated module, verifies types/Fd/arg structs/version defaults compile)
- **Total: 109 tests across 6 test suites**

## Jai Toolchain

**MANDATORY:** Before writing or modifying ANY Jai code, invoke the `jai-language` skill using the Skill tool. This loads the comprehensive language reference.

Jai compiler expected at `~/jai/jai/`. Standard library at `~/jai/jai/modules/`. The `~/jai/jai/how_to/` directory has annotated examples of every feature.

## Key Patterns

- No external dependencies — only Jai standard library (Basic, File, String, File_Utilities, Compiler, Autorun, Socket, POSIX)
- Zero-copy throughout: XML parser returns slices into the source buffer, protocol parser stores those slices
- Test pattern: named procedures with `assert()` + `print("  PASS: ...\n")`, called from `main()` in groups
- `first.jai` uses `build_and_run_test()` helper with `Autorun.run_build_result_of_workspace()` for test execution
- Generator returns temp-allocated strings via `String_Builder` with `sb.allocator = temp`; file writer uses `write_entire_file(path, *sb)` which accepts `*String_Builder` directly
- Compile-time code generation: `marshal`/`unmarshal` macros use `#expand` + `#insert #run` to walk struct type_info and emit serialization/deserialization code. `unmarshal_event` walks `tagged_union_bindings` for opcode dispatch. Debug expansions in `.build/.added_strings_wN.jai`
- **Client ID wire ordering:** Wayland compositors expect client-allocated IDs in monotonically increasing order on the wire. Always call `allocate_id()` immediately before queuing the message that creates that object. Pre-allocating IDs and sending in different order causes `wl_display.error`.
- **`defer` in for_expansion:** The `for session()` for_expansion uses `defer` for `receive_consume_message` so that `continue` in loop bodies doesn't skip message consumption. Never put post-body cleanup after `#insert body` without `defer` — `continue` will skip it.
- **Dogfood the convenience API:** Code inside the wayland module (output.jai, input.jai) should use session.jai convenience functions (`globals()`, `registry()`, `allocate_id()`, `for session()`, `wayland_send(*batch)`) rather than reaching into `context.wayland_session` directly.

## Wire Protocol Design

**Compile-time marshalling:** The `marshal(batch, object_id, opcode, args)` macro walks request arg struct fields via `type_info` at compile time and emits type-specific byte-packing code into the MessageBuilder. `#inline` primitive writers ensure zero-overhead — the optimizer sees only raw stores. This is the "Lisp-like macro" pattern from `csv_write_row` in jai-http.

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
- `docs/plans/2026-04-07-noise-reduction-design.md` — Message-shaped API redesign: Connection/MessageBuilder/ReceiveBuffer split
- `docs/plans/2026-04-07-noise-reduction-impl.md` — Noise reduction implementation plan (10 tasks)

## Next Steps

1. **Rendering integration (Phase 5)** — EGL/Vulkan WSI for GPU buffers, `wl_shm` for CPU rendering beyond solid colors. OpenGL, Vulkan, and plain shared-memory paths.
2. **Pointer input** — wl_pointer event decoding (enter/leave, motion with Fixed coordinates, button, axis/scroll). Extend `input.jai` with `get_pointer_info()`.
3. **XKB keymap parsing** — mmap the keymap Fd from `wl_keyboard.keymap`, parse xkb format for proper keysym translation (currently using raw evdev keycodes).
4. **Server-allocated objects** — Handle `new_id` args in events (e.g., wl_data_device.data_offer, tablet hotplug). IDs from 0xFF000000+ range.
5. **Double buffering** — Front/back buffers in the same shm pool for tear-free resizes. Swap on `wl_buffer.release` event.
6. **Fractional scaling** — `wp_fractional_scale_v1` protocol for non-integer scale factors (1.25, 1.5).
