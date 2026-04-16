# Noise Reduction Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the conn-on-every-struct API with a message-shaped API: MessageBuilder (explicit param, string-builder pattern), ReceiveBuffer (session-owned), Connection (identity only).

**Architecture:** Split Connection into three types. Marshal macro and generated code target MessageBuilder instead of Connection. Session holds ambient state (Connection, ReceiveBuffer, globals) via `#add_context`. Interface structs shrink to `id: u32` + `version: u32` with compile-time defaults.

**Tech Stack:** Jai, compile-time metaprogramming (`#expand`, `#insert #run`, `type_info`), `#add_context`

**Build/test commands:**
- `./build.sh - marshal_test` — 9 marshal macro tests
- `./build.sh - wire_test` — 20 wire protocol tests
- `./build.sh - compile_test` — 9 compilation smoke tests (imports generated module)
- `./build.sh - gen_test` — 36 generator tests
- `./build.sh - generate` — regenerate all 175 interfaces
- `./build.sh - hello_window` — live integration test (needs running Hyprland)

---

### Task 1: Split Connection into Connection / MessageBuilder / ReceiveBuffer

The foundation. Everything else builds on these types.

**Files:**
- Modify: `modules/wayland/connection.jai`

**Step 1: Define the three new types**

Replace the monolithic Connection struct with:

```jai
Connection :: struct {
    socket_fd: s32 = -1;
    next_id: u32 = 1;
}

MessageBuilder :: struct ($MMS: u32 = MAX_MESSAGE_SIZE * 2, $MFDS: u32 = MAX_FDS_OUT) {
    out_buf: [MMS] u8;
    out_used: u32;
    out_fds: [MFDS] s32;
    out_fds_count: u32;
}

ReceiveBuffer :: struct ($MMS: u32 = MAX_MESSAGE_SIZE * 4, $MFDS: u32 = MAX_FDS_OUT) {
    in_buf: [MMS] u8;
    in_used: u32;
    in_read: u32;
    in_fds: [MFDS] s32;
    in_fds_count: u32;
    in_fds_read: u32;
}
```

**Step 2: Retarget queue helpers to MessageBuilder**

Rename and retarget:
- `connection_queue(conn, data, size)` -> `message_queue(batch: *MessageBuilder, data: *u8, size: u32)`
- `connection_queue_fd(conn, fd)` -> `message_queue_fd(batch: *MessageBuilder, fd: s32)`

Same bodies, just operating on `batch.out_buf`/`batch.out_used`/`batch.out_fds` instead of `conn.out_buf` etc.

**Step 3: Retarget peek/consume/pop helpers to ReceiveBuffer**

Rename and retarget:
- `connection_peek_message(conn)` -> `receive_peek_message(buf: *ReceiveBuffer) -> *u8, u32`
- `connection_consume_message(conn, size)` -> `receive_consume_message(buf: *ReceiveBuffer, size: u32)`
- `connection_pop_fd(conn)` -> `receive_pop_fd(buf: *ReceiveBuffer) -> s32`

**Step 4: Create wayland_send, wayland_receive, wayland_send_receive**

```jai
wayland_send :: (conn: *Connection, batch: *MessageBuilder) -> bool {
    // Body from current connection_flush, but reads batch.out_buf/out_fds
    // and writes to conn.socket_fd
}

wayland_receive :: (conn: *Connection, buf: *ReceiveBuffer) -> s64 {
    // Body from current connection_read, but operates on buf.in_buf/in_fds
    // and reads from conn.socket_fd
}

wayland_send_receive :: (conn: *Connection, batch: *MessageBuilder, buf: *ReceiveBuffer) -> bool, s64 {
    if !wayland_send(conn, batch) return false, 0;
    bts := wayland_receive(conn, buf);
    return true, bts;
}
```

**Step 5: Keep wayland_connect and wayland_disconnect unchanged**

They operate on `conn.socket_fd` only — still correct with the slimmed Connection.

**Step 6: Keep allocate_id unchanged**

Still operates on `conn.next_id` — still correct.

**Step 7: Remove debug print statements from connection_flush (now wayland_send)**

