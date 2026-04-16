# Phase 4: Client API — No Inversion of Control

**Date:** 2026-04-05
**Goal:** Make the library usable for a complete "hello world" that connects to a Wayland compositor, discovers globals, creates a shared-memory buffer, and displays a black window — all in `main()`, no callbacks, no framework.

## Design Philosophy

**Simple things MUST be simple. No exceptions.**

The Wayland wire protocol is just structured messages on a Unix socket. The client API must reflect that simplicity:

- **No inversion of control.** The application owns the event loop. It calls `connection_read`, peeks at messages, switches on object IDs it knows about, and decodes events inline.
- **No callbacks.** No dispatch tables. No event queues. No handler registration.
- **No proxy lifecycle manager.** The application creates objects on the stack (or wherever it wants), assigns IDs, and tracks them with its own variables.
- **The "object map" is the application's own `if` chain.** The user allocated the IDs — they know which ID belongs to which object.

The library provides: **connect, send (marshal), receive (read + peek), decode (demarshal primitives).** The application provides: **the logic.**

## The Litmus Test

A "print the globals" program:

```jai
Wayland :: #import "wayland";
#import "Basic";

main :: () {
    conn: Wayland.Connection;
    if !Wayland.wayland_connect(*conn) { print("no compositor\n"); return; }
    defer Wayland.wayland_disconnect(*conn);

    globals := Wayland.discover_globals(*conn);
    for globals  print("[%] % v%\n", it.name, it.interface, it.version);
}
```

That's 10 lines. `discover_globals` is a library function -- not a framework, just a function that does the registry roundtrip and returns a list. You *could* do the roundtrip manually (the primitives are all public), but why would you? Every Wayland client needs this, there's only one correct implementation, and it returns data -- it doesn't take control.

For binding globals, there's a companion `find_global`:

```jai
compositor_name := Wayland.find_global(globals, "wl_compositor");
```

Returns the `name` field (the u32 you pass to `wl_registry.bind`), or 0 if not found.

If any API decision makes the above harder, the decision is wrong.

### Manual version (no helpers)

For understanding or customization, the same thing done manually is ~30 lines:

```jai
main :: () {
    conn: Connection;
    if !wayland_connect(*conn) { print("no compositor\n"); return; }
    defer wayland_disconnect(*conn);

    display: Wl_Display;  display.id = 1; display.version = 1; display.conn = *conn;

    registry_id := allocate_id(*conn);
    wl_display_get_registry(*display);
    sync_id := allocate_id(*conn);
    wl_display_sync(*display);
    connection_flush(*conn);

    done := false;
    while !done && connection_read(*conn) > 0 {
        msg, size := connection_peek_message(*conn);
        while msg != null {
            object_id, opcode, _ := unpack_header(msg);
            payload := msg + HEADER_SIZE;

            if object_id == {
                case registry_id;
                    if opcode == WL_REGISTRY_GLOBAL {
                        name := read_u32(payload);
                        iface, iface_len := read_string(payload + 4);
                        ver := read_u32(payload + 4 + iface_len);
                        print("[%] % v%\n", name, iface, ver);
                    }
                case sync_id;
                    done = true;
            }

            connection_consume_message(*conn, size);
            msg, size = connection_peek_message(*conn);
        }
    }
}
```

Both versions are first-class citizens. The helpers reduce ceremony; the primitives give full control. Neither forces a framework on you.

## The Black Window -- Full Wire Conversation

This is the complete protocol exchange for a `wl_shm` black window:

