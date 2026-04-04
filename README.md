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
- 22 tests

**Phase 2 (next):** Code generator — emit Jai source from parsed protocols.

**Phase 3:** Wire protocol — socket connection, message framing, fd passing.

**Phase 4:** Client API — registry, globals, surfaces, input.

## Building

Requires the Jai compiler (beta 0.2.026+) at `~/jai/jai/`.

```bash
./build.sh            # Build → build/main
./build.sh - test     # Build and run tests
```

The build uses Jai's compile-time metaprogramming via `first.jai` — no external build tools required.

## Project Structure

```
src/
  xml.jai          — Zero-copy XML pull parser
  protocol.jai     — Protocol data model + parser
  main.jai         — Validation harness
tests/
  xml_test.jai     — 22 tests (parser, entities, protocol)
vendor/
  wayland-protocols/   — Vendored protocol XML (core, stable, staging, unstable)
  reference/           — zig-wayland and wayland-rs sources for reference
first.jai          — Build metaprogram
```

## Vendored Protocols

59 XML protocol definitions from `/usr/share/wayland/` and `/usr/share/wayland-protocols/`:

- **Core:** `wayland.xml` (23 interfaces)
- **Stable:** xdg-shell, viewporter, tablet, presentation-time, linux-dmabuf
- **Staging:** 31 protocols (cursor-shape, fractional-scale, xdg-dialog, etc.)
- **Unstable:** 20 protocols (xdg-decoration, pointer-constraints, relative-pointer, etc.)

## License

MIT