The current `connection_flush` has `print("flushing... ")` and `print("iov: % ", ...)` debug output. Remove these in the new `wayland_send`.

**Step 8: Run wire tests**

Run: `./build.sh - wire_test`

Expected: Wire tests should still pass — they test `read_*`/`write_*`/`pack_header`/`unpack_header` which are unchanged. Some tests create a `Connection` and call `connection_queue` — these will fail because those functions are renamed. Fix them:
- Change `Connection` usage in wire tests that test queue/peek/consume to use `MessageBuilder`/`ReceiveBuffer`
- Update function names: `connection_queue` -> `message_queue`, `connection_peek_message` -> `receive_peek_message`, `connection_consume_message` -> `receive_consume_message`

Run: `./build.sh - wire_test`
Expected: All 20 tests pass.

**Step 9: Commit**

```
feat: split Connection into Connection/MessageBuilder/ReceiveBuffer
```

---

### Task 2: Update marshal macro to target MessageBuilder

**Files:**
- Modify: `modules/wayland/marshal.jai`

**Step 1: Change marshal signatures**

```jai
// Before:
marshal :: (conn: *Connection, object_id: u32, opcode: u16, args: *$T) #expand
marshal_constructor :: (conn: *Connection, object_id: u32, opcode: u16, new_id: u32, args: *$T) #expand

// After:
marshal :: (batch: *MessageBuilder, object_id: u32, opcode: u16, args: *$T) #expand
marshal_constructor :: (batch: *MessageBuilder, object_id: u32, opcode: u16, new_id: u32, args: *$T) #expand
```

**Step 2: Update emitted code in all four emit functions**

In `emit_fixed_path`, `emit_variable_path`, `emit_constructor_fixed_path`, `emit_constructor_variable_path`:
- Change all `connection_queue(conn,` -> `message_queue(batch,`
- Change all `connection_queue_fd(conn,` -> `message_queue_fd(batch,`

These are string literals in `print_to_builder` calls. Six occurrences total across the four functions.

**Step 3: Update marshal tests**

In `tests/marshal_test.jai`:
- Every test currently creates `conn: Wayland.Connection;` and calls `Wayland.marshal(*conn, ...)`, then checks `conn.out_used`, `conn.out_buf`, `conn.out_fds`, etc.
- Change to: create `batch: Wayland.MessageBuilder;` and call `Wayland.marshal(*batch, ...)`, then check `batch.out_used`, `batch.out_buf`, `batch.out_fds`, etc.
- Same for `marshal_constructor` tests.

**Step 4: Run marshal tests**

Run: `./build.sh - marshal_test`
Expected: All 9 tests pass.

**Step 5: Commit**

```
feat: marshal macro targets MessageBuilder instead of Connection
```

---

### Task 3: Update generator — struct and request function signatures

**Files:**
- Modify: `src/generator.jai` — three functions: `generate_interface_struct`, `generate_request`, and `generate_module_root`

**Step 1: Update generate_interface_struct (line 477)**

Change from:
```jai
print_to_builder(*sb, "% :: struct {\n", type_name);
print_to_builder(*sb, "    id: u32;\n");
print_to_builder(*sb, "    version: u32;\n");
print_to_builder(*sb, "    conn: *Connection;\n");
print_to_builder(*sb, "}\n");
```

To:
```jai
print_to_builder(*sb, "% :: struct {\n", type_name);
print_to_builder(*sb, "    id: u32;\n");
descriptor_name := tprint("%_INTERFACE", to_upper_snake(iface.name));
print_to_builder(*sb, "    version: u32 = #run %.version;\n", descriptor_name);
print_to_builder(*sb, "}\n");
```

Note: The struct references the interface descriptor which is generated later in the same file. This works because `#run` executes at compile time after all declarations are visible. But the struct appears before the descriptor constant in the file. Jai resolves this because `#run` is lazy — it runs when needed, not at parse time. Verify this compiles in Step 6.

**Step 2: Update generate_request (line 307) — add batch param**

Change the function signature emission from:
```jai
print_to_builder(*sb, "% :: (self: *%", func_name, type_name);
```

To:
```jai
print_to_builder(*sb, "% :: (batch: *MessageBuilder, self: *%", func_name, type_name);
```