```
PHASE 1: Discovery
-----------------------------------------------
-> wl_display.get_registry              (registry = ID 2)
-> wl_display.sync                      (callback = ID 3)
-> flush

<- wl_registry.global  name=N  "wl_compositor"  vN
<- wl_registry.global  name=N  "wl_shm"         vN
<- wl_registry.global  name=N  "xdg_wm_base"    vN
<- ... more globals ...
<- wl_callback.done

PHASE 2: Bind the three globals we need
-----------------------------------------------
-> wl_registry.bind  name=?  "wl_compositor"  v6   (compositor = ID 4)
-> wl_registry.bind  name=?  "xdg_wm_base"   v6   (wm_base = ID 5)
-> wl_registry.bind  name=?  "wl_shm"        v2   (shm = ID 6)
-> flush

<- wl_shm.format  XRGB8888
<- wl_shm.format  ARGB8888
<- ... more formats ...

PHASE 3: Create the surface + window role
-----------------------------------------------
-> wl_compositor.create_surface          (surface = ID 7)
-> xdg_wm_base.get_xdg_surface(7)       (xdg_surface = ID 8)
-> xdg_surface.get_toplevel              (toplevel = ID 9)
-> xdg_toplevel.set_title("hello")
-> wl_surface.commit                     (empty commit -> triggers configure)
-> flush

<- xdg_toplevel.configure  width=0 height=0 states=[]
                           (0x0 = "you pick the size")
<- xdg_surface.configure   serial=1
                           (must ack before attaching buffer)

-> xdg_surface.ack_configure(serial=1)
-> flush

PHASE 4: Create the shared memory buffer
-----------------------------------------------
   fd = memfd_create("buffer", 0)
   ftruncate(fd, width * height * 4)
   data = mmap(fd, ...)
   memset(data, 0, ...)                 (black pixels)

-> wl_shm.create_pool(fd, size)         (pool = ID 10, fd via SCM_RIGHTS)
-> wl_shm_pool.create_buffer(           (buffer = ID 11)
      offset=0, width, height,
      stride=width*4, format=XRGB8888)
-> wl_shm_pool.destroy
-> flush

PHASE 5: Attach and show
-----------------------------------------------
-> wl_surface.attach(buffer=11, x=0, y=0)
-> wl_surface.damage_buffer(0, 0, width, height)
-> wl_surface.commit
-> flush

   >> BLACK WINDOW VISIBLE <<

PHASE 6: Stay alive
-----------------------------------------------
<- xdg_wm_base.ping(serial=N)
-> xdg_wm_base.pong(serial=N)
-> flush
   (repeat -- compositor kills unresponsive clients)

<- xdg_toplevel.close
   (user closed the window -- exit the loop)
```

## Implementation Tasks

### Task 1: Wire read helpers -- `read_string` and `read_array`

Mirror of `write_string`/`write_array`. These read from the incoming message buffer.

**Add to `modules/wayland/wire.jai`:**

```jai
// Read a Wayland string from the wire buffer.
// Returns: string slice into the buffer (valid until next connection_read)
//          and total bytes consumed (always 4-byte aligned).
// A length of 0 means empty string. Otherwise length includes NUL.
read_string :: (src: *u8) -> string, u32 {
    length := read_u32(src);
    if length == 0  return "", 4;
    result: string;
    result.data = src + 4;
    result.count = cast(s64)(length - 1);  // exclude NUL
    return result, 4 + align4(length);
}

// Read a Wayland array from the wire buffer.
// Returns: byte slice into the buffer (valid until next connection_read)
//          and total bytes consumed (always 4-byte aligned).
read_array :: (src: *u8) -> [] u8, u32 {
    length := read_u32(src);
    result: [] u8;
    result.data = src + 4;
    result.count = cast(s64) length;
    return result, 4 + align4(length);
}
```

**Tests:** `tests/wire_test.jai` -- add tests for read_string (normal, empty, padded), read_array.

### Task 2: Library helpers -- `discover_globals`, `find_global`, `init_display`

Convenience functions that live in the module. These are plain functions -- they do work and return data. No inversion of control.

**Add to `modules/wayland/registry.jai`** (new file, `#load`ed from `module.jai`):

```jai
Global_Info :: struct {
    name: u32;
    interface: string;   // heap-allocated copy, stable after return
    version: u32;
}

// Perform the wl_display.get_registry + wl_display.sync roundtrip.
// Returns all globals the compositor advertised, plus the registry ID
// (needed for subsequent wl_registry.bind calls).
// Allocates the registry and sync callback IDs internally.
discover_globals :: (conn: *Connection) -> [] Global_Info, u32 {
    display: Wl_Display;
    display.id = 1;  display.version = 1;  display.conn = conn;

    registry_id := allocate_id(conn);
    wl_display_get_registry(*display);
    sync_id := allocate_id(conn);
    wl_display_sync(*display);
    connection_flush(conn);

    globals: [..] Global_Info;

    done := false;
    while !done && connection_read(conn) > 0 {
        msg, size := connection_peek_message(conn);
        while msg != null {
            object_id, opcode, _ := unpack_header(msg);
            payload := msg + HEADER_SIZE;

            if object_id == {
                case registry_id;
                    if opcode == WL_REGISTRY_GLOBAL {
                        gname := read_u32(payload);
                        iface, iface_len := read_string(payload + 4);
                        ver := read_u32(payload + 4 + iface_len);
                        array_add(*globals, .{
                            name = gname,
                            interface = copy_string(iface),
                            version = ver,
                        });
                    }
                case sync_id;
                    done = true;
            }

            connection_consume_message(conn, size);
            msg, size = connection_peek_message(conn);
        }
    }

    return globals, registry_id;
}

// Look up a global by interface name. Returns the global's name (u32)
// for use with wl_registry.bind, or 0 if not found.
find_global :: (globals: [] Global_Info, interface: string) -> u32 {
    for globals {
        if it.interface == interface  return it.name;
    }
    return 0;
}

// Initialize a wl_display proxy. Always ID 1, always version 1.
init_display :: (conn: *Connection) -> Wl_Display {
    display: Wl_Display;
    display.id = 1;
    display.version = 1;
    display.conn = conn;
    return display;
}
```

