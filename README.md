# jai-wayland

Wayland client support for the [Jai](https://jai.community/) programming language.

## Design

This library takes the same approach as [zig-wayland](https://github.com/ifreund/zig-wayland) and [wayland-rs](https://github.com/Smithay/wayland-rs): bypass `libwayland-client.so` entirely and speak the Wayland wire protocol directly.

**Key decisions:**

- **No libwayland dependency.** The Wayland wire protocol is simple — structured messages over a Unix socket with fd passing via `sendmsg`/`recvmsg`. No reason to link a C library for that.
- **No hard-linked shared objects.** Like many OpenGL loaders, we use function pointer tables populated at runtime via `dlopen`. Nothing shows up under `ldd`.
- **Code generation from protocol XML.** Wayland protocols are defined in XML files. We parse them and generate Jai bindings — interface structs, opcode constants, and dispatch tables.
- **Compile-time marshalling.** Request functions use a compile-time `marshal` macro that walks arg struct types via `type_info` and emits specialized serialization code. Zero runtime reflection, zero branches — just raw stores.

## Status

**Phase 1 (complete):** XML parser and protocol data model.

- Zero-copy pull parser for XML (~290 lines)
- Protocol data model: `Protocol`, `Interface`, `Message`, `Arg`, `Enum_Def`, `Entry`
- Parses all 59 vendored protocol XML files (189 interfaces) with zero failures

**Phase 2 (complete):** Code generator — emit Jai source from parsed protocols.

- Standalone tool reads protocol XML and emits idiomatic Jai source files
- Per-interface files with typed structs, opcode constants, event tagged unions, enum definitions, and request functions
- Full protocol descriptions as doc comments for traceability to the spec
- 56 protocols, 175 interfaces in `modules/wayland/`
- 92 tests across 5 test suites

**Phase 3 (complete):** Wire protocol — message framing, compile-time marshalling, fd passing.

- `inline` primitive writers for native-endian 4-byte-aligned wire encoding
- `marshal` macro: `#expand` + `#insert #run generate_marshal_code(type_info(T))` — walks arg struct fields at compile time, emits type-specific serialization code (fixed-size stack buffer or variable-size runtime path)
- `marshal_constructor` variant: caller provides pre-allocated object ID, writes it as first arg
- `Fd :: #type,distinct s32` — file descriptors tagged for compile-time walker, routed to `SCM_RIGHTS` out-of-band
- `Connection` struct: Unix socket connect, send/recv buffers, fd queues, `sendmsg`/`recvmsg` with `SCM_RIGHTS` ancillary data
- Object ID allocator (client IDs from 1, incrementing)
- Generated request functions now call `marshal()`/`marshal_constructor()` instead of stubs

**Phase 4 (complete):** Client API — no inversion of control.

- **Design principle: simple things MUST be simple.** Application owns the event loop. No callbacks, no dispatch tables, no event queues, no proxy lifecycle manager.
- `discover_globals(conn)` — performs wl_display.get_registry + sync roundtrip, returns list of all compositor globals
- `find_global(globals, name)` — look up a global by interface name
- `init_display(conn)` — create wl_display proxy (always ID 1)
- Wire read helpers: `read_string`, `read_array` — mirrors of write_string/write_array for event deserialization
- `wl_registry.bind` — full untyped `new_id` wire encoding (interface name + version + id)
- `memfd_create` — thin syscall wrapper for anonymous shared memory
- `examples/hello_globals.jai` — 20 lines, prints all compositor globals
- `examples/hello_window.jai` — ~150 lines, displays a black 640x480 window via wl_shm. Full protocol: discover, bind, create surface, configure, attach buffer, event loop with ping/pong
- 96 tests across 5 test suites
- Tested live against Hyprland compositor on Arch Linux

**Phase 5 (next):** Rendering integration — EGL/Vulkan WSI, `wl_shm` for CPU rendering.

## Building

Requires the Jai compiler (beta 0.2.026+) at `~/jai/jai/`.

```bash
./build.sh              # Build → build/main
./build.sh - test       # Build and run XML/protocol tests
./build.sh - gen_test   # Build and run generator tests
./build.sh - wire_test  # Build and run wire protocol tests
./build.sh - marshal_test  # Build and run marshal macro tests
./build.sh - compile_test  # Build and run compilation smoke tests
./build.sh - generate   # Regenerate modules/wayland/ from protocol XML
./build.sh - hello_globals  # Build and run: print compositor globals
./build.sh - hello_window   # Build and run: display a black window
```

The build uses Jai's compile-time metaprogramming via `first.jai` — no external build tools required.

## Project Structure

```
src/
  xml.jai            — Zero-copy XML pull parser
  protocol.jai       — Protocol data model + parser
  generator.jai      — Code generator (naming, enums, events, requests, assembly)
  generate_main.jai  — Generator entry point (file I/O, deduplication)
  main.jai           — Validation harness
tests/
  xml_test.jai       — 22 tests (parser, entities, protocol)
  generator_test.jai — 36 tests (naming, enums, events, requests, assembly)
  wire_test.jai      — 20 tests (primitive read/write, header, string/array, buffers)
  marshal_test.jai   — 9 tests (fixed args, fd, string, array, constructors)
  compile_test.jai   — 9 tests (imports generated module, verifies types)
examples/
  hello_globals.jai  — 20 lines: connect, discover globals, print them
  hello_window.jai   — ~150 lines: full wl_shm black window with event loop
modules/
  wayland/           — Generated Jai bindings (56 protocols)
    module.jai       — Module root (#load chain)
    types.jai        — Shared types (Fixed, Fd, Interface_Descriptor, Wire_Arg_Type)
    wire.jai         — Wire primitives (read/write, header, string/array encoding)
    connection.jai   — Socket connect, buffers, fd queues, sendmsg/recvmsg
    marshal.jai      — Compile-time marshal macro (#expand + #insert #run)
    registry.jai     — discover_globals, find_global, init_display helpers
    shm.jai          — memfd_create syscall wrapper
    wayland/         — Core protocol (wl_display, wl_surface, etc.)
    xdg_shell/       — XDG shell (xdg_toplevel, xdg_surface, etc.)
    ...              — 54 more protocol directories
vendor/
  wayland-protocols/   — Vendored protocol XML (core, stable, staging, unstable)
  reference/           — zig-wayland and wayland-rs sources for reference
first.jai            — Build metaprogram
```

## Vendored Protocols

59 XML protocol definitions from `/usr/share/wayland/` and `/usr/share/wayland-protocols/`:

- **Core:** `wayland.xml` (23 interfaces)
- **Stable:** xdg-shell, viewporter, tablet, presentation-time, linux-dmabuf
- **Staging:** 31 protocols (cursor-shape, fractional-scale, xdg-dialog, etc.)
- **Unstable:** 20 protocols (xdg-decoration, pointer-constraints, relative-pointer, etc.)

## License

MIT
