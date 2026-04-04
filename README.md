# jai-wayland

Wayland client support for the [Jai](https://jai.community/) programming language.

## Design

This library takes the same approach as [zig-wayland](https://github.com/ifreund/zig-wayland) and [wayland-rs](https://github.com/Smithay/wayland-rs): bypass `libwayland-client.so` entirely and speak the Wayland wire protocol directly.

**Key decisions:**

- **No libwayland dependency.** The Wayland wire protocol is simple — structured messages over a Unix socket with fd passing via `sendmsg`/`recvmsg`. No reason to link a C library for that.
- **No hard-linked shared objects.** Like many OpenGL loaders, we use function pointer tables populated at runtime via `dlopen`. Nothing shows up under `ldd`.
- **Code generation from protocol XML.** Wayland protocols are defined in XML files. We parse them and generate Jai bindings — interface structs, opcode constants, and dispatch tables.

## Status

**Phase 1 (complete):** XML parser and protocol data model.

- Zero-copy pull parser for XML (~290 lines)
- Protocol data model: `Protocol`, `Interface`, `Message`, `Arg`, `Enum_Def`, `Entry`
- Parses all 59 vendored protocol XML files (189 interfaces) with zero failures

**Phase 2 (complete):** Code generator — emit Jai source from parsed protocols.

- Standalone tool reads protocol XML and emits idiomatic Jai source files
- Per-interface files with typed structs, opcode constants, event tagged unions, enum definitions, and request function stubs
- Full protocol descriptions as doc comments for traceability to the spec
- 56 protocols, 189 interfaces, 233 generated `.jai` files in `modules/wayland/`
- 64 tests across 3 test suites

**Phase 3 (next):** Wire protocol — socket connection, message framing, fd passing.

**Phase 4:** Client API — registry, globals, surfaces, input.

## Building

Requires the Jai compiler (beta 0.2.026+) at `~/jai/jai/`.

```bash
./build.sh              # Build → build/main
./build.sh - test       # Build and run XML/protocol tests
./build.sh - gen_test   # Build and run generator tests
./build.sh - compile_test  # Build and run compilation smoke tests
./build.sh - generate   # Regenerate modules/wayland/ from protocol XML
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
  compile_test.jai   — 6 tests (imports generated module, verifies types)
modules/
  wayland/           — Generated Jai bindings (56 protocols, 233 files)
    module.jai       — Module root (#load chain)
    types.jai        — Shared types (Fixed, Interface_Descriptor, Wire_Arg_Type)
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