**Step 3: Update generate_request — marshal calls**

Change the three `marshal` call emissions:
- Line 429: `marshal_constructor(self.conn, self.id, %, new_id, *args)` -> `marshal_constructor(batch, self.id, %, new_id, *args)`
- Line 447: `marshal(self.conn, self.id, %, *args)` -> `marshal(batch, self.id, %, *args)` (destructor path)
- Line 466: `marshal(self.conn, self.id, %, *args)` -> `marshal(batch, self.id, %, *args)` (normal path)

**Step 4: Update generate_request — untyped new_id (wl_registry.bind) path**

The untyped new_id path (line 374-411) emits raw wire encoding, not marshal calls. Change:
- Line 411: `connection_queue(self.conn, _buf.data, _offset)` -> `message_queue(batch, _buf.data, _offset)`

**Step 5: Update generate_module_root (line 690)**

Add `#load "session.jai";` to the generated module root, after `#load "registry.jai";`:
```jai
print_to_builder(*sb, "#load \"session.jai\";\n");
```

**Step 6: Update generator tests**

In `tests/generator_test.jai`, update any tests that check:
- Struct generation — should no longer expect `conn: *Connection;`, should expect `version: u32 = #run ...`
- Request function signatures — should expect `batch: *MessageBuilder` as first param
- Marshal call output — should expect `marshal(batch,` and `marshal_constructor(batch,` instead of `marshal(self.conn,`
- Untyped new_id — should expect `message_queue(batch,` instead of `connection_queue(self.conn,`

Run: `./build.sh - gen_test`
Expected: All 36 tests pass.

**Step 7: Commit**

```
feat: generator emits MessageBuilder-based request functions, version defaults
```

---

### Task 4: Regenerate all 175 interfaces

**Files:**
- Modify: All files under `modules/wayland/` (auto-generated)

**Step 1: Run the generator**

Run: `./build.sh - generate`
Expected: Completes successfully, regenerates all interface files.

**Step 2: Verify with compile test**

Run: `./build.sh - compile_test`

This will fail because `tests/compile_test.jai` has tests that depend on the old struct shape:
- `test_conn_field` (line 53) asserts `surface.conn == null` — this field no longer exists
- `test_types_exist` (line 7) asserts `s.version == 0` — version now has a non-zero default

**Step 3: Update compile tests**

