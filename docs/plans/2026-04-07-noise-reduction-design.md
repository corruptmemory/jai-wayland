# Noise Reduction: Message-Shaped API

**Date:** 2026-04-07
**Branch:** noise-reduction
**Goal:** Eliminate boilerplate from the client API. If Wayland is "just a socket protocol," the API should be message-shaped: build a batch of requests, send them, read responses.

## Motivation

The Phase 4 API works but has too much ceremony per object:
- Every interface struct carries `conn: *Connection` (8 bytes, 175 structs, set manually every time)
- `connection_flush()` is a footgun — easy to forget, impossible to enforce via the type system
- Version must be set explicitly even though the correct value is known at compile time
- Object initialization takes 3-4 lines instead of 1

## Design Principles

1. **Message-shaped** — separate "what I want to say" (MessageBuilder) from "the connection" (Connection) from "what I heard" (ReceiveBuffer)
2. **Explicit batching** — MessageBuilder is the batch. `wayland_send` is the send. No hidden flush state.
3. **String builder pattern** — MessageBuilder is passed explicitly to request functions, like Jai's `*String_Builder`. Composable across function boundaries.
4. **Session context for ambient state** — Connection, ReceiveBuffer, bound globals live in `#add_context`. Set up once, always available.
5. **Structure literals** — Jai's `T.{ field = value }` syntax eliminates multi-line object init.

## Core Types

### Connection (identity only)

```jai
Connection :: struct {
    socket_fd: s32 = -1;
    next_id: u32 = 1;
}
```

Owns the socket and ID allocator. Nothing else.

### MessageBuilder (outgoing batch)

```jai
MessageBuilder :: struct ($MMS: u32 = MAX_MESSAGE_SIZE * 2, $MFDS: u32 = MAX_FDS_OUT) {
    out_buf: [MMS] u8;
    out_used: u32;
    out_fds: [MFDS] s32;
    out_fds_count: u32;
}
```

Polymorphic buffer sizes — tune per use case without runtime cost. Stack-allocatable for typical batches.

### ReceiveBuffer (incoming data)

```jai
ReceiveBuffer :: struct ($MMS: u32 = MAX_MESSAGE_SIZE * 4, $MFDS: u32 = MAX_FDS_OUT) {
    in_buf: [MMS] u8;
    in_used: u32;
    in_read: u32;
    in_fds: [MFDS] s32;
    in_fds_count: u32;
    in_fds_read: u32;
}
```

### Interface structs (just id + version)

```jai
Wl_Compositor :: struct {
    id: u32;
    version: u32 = #run WL_COMPOSITOR_INTERFACE.version;
}
```

No `conn` field. Version defaults to the protocol-defined value. Initialized with structure literals:

```jai
compositor := Wl_Compositor.{ id = allocate_id() };
```

## Send/Receive Primitives

```jai
wayland_send :: (conn: *Connection, batch: *MessageBuilder) -> bool
wayland_receive :: (conn: *Connection, buf: *ReceiveBuffer) -> s64
wayland_send_receive :: (conn: *Connection, batch: *MessageBuilder, buf: *ReceiveBuffer) -> bool, s64
```

Buffer helpers retargeted:
- `message_queue(batch, data, size)` — replaces `connection_queue`
- `message_queue_fd(batch, fd)` — replaces `connection_queue_fd`
- `receive_peek_message(buf)` — replaces `connection_peek_message`
- `receive_consume_message(buf, size)` — replaces `connection_consume_message`
- `receive_pop_fd(buf)` — replaces `connection_pop_fd`

## Generated Request Functions

Every request function gets `batch: *MessageBuilder` as first param:

```jai
// Before:
wl_compositor_create_surface :: (self: *Wl_Compositor, new_id: u32) { ... }

// After:
wl_compositor_create_surface :: (batch: *MessageBuilder, self: *Wl_Compositor, new_id: u32) { ... }
```

Marshal macro signature:

```jai
marshal :: (batch: *MessageBuilder, object_id: u32, opcode: u16, args: *$T) #expand
marshal_constructor :: (batch: *MessageBuilder, object_id: u32, opcode: u16, new_id: u32, args: *$T) #expand
```

Emitted code uses `message_queue` / `message_queue_fd` instead of `connection_queue` / `connection_queue_fd`.

## Session + Context

```jai
WaylandSession :: struct {
    conn: Connection;
    recv: ReceiveBuffer;
    globals: [..] Global_Info;
    registry: Wl_Registry;
    compositor: Wl_Compositor;
    wm_base: Xdg_Wm_Base;
    compositor_name: u32;
    shm_name: u32;
    wm_base_name: u32;
}

#add_context wayland_session: *WaylandSession;
```

Context-based convenience overloads:
- `wayland_send(batch)` — pulls connection from context
- `allocate_id()` — pulls connection from context
- `session()`, `connection()`, `registry()`, `compositor()`, `wm_base()` — accessors

`for_expansion` on `*WaylandSession` iterates the ReceiveBuffer, handles ping/pong transparently, yields `WaylandMessageHeader` for everything else.

## Example: Hello Window

```jai
init_wayland_session();
defer end_wayland_session();

shm := Wl_Shm.{ id = allocate_id() };

batch: MessageBuilder;
wl_registry_bind(*batch, registry(), shm_name(), "wl_shm", 1, shm.id);
wayland_send(*batch);

drain_messages();  // consume wl_shm.format events

surface := Wl_Surface.{ id = allocate_id() };
xdg_surface := Xdg_Surface.{ id = allocate_id() };
toplevel := Xdg_Toplevel.{ id = allocate_id() };

batch2: MessageBuilder;
wl_compositor_create_surface(*batch2, *compositor, surface.id);
xdg_wm_base_get_xdg_surface(*batch2, *wm_base, xdg_surface.id, *surface);
xdg_surface_get_toplevel(*batch2, *xdg_surface, toplevel.id);
xdg_toplevel_set_title(*batch2, *toplevel, "hello");
wl_surface_commit(*batch2, *surface);
wayland_send(*batch2);

// Wait for configure, ack it, create buffer, attach, commit ...

for session() {
    if it.object_id == toplevel.id && it.opcode == XDG_TOPLEVEL_CLOSE {
        break;
    }
}
```

## Changes by File

| Component | Change |
|---|---|
| `connection.jai` | Split Connection into Connection/MessageBuilder/ReceiveBuffer. Queue/peek/consume retargeted. Send/receive functions added. |
| `marshal.jai` | `marshal`/`marshal_constructor` take `*MessageBuilder`. Emitted code uses `message_queue`/`message_queue_fd`. |
| `generator.jai` | Struct drops `conn`, adds version default. Request functions gain `batch: *MessageBuilder` first param. Emits `message_queue` calls. |
| `session.jai` | WaylandSession holds ReceiveBuffer. `for_expansion` reads from it. Context overloads for send/allocate. |
| `registry.jai` | `discover_globals` uses MessageBuilder internally for its own send/receive cycle. |
| All 175 generated interfaces | Regenerated — structs shrink, request functions gain `batch` param. |
| `examples/` | Updated to new API. |
| Tests | Marshal/wire/compile tests updated for new types. |