**Tests:** Add a unit test that constructs fake wire messages in a buffer and verifies `discover_globals` parses them correctly. (Or defer to integration test in Task 9.)

### Task 3: `wl_registry_bind` wire encoding

This is the ONE special case in the entire protocol. All other `new_id` args are typed (the interface is known from XML). But `wl_registry.bind` has an **untyped** `new_id` -- the wire encoding is:

```
[name: u32][interface_name: string][version: u32][new_id: u32]
```

Three extra fields (interface name as string, version) that don't appear for typed `new_id`.

**Update `modules/wayland/wayland/wl_registry.jai`** (generated, but we need to hand-write this one function or update the generator):

```jai
wl_registry_bind :: (self: *Wl_Registry, name: u32, interface_name: string,
                     version: u32, new_id: u32) {
    // Manual wire encoding -- untyped new_id is the only special case
    msg_size: u32 = HEADER_SIZE;
    msg_size += 4;  // name
    msg_size += 4 + align4(cast(u32)(interface_name.count + 1));  // interface string
    msg_size += 4;  // version
    msg_size += 4;  // new_id

    buf: [MAX_MESSAGE_SIZE] u8;
    write_u32(buf.data, self.id);
    offset: u32 = HEADER_SIZE;
    write_u32(buf.data + offset, name);  offset += 4;
    offset += write_string(buf.data + offset, interface_name);
    write_u32(buf.data + offset, version);  offset += 4;
    write_u32(buf.data + offset, new_id);  offset += 4;
    write_u32(buf.data + 4, cast(u32)(cast(u32) offset << 16) | cast(u32) WL_REGISTRY_BIND);
    connection_queue(self.conn, buf.data, offset);
}
```

**Decision:** Either hand-write this in a non-generated file that overrides the generated stub, or teach the generator to emit the special encoding for untyped `new_id`. The hand-written approach is simpler for now -- it's literally the only function in the entire protocol that needs this.

### Task 4: Fix `marshal_constructor` -- caller provides the new ID

Currently `marshal_constructor` calls `allocate_id` internally. In the new API, the caller already allocated the ID and set it on their object struct. The marshal macro should take the new_id as a parameter.

**Change in `modules/wayland/marshal.jai`:**

```jai
// Before:
marshal_constructor :: (conn: *Connection, object_id: u32, opcode: u16, args: *$T) -> u32 #expand {
    _new_id := allocate_id(conn);
    ...
}

// After:
marshal_constructor :: (conn: *Connection, object_id: u32, opcode: u16, new_id: u32, args: *$T) #expand {
    _new_id := new_id;
    ...
}
```

No return value needed -- the caller already has the ID.

**Update generator** (`src/generator.jai`): Change all generated constructor calls from:
```jai
new_id := marshal_constructor(self.conn, self.id, OPCODE, *args);
```
to:
```jai
marshal_constructor(self.conn, self.id, OPCODE, new_id, *args);
```

Where `new_id` comes from a parameter. See Task 5 for the generated function signature change.

### Task 5: Update generated constructor functions

Constructor request functions currently return a pointer and allocate internally. In the new API, they should:
- Take the new object's ID as a parameter
- Not return anything (or return void)
- Let the caller set up their own struct

**Before:**
```jai
wl_compositor_create_surface :: (self: *Wl_Compositor) -> *Wl_Surface {
    args := Wl_Compositor_Create_Surface_Args.{};
    new_id := marshal_constructor(self.conn, self.id, WL_COMPOSITOR_CREATE_SURFACE, *args);
    // TODO(Phase 4): allocate proxy properly
    return null;
}
```

**After:**
```jai
wl_compositor_create_surface :: (self: *Wl_Compositor, new_id: u32) {
    args := Wl_Compositor_Create_Surface_Args.{};
    marshal_constructor(self.conn, self.id, WL_COMPOSITOR_CREATE_SURFACE, new_id, *args);
}
```

The application uses it as:
```jai
surface: Wl_Surface;
surface.id = allocate_id(*conn);
surface.version = 6;
surface.conn = *conn;
wl_compositor_create_surface(*compositor, surface.id);
```

**Constructor functions that also have regular args** (e.g., `wl_shm_pool_create_buffer`) keep their existing args plus gain `new_id`:
```jai
wl_shm_pool_create_buffer :: (self: *Wl_Shm_Pool, new_id: u32, offset: s32,
                               width: s32, height: s32, stride: s32, format: u32) {
    args := Wl_Shm_Pool_Create_Buffer_Args.{...};
    marshal_constructor(self.conn, self.id, WL_SHM_POOL_CREATE_BUFFER, new_id, *args);
}
```