In `tests/compile_test.jai`:
- Remove `test_conn_field` test entirely (the field doesn't exist anymore)
- Update `test_types_exist`: change `assert(s.version == 0)` to `assert(s.version == WL_SURFACE_INTERFACE.version)`
- Remove the call to `test_conn_field` from `main()`

**Step 4: Run compile tests**

Run: `./build.sh - compile_test`
Expected: All tests pass (now 8 tests instead of 9).

**Step 5: Commit**

```
feat: regenerate all interfaces with MessageBuilder API
```

---

### Task 5: Update session.jai — ReceiveBuffer, for_expansion, context overloads

**Files:**
- Modify: `modules/wayland/session.jai`

**Step 1: Update WaylandSession struct**

Add `recv: ReceiveBuffer;` to the struct. Remove `pool: Pool;` and `#import "Pool";` for now (can be re-added later if needed — keep it simple).

```jai
WaylandSession :: struct {
    conn: Connection;
    recv: ReceiveBuffer;
    registry: Wl_Registry;
    compositor: Wl_Compositor;
    wm_base: Xdg_Wm_Base;
    compositor_name: u32;
    shm_name: u32;
    wm_base_name: u32;
    globals: [..] Global_Info;
}
```

**Step 2: Update for_expansion to use ReceiveBuffer**

Change `for_expansion` to read from `session.recv` instead of calling `connection_read(*conn)` / `connection_peek_message(*conn)`:

```jai
for_expansion :: (session: *WaylandSession, body: Code, flags: For_Flags) #expand {
    {
        while bts := wayland_receive(*session.conn, *session.recv) {
            if bts <= 0 break;
            msg, size := receive_peek_message(*session.recv);
            while msg != null {
                header: WaylandMessageHeader;
                header.object_id, header.opcode, header.msg_size = unpack_header(msg);
                header.payload = msg + HEADER_SIZE;

                if header.object_id == session.wm_base.id && header.opcode == XDG_WM_BASE_PING {
                    serial := read_u32(header.payload);
                    ping_batch: MessageBuilder;
                    xdg_wm_base_pong(*ping_batch, *session.wm_base, serial);
                    wayland_send(*session.conn, *ping_batch);
                } else {
                    `it := header;
                    `it_index := 0;
                    #insert(break=break bts) body;
                }

                receive_consume_message(*session.recv, header.msg_size);
                msg, size = receive_peek_message(*session.recv);
            }
        }
    }
}
```

**Step 3: Add context-based wayland_send overload**

In `connection.jai`, add:
```jai
wayland_send :: (batch: *MessageBuilder) -> bool {
    return wayland_send(*context.wayland_session.conn, batch);
}
```

**Step 4: Update init_wayland_session**

- Remove pool allocator setup (simplify for now)
- Use `wayland_send` / `wayland_receive` with explicit MessageBuilder
- Remove the erroneous `defer wayland_disconnect` inside the setup block
- Use structure literals for interface objects

```jai
init_wayland_session :: () -> bool {
    session := New(WaylandSession);
    context.wayland_session = session;

    if !wayland_connect(*session.conn) {
        print("Could not connect to Wayland compositor.\n");
        free(session);
        return false;
    }

    discover_globals();

    session.compositor_name = find_global("wl_compositor");
    session.shm_name        = find_global("wl_shm");
    session.wm_base_name    = find_global("xdg_wm_base");

    if session.compositor_name == 0 || session.shm_name == 0 || session.wm_base_name == 0 {
        print("Missing required globals\n");
        wayland_disconnect(*session.conn);
        free(session);
        return false;
    }

    session.compositor = Wl_Compositor.{ id = allocate_id() };
    session.wm_base    = Xdg_Wm_Base.{ id = allocate_id() };

    batch: MessageBuilder;
    wl_registry_bind(*batch, *session.registry, session.compositor_name, "wl_compositor", 6, session.compositor.id);
    wl_registry_bind(*batch, *session.registry, session.wm_base_name, "xdg_wm_base", 6, session.wm_base.id);
    wayland_send(*session.conn, *batch);

    return true;
}
```

**Step 5: Update end_wayland_session**

```jai
end_wayland_session :: () {
    wayland_disconnect(*context.wayland_session.conn);
    free(context.wayland_session);
}
```

**Step 6: Update convenience accessors**

Keep `session()`, `connection()`, `registry()`, `compositor()`, `wm_base()`, `shm_name()` — they just return pointers/values from context. No changes needed except removing any pool references.

**Step 7: Commit**

```
feat: session uses ReceiveBuffer, for_expansion handles ping/pong via MessageBuilder
```

---

### Task 6: Update registry.jai — discover_globals uses MessageBuilder

**Files:**
- Modify: `modules/wayland/registry.jai`

**Step 1: Update the explicit-connection overload**

`discover_globals(conn: *Connection)` currently calls `connection_flush`, `connection_read`, `connection_peek_message`, `connection_consume_message`. Update to use MessageBuilder and ReceiveBuffer:

```jai
discover_globals :: (conn: *Connection) -> [] Global_Info, u32 {
    display := init_display(conn);

    registry_id := allocate_id(conn);
    sync_id := allocate_id(conn);

    batch: MessageBuilder;
    wl_display_get_registry(*batch, *display, registry_id);
    wl_display_sync(*batch, *display, sync_id);
    wayland_send(conn, *batch);

    recv: ReceiveBuffer;
    globals: [..] Global_Info;

    done := false;
    while !done && wayland_receive(conn, *recv) > 0 {
        msg, size := receive_peek_message(*recv);
        while msg != null {
            object_id, opcode, _ := unpack_header(msg);
            payload := msg + HEADER_SIZE;

            if object_id == registry_id {
                if opcode == WL_REGISTRY_GLOBAL {
                    offset: u32 = 0;
                    gname := read_u32(payload + offset);
                    offset += 4;
                    iface, iface_bytes := read_string(payload + offset);
                    offset += iface_bytes;
                    ver := read_u32(payload + offset);
                    array_add(*globals, .{
                        name = gname,
                        interface_name = copy_string(iface),
                        version = ver,
                    });
                }
            } else if object_id == sync_id {
                done = true;
            }

            receive_consume_message(*recv, size);
            msg, size = receive_peek_message(*recv);
        }
    }

    return globals, registry_id;
}
```

**Step 2: Update the context-based overload**

Same pattern but uses `context.wayland_session.conn` and `context.wayland_session.recv`, stores globals into `context.wayland_session.globals`, and stores the registry into `context.wayland_session.registry`:

```jai
discover_globals :: () -> u32 {
    session := context.wayland_session;
    display := init_display(*session.conn);

    registry_id := allocate_id();
    sync_id := allocate_id();

    batch: MessageBuilder;
    wl_display_get_registry(*batch, *display, registry_id);
    wl_display_sync(*batch, *display, sync_id);
    wayland_send(*session.conn, *batch);

    done := false;
    while !done && wayland_receive(*session.conn, *session.recv) > 0 {
        msg, size := receive_peek_message(*session.recv);
        while msg != null {
            object_id, opcode, _ := unpack_header(msg);
            payload := msg + HEADER_SIZE;

            if object_id == registry_id {
                if opcode == WL_REGISTRY_GLOBAL {
                    offset: u32 = 0;
                    gname := read_u32(payload + offset);
                    offset += 4;
                    iface, iface_bytes := read_string(payload + offset);
                    offset += iface_bytes;
                    ver := read_u32(payload + offset);
                    array_add(*session.globals, .{
                        name = gname,
                        interface_name = copy_string(iface),
                        version = ver,
                    });
                }
            } else if object_id == sync_id {
                done = true;
            }

            receive_consume_message(*session.recv, size);
            msg, size = receive_peek_message(*session.recv);
        }
    }

    session.registry = Wl_Registry.{ id = registry_id };
    return registry_id;
}
```

**Step 3: Commit**

```
feat: registry discovery uses MessageBuilder/ReceiveBuffer
```

---

### Task 7: Update hello_window.jai

**Files:**
- Modify: `examples/hello_window.jai`

**Step 1: Rewrite to new API**

Use structure literals, MessageBuilder batches, session for_expansion:

```jai
#import,dir "../modules/wayland";
#import "Basic";
#import "POSIX";

WIDTH  :: 640;
HEIGHT :: 480;
STRIDE :: WIDTH * 4;
BUF_SIZE :: STRIDE * HEIGHT;

main :: () {
    if !init_wayland_session() {
        print("Failed to create Wayland session\n");
        return;
    }
    defer end_wayland_session();

    // Bind wl_shm
    shm := Wl_Shm.{ id = allocate_id() };
    {
        batch: MessageBuilder;
        wl_registry_bind(*batch, registry(), shm_name(), "wl_shm", 1, shm.id);
        wayland_send(*batch);
    }

    // Drain wl_shm.format events
    drain_messages();

    // Create surface + window role
    surface := Wl_Surface.{ id = allocate_id() };
    xdg_surface := Xdg_Surface.{ id = allocate_id() };
    toplevel := Xdg_Toplevel.{ id = allocate_id() };
    {
        batch: MessageBuilder;
        wl_compositor_create_surface(*batch, compositor(), surface.id);
        xdg_wm_base_get_xdg_surface(*batch, wm_base(), xdg_surface.id, *surface);
        xdg_surface_get_toplevel(*batch, *xdg_surface, toplevel.id);
        xdg_toplevel_set_title(*batch, *toplevel, "hello");
        wl_surface_commit(*batch, *surface);
        wayland_send(*batch);
    }

    // Wait for xdg_surface.configure
    configure_serial: u32 = 0;
    for session() {
        if it.object_id == xdg_surface.id && it.opcode == XDG_SURFACE_CONFIGURE {
            configure_serial = read_u32(it.payload);
            break;
        }
    }

    if configure_serial == 0 {
        print("Did not receive xdg_surface.configure\n");
        return;
    }

    // Create shared memory buffer
    fd := memfd_create("wayland-shm".data, 0);
    if fd < 0 { print("memfd_create failed\n"); return; }
    ftruncate(fd, BUF_SIZE);
    data := mmap(null, BUF_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if data == cast(*void) -1 { print("mmap failed\n"); return; }
    memset(data, 0, BUF_SIZE);

    pool := Wl_Shm_Pool.{ id = allocate_id() };
    buffer := Wl_Buffer.{ id = allocate_id() };
    {
        batch: MessageBuilder;
        xdg_surface_ack_configure(*batch, *xdg_surface, configure_serial);
        wl_shm_create_pool(*batch, *shm, pool.id, cast(Fd) fd, cast(s32) BUF_SIZE);
        wl_shm_pool_create_buffer(*batch, *pool, buffer.id,
            offset = 0, width = WIDTH, height = HEIGHT,
            stride = STRIDE, format = cast(u32) Wl_Shm_Format.XRGB8888);
        wl_shm_pool_destroy(*batch, *pool);
        wl_surface_attach(*batch, *surface, *buffer, 0, 0);
        wl_surface_damage_buffer(*batch, *surface, 0, 0, WIDTH, HEIGHT);
        wl_surface_commit(*batch, *surface);
        wayland_send(*batch);
    }

    print("Window displayed. Close the window or press Ctrl+C to exit.\n");

    // Event loop — ping/pong handled by for_expansion
    for session() {
        if it.object_id == toplevel.id && it.opcode == XDG_TOPLEVEL_CLOSE {
            print("Close requested.\n");
            break;
        } else if it.object_id == 1 && it.opcode == WL_DISPLAY_ERROR {
            err_obj := read_u32(it.payload);
            err_code := read_u32(it.payload + 4);
            err_msg, _ := read_string(it.payload + 8);
            print("FATAL: wl_display.error object=% code=%: %\n", err_obj, err_code, err_msg);
            break;
        }
    }

    munmap(data, BUF_SIZE);
    close(fd);
}

drain_messages :: () {
    conn := connection();
    recv := *context.wayland_session.recv;
    wayland_receive(conn, recv);
    msg, size := receive_peek_message(recv);
    while msg != null {
        _, _, msg_size := unpack_header(msg);
        receive_consume_message(recv, msg_size);
        msg, size = receive_peek_message(recv);
    }
}
```

**Step 2: Build and run**

Run: `./build.sh - hello_window`
Expected: Black 640x480 window appears on Hyprland. Close cleanly.

**Step 3: Commit**

```
feat: hello_window uses message-shaped API
```

---

### Task 8: Update hello_globals.jai (if it exists on this branch)

**Files:**
- Modify: `examples/hello_globals.jai`

**Step 1: Check if hello_globals.jai needs updating**

If it uses the old `Connection`-based `discover_globals`, update to use the session API or the explicit overload with MessageBuilder/ReceiveBuffer. If it already uses `init_wayland_session()`, it may just work.

**Step 2: Build and run**

Run: `./build.sh - hello_globals`
Expected: Prints all globals from Hyprland.

**Step 3: Commit (if changes needed)**

```
feat: hello_globals uses message-shaped API
```

---

### Task 9: Run full test suite

**Step 1: Run all test suites**

Run each in sequence:
- `./build.sh - test` (XML tests)
- `./build.sh - gen_test` (generator tests)
- `./build.sh - wire_test` (wire protocol tests)
- `./build.sh - marshal_test` (marshal macro tests)
- `./build.sh - compile_test` (compilation smoke tests)

Expected: All pass.

**Step 2: Run live examples**

- `./build.sh - hello_globals` — prints globals
- `./build.sh - hello_window` — shows black window

**Step 3: Final commit if any fixups needed**

---

### Task 10: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Update architecture section**

Document the new Connection/MessageBuilder/ReceiveBuffer split. Update the wire protocol design section to describe `message_queue`/`message_queue_fd` instead of `connection_queue`. Document the session + `#add_context` pattern. Update the "Client API" section to describe the message-shaped API.

**Step 2: Commit**

```
docs: update CLAUDE.md for message-shaped API
```
