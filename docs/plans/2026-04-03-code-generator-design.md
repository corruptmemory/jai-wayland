# Code Generator Design

## Goal

A standalone tool that reads Wayland protocol XML files, parses them with the Phase 1 parser, and emits idiomatic Jai source files — one file per interface, grouped by protocol, with full doc comments, typed request functions, and event tagged unions.

## Architecture

The generator is a Jai program (`src/generator.jai`) invoked via `./build.sh - generate`. It reads from `vendor/wayland-protocols/`, writes to `modules/wayland/`. Generated files are checked into git — users consume them via `#import "wayland"` and never run the generator.

The generated code uses a **hybrid approach**: typed request functions provide compile-time safety at call sites, while their bodies delegate to a shared `marshal()` core (implemented in Phase 3). For Phase 2, function bodies are stubs.

## Output Structure

```
modules/
  wayland/
    module.jai                        // #load per protocol + shared types
    types.jai                         // Fixed, Interface_Descriptor, Wire_Arg_Type
    wayland/
      wayland.jai                     // #load per interface (23 files)
      wl_display.jai
      wl_registry.jai
      wl_surface.jai
      ...
    xdg_shell/
      xdg_shell.jai
      xdg_wm_base.jai
      xdg_surface.jai
      xdg_toplevel.jai
      ...
    linux_dmabuf_v1/
      ...
```

One directory per protocol, one file per interface, stitched together with `#load` chains.

## Per-Interface File Structure

Each file contains these sections in order:

### 1. Doc comment block

Full `<description>` from the XML — summary line plus body.

```jai
//
// wl_surface — a compositable surface
//
// A surface is a rectangular area that may be displayed on
// zero or more outputs...
//
```

### 2. Interface struct

```jai
Wl_Surface :: struct {
    id: u32;
    version: u32;
}
```

Minimal identity handle. Phase 3 adds connection pointer, userdata, etc.

### 3. Opcode constants

```jai
WL_SURFACE_DESTROY          :: 0;
WL_SURFACE_ATTACH           :: 1;
WL_SURFACE_DAMAGE_BUFFER    :: 9;

WL_SURFACE_ENTER            :: 0;  // event opcodes
WL_SURFACE_LEAVE            :: 1;
```

Request and event opcodes are 0-indexed per their definition order in the XML.

### 4. Enums

Regular enums use `enum`, bitfield enums use `enum_flags`:

```jai
Wl_Surface_Error :: enum u32 {
    INVALID_SCALE     :: 0;
    INVALID_TRANSFORM :: 1;
}

Wl_Seat_Capability :: enum_flags u32 {
    POINTER  :: 1;
    KEYBOARD :: 2;
    TOUCH    :: 4;
}
```

### 5. Event tagged union

```jai
Wl_Surface_Event_Kind :: enum u8 {
    ENTER :: 0;
    LEAVE :: 1;
    PREFERRED_BUFFER_SCALE :: 2;
    PREFERRED_BUFFER_TRANSFORM :: 3;
}

Wl_Surface_Event :: union kind: Wl_Surface_Event_Kind {
    .ENTER ,, output: u32;
    .LEAVE ,, output: u32;
    .PREFERRED_BUFFER_SCALE ,, factor: s32;
    .PREFERRED_BUFFER_TRANSFORM ,, transform: u32;
}
```

### 6. Typed request functions

```jai
wl_surface_attach :: (self: *Wl_Surface, buffer: *Wl_Buffer, x: s32, y: s32) {
    // TODO(Phase 3): marshal(self, WL_SURFACE_ATTACH, buffer.id, x, y);
}

wl_surface_frame :: (self: *Wl_Surface) -> *Wl_Callback {
    // TODO(Phase 3): return marshal_constructor(self, WL_SURFACE_FRAME, Wl_Callback);
}
```

Stub bodies for Phase 2. Full implementation in Phase 3.

### 7. Interface descriptor

```jai
WL_SURFACE_INTERFACE :: Interface_Descriptor.{
    name = "wl_surface",
    version = 6,
    request_count = 10,
    event_count = 4,
};
```

## Shared Types (`types.jai`)

```jai
Interface_Descriptor :: struct {
    name: string;
    version: u32;
    request_count: u32;
    event_count: u32;
}

Wire_Arg_Type :: enum u8 {
    INT; UINT; FIXED; STRING; OBJECT; NEW_ID; ARRAY; FD;
}

Fixed :: struct { raw: s32; }
fixed_from_float :: (v: float64) -> Fixed { ... }
fixed_to_float :: (f: Fixed) -> float64 { ... }
```

## Special Cases

**Untyped `new_id` (`wl_registry.bind`):** Uses a polymorphic type parameter:

```jai
wl_registry_bind :: (self: *Wl_Registry, name: u32, $T: Type, version: u32) -> *T { ... }
```

**Destructor requests:** Marked with a comment; Phase 3 handles cleanup.

**Cross-interface enum references:** `enum="wl_shm.format"` resolves to the `Wl_Shm_Format` type.

**Nullable object args:** `allow-null="true"` needs no special handling — Jai pointers are naturally nullable.

**Bitfield enums:** `bitfield="true"` emits `enum_flags` instead of `enum`.

## Naming Conventions

| XML | Jai | Example |
|-----|-----|---------|
| interface name | `Upper_Snake_Case` struct | `wl_surface` -> `Wl_Surface` |
| request/event opcode | `UPPER_SNAKE_CASE` constant | `WL_SURFACE_ATTACH :: 1` |
| request function | `lower_snake_case` | `wl_surface_attach(...)` |
| enum type | `Upper_Snake_Case` | `Wl_Surface_Error` |
| enum entry | `UPPER_SNAKE_CASE` | `INVALID_SCALE :: 0` |

## Rendering Compatibility

The generated bindings cover all protocols needed for OpenGL, Vulkan, and plain shared-memory buffer rendering:

- **Plain buffers:** `wl_shm`, `wl_shm_pool` (core `wayland.xml`)
- **GPU buffers:** `linux_dmabuf_v1` (staging protocol, used by GL and Vulkan compositors)
- **EGL/Vulkan WSI:** uses `wl_display` and `wl_surface` (core), integration is runtime Phase 3-4

## Testing

**Golden file tests:** Generate from a hand-written test protocol XML, compare against checked-in expected output.

**Compilation test:** `#import "wayland"` and reference a sampling of generated types, opcodes, and event unions. Verifies the full 59-protocol output compiles.

**Coverage checks:** Total interface count (189), spot-check specific interfaces for correct opcodes, enum values, event variants.

## Scope Boundary

**Phase 2 generates:** Types, opcodes, enums, tagged unions, stub request functions, interface descriptors, doc comments, module structure.

**Phase 3-4 implements:** `marshal()`/`marshal_constructor()`, wire protocol, socket connection, event dispatch, buffer management, EGL/Vulkan integration.