**Generator change:** In `generate_request` in `src/generator.jai`, for constructor requests:
- Add `new_id: u32` as first parameter after `self`
- Change return type to `void` (no return)
- Pass `new_id` to `marshal_constructor`
- Remove the `// TODO(Phase 4)` comments

### Task 6: `memfd_create` syscall wrapper

Jai's POSIX module has `mmap`, `ftruncate`, `PROT_READ`, `PROT_WRITE`, `MAP_SHARED`. But `memfd_create` needs a thin syscall wrapper.

**Add to `modules/wayland/connection.jai`** (or a new `modules/wayland/shm.jai`):

```jai
// Create an anonymous shared memory file descriptor.
// Uses Linux memfd_create syscall (319 on x86_64).
memfd_create :: (name: *u8, flags: u32) -> s32 {
    return cast(s32) syscall(SYS_memfd_create, cast(u64) name, cast(u64) flags);
}
```

The `SYS_memfd_create` constant (319) is already in Jai's `POSIX/bindings/linux/syscall.jai`. The `syscall` function is available via `#import "POSIX"`.

### Task 7: Update tests

- **`tests/wire_test.jai`**: Add tests for `read_string`, `read_array`
- **`tests/marshal_test.jai`**: Update to new `marshal_constructor` signature (pass new_id explicitly)
- **`tests/compile_test.jai`**: Update constructor function signature expectations
- **`tests/generator_test.jai`**: Update expected output for constructor functions

### Task 8: Regenerate bindings

Run `./build.sh - generate` to regenerate all 175 interfaces with:
- Updated constructor function signatures (new_id parameter, void return)
- `wl_registry.bind` handled specially (or hand-written override)

### Task 9: The "hello world" -- print globals

Create `examples/hello_globals.jai`:
- Connect to compositor
- Call `discover_globals` (or do it manually -- both should work)
- Print each global's name, interface, and version
- ~10 lines with helper, ~30 lines manual

This is the first live test against Hyprland.

### Task 10: The "black window" -- pixels on screen

Create `examples/hello_window.jai`:
- Full 6-phase protocol exchange as documented above
- `memfd_create` + `mmap` for shared memory buffer
- `wl_shm.create_pool` + `wl_shm_pool.create_buffer`
- `wl_surface.attach` + `commit`
- Event loop: respond to `xdg_wm_base.ping`, handle `xdg_toplevel.close`
- ~100-120 lines, all in `main()`

This is the milestone: a visible black window on Jim's Hyprland desktop.

### Task 11: Build system updates

- **`first.jai`**: Add build targets for examples (`hello_globals`, `hello_window`)
- **`build.sh`**: Add `- hello_globals` and `- hello_window` commands

## What We Are NOT Doing

- **No object map.** The application tracks its own IDs.
- **No event queue.** Events are processed inline in the read loop.
- **No callbacks or dispatch tables.** The `if`/`switch` is the dispatch.
- **No proxy lifecycle manager.** The application knows when it creates and destroys objects.
- **No demarshal macro (yet).** Manual `read_u32`/`read_string` is enough for hello world. A compile-time demarshal can come later as a convenience, but it's not required.

## Dependencies Between Tasks

Tasks 1, 3, 4, and 6 are independent -- can be done in parallel.

Task 5 depends on Task 4 (marshal_constructor signature must change first).

Task 2 depends on Tasks 1 and 3 (needs read_string for parsing globals, needs bind for returning registry_id).

Tasks 7 and 8 depend on Task 5 (tests and regeneration need the new signatures).

Task 9 (hello_globals) depends on Tasks 2 and 8 -- first live test against Hyprland.

Task 10 (hello_window) depends on Tasks 2, 6, and 8 -- the milestone, black pixels on screen.

Task 11 (build system) depends on Tasks 9 and 10.

## Open Questions

1. **`wl_registry.bind` -- hand-write or generate?** Hand-writing is simpler (one function, one special case). Updating the generator is more "correct" but adds complexity for a single function. **Recommendation:** Hand-write it in a separate file loaded after the generated one, or modify the generated file with a comment marking it as hand-edited.

2. **Buffer compaction in `connection_read`.** The current implementation compacts on every read. For the event loop this is fine, but worth noting: the string slices returned by `read_string` point into the receive buffer and are only valid until the next `connection_read` call. Applications must copy strings they want to keep.

3. **Error handling.** `wl_display.error` events are fatal protocol errors. The hello world should check for them and print a diagnostic. This is just an opcode check in the event loop -- no special infrastructure needed.
