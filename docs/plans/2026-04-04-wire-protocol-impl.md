# Phase 3: Wire Protocol Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement the Wayland wire protocol building blocks — socket connect, message framing, fd passing, and compile-time marshalling — so the generated request stubs become real serialization code.

**Architecture:** A compile-time `marshal` macro (`#expand` + `#insert #run`) walks request arg structs via `type_info` at compile time and emits type-specific byte-packing code. `#inline` primitive writers ensure the optimizer sees only raw stores. Socket I/O uses `sendmsg`/`recvmsg` with `SCM_RIGHTS` for fd passing. `Fd :: #type,distinct s32` tags file descriptors for the compile-time walker.

**Tech Stack:** Jai standard library (`Socket`, `POSIX`, `Basic`, `Compiler`). No external dependencies.

**Key references:**
- `vendor/reference/zig-wayland/src/` — wire format, message layout
- `vendor/reference/wayland-rs/wayland-backend/src/rs/` — socket.rs (fd passing), wire.rs (framing)
- `~/jai/jai/modules/Socket/` — sendmsg, recvmsg, msghdr, cmsghdr, CMSG_* helpers, SCM.RIGHTS
- `~/jai/jai/modules/POSIX/` — close, iovec
- `~/projects/jai-http/modules/csv/module.jai` — compile-time struct-walking macro pattern

**Wire format (native-endian, 4-byte aligned):**
```
Header (8 bytes):
  [0..3] object_id: u32
  [4..7] (size << 16) | opcode: u32

Arguments (variable):
  int/uint/fixed/object/new_id: 4 bytes each
  string: u32 length (incl NUL) + data + NUL + pad to 4
  array:  u32 length + data + pad to 4
  fd:     NOT on wire — passed via SCM_RIGHTS ancillary data
```

**New files:**
- `src/wire.jai` — message framing, inline writers, compile-time marshal macro
- `src/connection.jai` — socket connect, buffers, fd queue, sendmsg/recvmsg
- `tests/wire_test.jai` — unit tests for wire primitives
- `tests/marshal_test.jai` — compilation tests for marshal macro

**Modified files:**
- `modules/wayland/types.jai` — add `Fd` distinct type, `Connection` forward-decl
- `src/generator.jai` — emit `Fd` for fd args, generate request arg structs, emit marshal calls
- `src/generate_main.jai` — emit `#import` for wire module in generated code
- `tests/compile_test.jai` — verify marshal-based generated code compiles
- `first.jai` — add `wire_test` and `marshal_test` build targets

---

### Task 1: Shared Types Foundation

Add `Fd` distinct type and wire-related shared types to the generated module.

**Files:**
- Modify: `modules/wayland/types.jai`

**Step 1: Update types.jai**

Add after the existing `Fixed` definition:

```jai
// File descriptor passed via SCM_RIGHTS ancillary data, not in message body.
// #type,distinct ensures compile-time marshal walker can distinguish Fd from s32.
Fd :: #type,distinct s32;

// Wire message header size in bytes.
HEADER_SIZE :: 8;

// Maximum message size (from libwayland compatibility).
MAX_MESSAGE_SIZE :: 4096;

// Maximum fds per sendmsg call.
MAX_FDS_OUT :: 28;
```

**Step 2: Commit**

```bash
git add modules/wayland/types.jai
git commit -m "feat(wire): add Fd distinct type and wire constants to types.jai"
```

---

### Task 2: Wire Primitives — Header and Inline Writers (TDD)

Implement message header packing/unpacking and `#inline` primitive writers for fixed-size arg types.

**Files:**
- Create: `src/wire.jai`
- Create: `tests/wire_test.jai`
- Modify: `first.jai` — add `wire_test` build target

**Step 1: Add wire_test build target to first.jai**

Add a new case in the arg dispatch and a new builder:

```jai
case "wire_test";
    build_and_run_test("wire_tests", "wire_tests", "tests/wire_test.jai", "build_tests");
    set_build_options_dc(.{do_output=false});
```

Update the error message to include `wire_test`.

**Step 2: Write failing tests for header and inline writers**

Create `tests/wire_test.jai`:

```jai
#import "Basic";
Wayland :: #import,dir "../modules/wayland";

main :: () {
    print("=== Wire Protocol Tests ===\n\n");

    test_write_u32();
    test_write_s32();
    test_read_u32();
    test_read_s32();
    test_pack_header();
    test_unpack_header();
    test_message_size_from_header();

    print("\n=== All wire tests passed ===\n");
}

test_write_u32 :: () {
    buf: [4] u8;
    write_u32(buf.data, 0x12345678);
    // Native-endian: on x86-64, bytes are [0x78, 0x56, 0x34, 0x12]
    result := (cast(*u32) buf.data).*;
    assert(result == 0x12345678, "write_u32 failed");
    print("  PASS: write_u32\n");
}

test_write_s32 :: () {
    buf: [4] u8;
    write_s32(buf.data, -42);
    result := (cast(*s32) buf.data).*;
    assert(result == -42, "write_s32 failed");
    print("  PASS: write_s32\n");
}

test_read_u32 :: () {
    buf: [4] u8;
    (cast(*u32) buf.data).* = 0xDEADBEEF;
    result := read_u32(buf.data);
    assert(result == 0xDEADBEEF, "read_u32 failed");
    print("  PASS: read_u32\n");
}

test_read_s32 :: () {
    buf: [4] u8;
    (cast(*s32) buf.data).* = -1;
    result := read_s32(buf.data);
    assert(result == -1, "read_s32 failed");
    print("  PASS: read_s32\n");
}

test_pack_header :: () {
    buf: [8] u8;
    pack_header(buf.data, object_id = 5, opcode = 1, size = 20);
    obj_id := (cast(*u32) buf.data).*;
    assert(obj_id == 5, "pack_header: wrong object_id");
    word2 := (cast(*u32) (buf.data + 4)).*;
    assert(word2 == (20 << 16) | 1, "pack_header: wrong size|opcode");
    print("  PASS: pack_header\n");
}

test_unpack_header :: () {
    buf: [8] u8;
    (cast(*u32) buf.data).* = 7;
    (cast(*u32) (buf.data + 4)).* = (24 << 16) | 3;
    object_id, opcode, size := unpack_header(buf.data);
    assert(object_id == 7, "unpack_header: wrong object_id");
    assert(opcode == 3, "unpack_header: wrong opcode");
    assert(size == 24, "unpack_header: wrong size");
    print("  PASS: unpack_header\n");
}

test_message_size_from_header :: () {
    buf: [8] u8;
    (cast(*u32) buf.data).* = 1;
    (cast(*u32) (buf.data + 4)).* = (32 << 16) | 0;
    _, _, size := unpack_header(buf.data);
    assert(size == 32);
    print("  PASS: message_size_from_header\n");
}

// Import wire functions — these will be in the wayland module
write_u32 :: Wayland.write_u32;
write_s32 :: Wayland.write_s32;
read_u32  :: Wayland.read_u32;
read_s32  :: Wayland.read_s32;
pack_header   :: Wayland.pack_header;
unpack_header :: Wayland.unpack_header;
```

**Step 3: Run tests, verify they fail**

```bash
./build.sh - wire_test
```

Expected: compilation failure (functions don't exist yet).

**Step 4: Implement wire primitives**

Create `src/wire.jai`:

```jai
// Wire protocol primitives for Wayland message framing.
// All writes are native-endian (both sides on same machine).

write_u32 :: (dst: *u8, value: u32) #inline {
    (cast(*u32) dst).* = value;
}

write_s32 :: (dst: *u8, value: s32) #inline {
    (cast(*s32) dst).* = value;
}

read_u32 :: (src: *u8) -> u32 #inline {
    return (cast(*u32) src).*;
}

read_s32 :: (src: *u8) -> s32 #inline {
    return (cast(*s32) src).*;
}

// Pack a Wayland message header into 8 bytes.
// Format: [object_id: u32][size << 16 | opcode: u32]
pack_header :: (dst: *u8, object_id: u32, opcode: u16, size: u32) #inline {
    write_u32(dst, object_id);
    write_u32(dst + 4, (size << 16) | cast(u32) opcode);
}

// Unpack a Wayland message header from 8 bytes.
// Returns: object_id, opcode, size
unpack_header :: (src: *u8) -> object_id: u32, opcode: u16, size: u32 {
    object_id = read_u32(src);
    word2 := read_u32(src + 4);
    opcode = cast(u16)(word2 & 0xFFFF);
    size = word2 >> 16;
}

// Round up to next 4-byte boundary.
align4 :: (n: u32) -> u32 #inline {
    return (n + 3) & ~cast(u32)3;
}
```

**Step 5: Wire types.jai into the module**

Add a `#load` for wire.jai in `modules/wayland/module.jai`. The wire functions need to be accessible from the generated module. However, since `wire.jai` is source code (not generated), it should live in `src/` and be loaded via the module. 

**Decision:** Place wire primitives directly in `modules/wayland/wire.jai` (alongside `types.jai`) since they're part of the public module API that generated code will call.

Create `modules/wayland/wire.jai` with the above content. Add `#load "wire.jai";` to `modules/wayland/module.jai`.

**Step 6: Run tests, verify they pass**

```bash
./build.sh - wire_test
```

Expected: all 7 tests pass.

**Step 7: Commit**

```bash
git add src/ modules/wayland/ tests/wire_test.jai first.jai
git commit -m "feat(wire): header pack/unpack and inline primitive writers (TDD)"
```

---

### Task 3: String and Array Wire Encoding (TDD)

Implement variable-length serialization for strings and arrays with 4-byte padding.

**Files:**
- Modify: `modules/wayland/wire.jai`
- Modify: `tests/wire_test.jai`

**Step 1: Write failing tests**

Add to `tests/wire_test.jai`:

```jai
test_write_string();
test_write_string_padding();
test_write_string_empty();
test_write_array();
test_write_array_padding();
test_align4();
```

Test implementations:

```jai
test_align4 :: () {
    assert(align4(0) == 0);
    assert(align4(1) == 4);
    assert(align4(2) == 4);
    assert(align4(3) == 4);
    assert(align4(4) == 4);
    assert(align4(5) == 8);
    assert(align4(7) == 8);
    assert(align4(8) == 8);
    print("  PASS: align4\n");
}

test_write_string :: () {
    buf: [64] u8;
    memset(buf.data, 0xCC, 64);  // fill with sentinel

    // "hello" = 5 chars + NUL = 6 bytes length, padded to 8
    // Wire: [6:u32][h][e][l][l][o][\0][pad][pad] = 12 bytes total
    bytes_written := write_string(buf.data, "hello");
    assert(bytes_written == 12, "write_string: wrong byte count");

    length := read_u32(buf.data);
    assert(length == 6, "write_string: wrong length (should include NUL)");

    // Verify string data
    assert(buf[4] == #char "h");
    assert(buf[5] == #char "e");
    assert(buf[9] == 0, "NUL terminator");

    // Verify padding is zeroed
    assert(buf[10] == 0, "padding byte 1");
    assert(buf[11] == 0, "padding byte 2");

    print("  PASS: write_string\n");
}

test_write_string_padding :: () {
    buf: [64] u8;
    // "ab" = 2 chars + NUL = 3 bytes, padded to 4
    // Wire: [3:u32][a][b][\0][pad] = 8 bytes
    bytes_written := write_string(buf.data, "ab");
    assert(bytes_written == 8);

    length := read_u32(buf.data);
    assert(length == 3, "length should be 3 (includes NUL)");
    print("  PASS: write_string_padding\n");
}

test_write_string_empty :: () {
    buf: [64] u8;
    // Empty string: length 0, no data
    // Wire: [0:u32] = 4 bytes
    bytes_written := write_string(buf.data, "");
    assert(bytes_written == 4);
    length := read_u32(buf.data);
    assert(length == 0, "empty string length should be 0");
    print("  PASS: write_string_empty\n");
}

test_write_array :: () {
    buf: [64] u8;
    memset(buf.data, 0xCC, 64);

    data: [5] u8 = .[1, 2, 3, 4, 5];
    // 5 bytes data, padded to 8
    // Wire: [5:u32][1][2][3][4][5][pad][pad][pad] = 12 bytes
    bytes_written := write_array(buf.data, data);
    assert(bytes_written == 12);

    length := read_u32(buf.data);
    assert(length == 5);
    assert(buf[4] == 1);
    assert(buf[8] == 5);
    // Padding zeroed
    assert(buf[9] == 0);
    assert(buf[10] == 0);
    assert(buf[11] == 0);
    print("  PASS: write_array\n");
}

test_write_array_padding :: () {
    buf: [64] u8;
    data: [4] u8 = .[0xAA, 0xBB, 0xCC, 0xDD];
    // 4 bytes exactly aligned, no padding needed
    // Wire: [4:u32][AA][BB][CC][DD] = 8 bytes
    bytes_written := write_array(buf.data, data);
    assert(bytes_written == 8);
    print("  PASS: write_array_padding\n");
}

align4 :: Wayland.align4;
write_string :: Wayland.write_string;
write_array  :: Wayland.write_array;
```

**Step 2: Run tests, verify they fail**

```bash
./build.sh - wire_test
```

**Step 3: Implement string and array writers**

Add to `modules/wayland/wire.jai`:

```jai
// Write a Wayland string to the wire buffer.
// Format: u32 length (including NUL) + data + NUL + zero-padding to 4 bytes.
// Empty string: writes length 0, no data.
// Returns: total bytes written (always 4-byte aligned).
write_string :: (dst: *u8, s: string) -> u32 {
    if s.count == 0 {
        write_u32(dst, 0);
        return 4;
    }
    length := cast(u32)(s.count + 1);  // include NUL
    write_u32(dst, length);
    memcpy(dst + 4, s.data, s.count);
    // NUL terminator
    (dst + 4 + s.count).* = 0;
    // Zero padding
    padded := align4(length);
    for i: length..padded-1 {
        (dst + 4 + i).* = 0;
    }
    return 4 + padded;
}

// Write a Wayland array to the wire buffer.
// Format: u32 length + data + zero-padding to 4 bytes.
// Returns: total bytes written (always 4-byte aligned).
write_array :: (dst: *u8, data: [] u8) -> u32 {
    length := cast(u32) data.count;
    write_u32(dst, length);
    if length > 0 {
        memcpy(dst + 4, data.data, data.count);
        padded := align4(length);
        for i: length..padded-1 {
            (dst + 4 + i).* = 0;
        }
        return 4 + padded;
    }
    return 4;
}
```

**Step 4: Run tests, verify they pass**

```bash
./build.sh - wire_test
```

Expected: all tests pass (7 from Task 2 + 6 new = 13).

**Step 5: Commit**

```bash
git add modules/wayland/wire.jai tests/wire_test.jai
git commit -m "feat(wire): string and array serialization with 4-byte padding (TDD)"
```

---

### Task 4: Socket Connection

Implement Unix domain socket connect to the Wayland compositor.

**Files:**
- Create: `modules/wayland/connection.jai`
- Modify: `modules/wayland/module.jai` — add `#load "connection.jai"`

**Step 1: Implement connection.jai**

```jai
#import "Socket";
#import "POSIX";

// sockaddr_un is not in Jai's Socket module — define it ourselves.
sockaddr_un :: struct {
    sun_family: u16;
    sun_path:   [108] u8;
}

Connection :: struct {
    socket_fd: s32 = -1;

    // Outgoing message buffer
    out_buf:  [MAX_MESSAGE_SIZE * 2] u8;
    out_used: u32;

    // Outgoing fd queue (for SCM_RIGHTS)
    out_fds:      [MAX_FDS_OUT] s32;
    out_fds_count: u32;

    // Incoming message buffer
    in_buf:  [MAX_MESSAGE_SIZE * 4] u8;
    in_used: u32;
    in_read: u32;  // read cursor

    // Incoming fd queue
    in_fds:       [MAX_FDS_OUT] s32;
    in_fds_count: u32;
    in_fds_read:  u32;  // read cursor

    // Object ID allocator (client IDs are odd, starting at 1)
    next_id: u32 = 1;
}

// Connect to the Wayland compositor via $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY.
// Returns true on success, false on failure.
wayland_connect :: (conn: *Connection) -> bool {
    runtime_dir := getenv("XDG_RUNTIME_DIR");
    if !runtime_dir  return false;

    display := getenv("WAYLAND_DISPLAY");
    if !display  display = "wayland-0";

    path := tprint("%/%", to_string(runtime_dir), to_string(display));
    if path.count >= 108  return false;  // path too long for sockaddr_un

    fd := socket(AF_LOCAL, .STREAM, cast(IPPROTO) 0);
    if fd < 0  return false;

    addr: sockaddr_un;
    addr.sun_family = AF_LOCAL;
    memcpy(addr.sun_path.data, path.data, path.count);
    addr.sun_path[path.count] = 0;  // NUL terminate

    result := connect(fd, cast(*sockaddr) *addr, cast(u32)(2 + path.count + 1));
    if result < 0 {
        close(fd);
        return false;
    }

    conn.socket_fd = fd;
    return true;
}

// Disconnect from the compositor.
wayland_disconnect :: (conn: *Connection) {
    if conn.socket_fd >= 0 {
        close(conn.socket_fd);
        conn.socket_fd = -1;
    }
}

// Allocate a new object ID. Client IDs start at 1 and increment.
// (Server IDs start at 0xFF000000 — we don't allocate those.)
allocate_id :: (conn: *Connection) -> u32 {
    id := conn.next_id;
    conn.next_id += 1;
    return id;
}
```

**Step 2: Add #load to module.jai**

Add `#load "connection.jai";` to `modules/wayland/module.jai`.

**Step 3: Verify compilation**

```bash
./build.sh - compile_test
```

Expected: existing compile tests still pass (connection.jai compiles as part of module).

**Step 4: Commit**

```bash
git add modules/wayland/connection.jai modules/wayland/module.jai
git commit -m "feat(wire): Connection struct, Unix socket connect, ID allocator"
```

---

### Task 5: Message Send with SCM_RIGHTS

Implement `connection_flush` using `sendmsg` with ancillary data for fd passing.

**Files:**
- Modify: `modules/wayland/connection.jai`
- Modify: `tests/wire_test.jai` — add buffer management tests

**Step 1: Write tests for buffer queueing**

Add to `tests/wire_test.jai`:

```jai
test_connection_queue_message();
test_connection_queue_fd();
test_connection_queue_multiple();

// ...

test_connection_queue_message :: () {
    conn: Connection;
    buf: [20] u8;
    pack_header(buf.data, object_id = 1, opcode = 0, size = 20);
    write_u32(buf.data + 8, 42);
    write_s32(buf.data + 12, -1);
    write_s32(buf.data + 16, 0);

    connection_queue(conn, buf.data, 20);
    assert(conn.out_used == 20);
    assert(read_u32(conn.out_buf.data) == 1);  // object_id
    print("  PASS: connection_queue_message\n");
}

test_connection_queue_fd :: () {
    conn: Connection;
    connection_queue_fd(*conn, 42);
    assert(conn.out_fds_count == 1);
    assert(conn.out_fds[0] == 42);
    print("  PASS: connection_queue_fd\n");
}

test_connection_queue_multiple :: () {
    conn: Connection;
    buf: [8] u8;
    pack_header(buf.data, object_id = 1, opcode = 0, size = 8);
    connection_queue(*conn, buf.data, 8);
    connection_queue(*conn, buf.data, 8);
    assert(conn.out_used == 16);
    print("  PASS: connection_queue_multiple\n");
}

Connection       :: Wayland.Connection;
connection_queue :: Wayland.connection_queue;
connection_queue_fd :: Wayland.connection_queue_fd;
```

**Step 2: Implement buffer queueing and flush**

Add to `modules/wayland/connection.jai`:

```jai
// Queue message bytes into the outgoing buffer.
connection_queue :: (conn: *Connection, data: *u8, size: u32) {
    assert(conn.out_used + size <= conn.out_buf.count, "outgoing buffer overflow");
    memcpy(conn.out_buf.data + conn.out_used, data, size);
    conn.out_used += size;
}

// Queue a file descriptor for SCM_RIGHTS transmission.
connection_queue_fd :: (conn: *Connection, fd: s32) {
    assert(conn.out_fds_count < MAX_FDS_OUT, "fd queue overflow");
    conn.out_fds[conn.out_fds_count] = fd;
    conn.out_fds_count += 1;
}

// Flush the outgoing buffer via sendmsg, passing queued fds via SCM_RIGHTS.
// Returns true on success.
connection_flush :: (conn: *Connection) -> bool {
    if conn.out_used == 0  return true;  // nothing to send

    iov: iovec;
    iov.iov_base = conn.out_buf.data;
    iov.iov_len  = cast(u64) conn.out_used;

    msg: msghdr;
    msg.msg_iov    = *iov;
    msg.msg_iovlen = 1;

    // SCM_RIGHTS ancillary data for fd passing
    cmsg_buf: [CMSG_SPACE_FDS] u8;  // sized for MAX_FDS_OUT fds
    if conn.out_fds_count > 0 {
        cmsg_size := CMSG_SPACE(cast(int)(conn.out_fds_count * size_of(s32)));
        msg.msg_control    = cmsg_buf.data;
        msg.msg_controllen = cast(u64) cmsg_size;

        cmsg := CMSG_FIRSTHDR(*msg);
        cmsg.cmsg_level = SOL_SOCKET;
        cmsg.cmsg_type  = cast(s32) SCM.RIGHTS;
        cmsg.cmsg_len   = cast(u64) CMSG_LEN(cast(int)(conn.out_fds_count * size_of(s32)));

        fd_dst := cast(*s32) CMSG_DATA(cmsg);
        memcpy(cast(*u8) fd_dst, cast(*u8) conn.out_fds.data,
               conn.out_fds_count * size_of(s32));
    }

    sent := sendmsg(conn.socket_fd, *msg, cast(MSG) 0);
    if sent < 0  return false;

    // Reset outgoing buffers
    conn.out_used = 0;
    conn.out_fds_count = 0;
    return true;
}

// CMSG_SPACE for MAX_FDS_OUT file descriptors
CMSG_SPACE_FDS :: #run CMSG_SPACE(MAX_FDS_OUT * size_of(s32));

// Import CMSG helpers from Socket module
CMSG_SPACE :: (len: int) -> int #inline {
    return CMSG_ALIGN(size_of(cmsghdr)) + CMSG_ALIGN(len);
}
```

Note: `CMSG_ALIGN`, `CMSG_FIRSTHDR`, `CMSG_DATA`, `CMSG_LEN` are already provided by Jai's `Socket` module. `CMSG_SPACE` may need to be defined if not present — check `~/jai/jai/modules/Socket/module.jai`.

**Step 3: Run tests**

```bash
./build.sh - wire_test
```

**Step 4: Commit**

```bash
git add modules/wayland/connection.jai tests/wire_test.jai
git commit -m "feat(wire): message queueing, fd queueing, and sendmsg flush with SCM_RIGHTS"
```

---

### Task 6: Message Receive with SCM_RIGHTS

Implement `connection_read` using `recvmsg` and `connection_next_message` to parse incoming messages.

**Files:**
- Modify: `modules/wayland/connection.jai`

**Step 1: Implement receive**

Add to `modules/wayland/connection.jai`:

```jai
// Read data from the socket into the incoming buffer.
// Returns true on success, false on disconnect or error.
connection_read :: (conn: *Connection) -> bool {
    // Compact: move unread data to front
    if conn.in_read > 0 {
        remaining := conn.in_used - conn.in_read;
        if remaining > 0 {
            memmove(conn.in_buf.data, conn.in_buf.data + conn.in_read, remaining);
        }
        conn.in_used = remaining;
        conn.in_read = 0;
    }

    // Also compact fd queue
    if conn.in_fds_read > 0 {
        remaining_fds := conn.in_fds_count - conn.in_fds_read;
        if remaining_fds > 0 {
            memmove(cast(*u8) conn.in_fds.data,
                    cast(*u8) (conn.in_fds.data + conn.in_fds_read),
                    remaining_fds * size_of(s32));
        }
        conn.in_fds_count = remaining_fds;
        conn.in_fds_read = 0;
    }

    iov: iovec;
    iov.iov_base = conn.in_buf.data + conn.in_used;
    iov.iov_len  = cast(u64)(conn.in_buf.count - conn.in_used);

    msg: msghdr;
    msg.msg_iov    = *iov;
    msg.msg_iovlen = 1;

    cmsg_buf: [CMSG_SPACE_FDS] u8;
    msg.msg_control    = cmsg_buf.data;
    msg.msg_controllen = cast(u64) cmsg_buf.count;

    received := recvmsg(conn.socket_fd, *msg, cast(MSG) 0);
    if received <= 0  return false;

    conn.in_used += cast(u32) received;

    // Extract fds from ancillary data
    cmsg := CMSG_FIRSTHDR(*msg);
    while cmsg != null {
        if cmsg.cmsg_level == SOL_SOCKET && cmsg.cmsg_type == cast(s32) SCM.RIGHTS {
            fd_data := CMSG_DATA(cmsg);
            payload_len := cmsg.cmsg_len - cast(u64) CMSG_LEN(0);
            fd_count := cast(u32)(payload_len / size_of(s32));
            for i: 0..fd_count-1 {
                if conn.in_fds_count < MAX_FDS_OUT {
                    conn.in_fds[conn.in_fds_count] = (cast(*s32)(fd_data + i * size_of(s32))).*;
                    conn.in_fds_count += 1;
                }
            }
        }
        cmsg = __cmsg_nxthdr(*msg, cmsg);
    }

    return true;
}

// Peek at the next incoming message without consuming it.
// Returns pointer to message start (header) and message size, or null if incomplete.
connection_peek_message :: (conn: *Connection) -> *u8, u32 {
    available := conn.in_used - conn.in_read;
    if available < HEADER_SIZE  return null, 0;

    src := conn.in_buf.data + conn.in_read;
    _, _, size := unpack_header(src);

    if available < size  return null, 0;  // incomplete message
    return src, size;
}

// Consume the current message (advance read cursor).
connection_consume_message :: (conn: *Connection, size: u32) {
    conn.in_read += size;
}

// Pop an incoming fd from the queue.
connection_pop_fd :: (conn: *Connection) -> s32 {
    assert(conn.in_fds_read < conn.in_fds_count, "no incoming fds");
    fd := conn.in_fds[conn.in_fds_read];
    conn.in_fds_read += 1;
    return fd;
}
```

**Step 2: Verify compilation**

```bash
./build.sh - compile_test
```

**Step 3: Commit**

```bash
git add modules/wayland/connection.jai
git commit -m "feat(wire): recvmsg with SCM_RIGHTS, message peek/consume, fd queue"
```

---

### Task 7: Compile-Time Marshal Macro (TDD)

The core innovation: an `#expand` macro that walks a request arg struct's `type_info` at compile time and emits type-specific serialization code via `#insert #run`.

**Files:**
- Create: `modules/wayland/marshal.jai`
- Create: `tests/marshal_test.jai`
- Modify: `modules/wayland/module.jai` — add `#load "marshal.jai"`
- Modify: `first.jai` — add `marshal_test` build target

**Step 1: Add marshal_test build target**

In `first.jai`:

```jai
case "marshal_test";
    build_and_run_test("marshal_tests", "marshal_tests", "tests/marshal_test.jai", "build_tests");
    set_build_options_dc(.{do_output=false});
```

**Step 2: Write test with a sample arg struct**

Create `tests/marshal_test.jai`:

```jai
#import "Basic";
#import "Compiler";
Wayland :: #import,dir "../modules/wayland";

// Test struct mimicking wl_surface.attach args
Test_Attach_Args :: struct {
    buffer_id: u32;  // object → its id
    x: s32;
    y: s32;
}

// Test struct with an Fd
Test_Fd_Args :: struct {
    mime_type: string;
    fd: Wayland.Fd;
}

main :: () {
    print("=== Marshal Macro Tests ===\n\n");

    test_marshal_fixed_args();
    test_marshal_with_fd();
    test_marshal_with_string();
    test_marshal_empty_args();

    print("\n=== All marshal tests passed ===\n");
}

Test_Empty_Args :: struct {}

test_marshal_fixed_args :: () {
    conn: Wayland.Connection;
    args := Test_Attach_Args.{buffer_id = 7, x = 10, y = -5};

    // Marshal into connection's outgoing buffer
    Wayland.marshal(*conn, object_id = 5, opcode = 1, *args);

    // Verify header: object_id=5, opcode=1, size=20 (8 header + 12 args)
    assert(conn.out_used == 20, "wrong message size");
    obj_id := Wayland.read_u32(conn.out_buf.data);
    assert(obj_id == 5, "wrong object_id in header");
    word2 := Wayland.read_u32(conn.out_buf.data + 4);
    assert(word2 == (20 << 16) | 1, "wrong size|opcode");

    // Verify args
    assert(Wayland.read_u32(conn.out_buf.data + 8) == 7, "wrong buffer_id");
    assert(Wayland.read_s32(conn.out_buf.data + 12) == 10, "wrong x");
    assert(Wayland.read_s32(conn.out_buf.data + 16) == -5, "wrong y");

    print("  PASS: marshal_fixed_args\n");
}

test_marshal_with_fd :: () {
    conn: Wayland.Connection;
    args := Test_Fd_Args.{mime_type = "text/plain", fd = cast(Wayland.Fd) 42};

    Wayland.marshal(*conn, object_id = 3, opcode = 0, *args);

    // Fd should be in the fd queue, NOT in the message body
    assert(conn.out_fds_count == 1, "fd not queued");
    assert(conn.out_fds[0] == 42, "wrong fd value");

    // Message should contain: header (8) + string ("text/plain" = 11 bytes + NUL = 12, padded = 12, wire = 4+12=16)
    // Total: 8 + 16 = 24 bytes (fd is NOT in message body)
    assert(conn.out_used == 24, "wrong message size with fd");

    print("  PASS: marshal_with_fd\n");
}

test_marshal_with_string :: () {
    conn: Wayland.Connection;

    Test_String_Args :: struct {
        name: string;
        version: u32;
    }

    args := Test_String_Args.{name = "wl_compositor", version = 4};
    Wayland.marshal(*conn, object_id = 2, opcode = 0, *args);

    // "wl_compositor" = 13 chars + NUL = 14, padded to 16, wire = 4 + 16 = 20
    // header (8) + string (20) + u32 (4) = 32
    assert(conn.out_used == 32, "wrong message size with string");

    print("  PASS: marshal_with_string\n");
}

test_marshal_empty_args :: () {
    conn: Wayland.Connection;
    args: Test_Empty_Args;
    Wayland.marshal(*conn, object_id = 1, opcode = 6, *args);

    // Header only: 8 bytes
    assert(conn.out_used == 8, "empty args should be header-only");
    print("  PASS: marshal_empty_args\n");
}
```

**Step 3: Run test, verify it fails**

```bash
./build.sh - marshal_test
```

**Step 4: Implement the compile-time marshal macro**

Create `modules/wayland/marshal.jai`:

```jai
#import "Compiler";

// Compile-time marshal macro. Walks the arg struct's type_info and emits
// type-specific serialization code. The generated code references `conn`,
// `object_id`, `opcode`, and `args` from the caller's scope via backtick.
marshal :: (conn: *Connection, object_id: u32, opcode: u16, args: *$T) #expand {
    _marshal_code :: #run generate_marshal_code(type_info(T));
    #insert,scope() _marshal_code;
}

// Compile-time: walk struct members and emit serialization code.
// Returns a string that will be #insert-ed into the marshal macro body.
generate_marshal_code :: (ti: *Type_Info) -> string {
    si := cast(*Type_Info_Struct) ti;

    sb: String_Builder;

    // Phase 1: determine if message is fixed-size or variable-size
    has_variable := false;
    fixed_size: u32 = HEADER_SIZE;

    for member: si.members {
        mt := member.type;
        if mt.type == .STRING {
            has_variable = true;
        } else if mt.type == .STRUCT {
            // Check if it's [] u8 (array slice)
            if is_u8_slice(mt) {
                has_variable = true;
            } else if !is_fd_type(mt) && !is_fixed_type(mt) {
                // Pointer to interface (object) — 4 bytes
                fixed_size += 4;
            } else {
                fixed_size += 4;
            }
        } else if mt.type == .POINTER {
            // Object pointer → write .id (4 bytes)
            fixed_size += 4;
        } else if mt.type == .INTEGER {
            fixed_size += 4;
        } else if mt.type == .VARIANT {
            // #type,distinct — check if it's Fd
            if is_fd_type(mt) {
                // Fd: not on wire, goes to fd queue
            } else {
                fixed_size += 4;
            }
        }
    }

    if !has_variable {
        // Fixed-size fast path: stack buffer, all sizes known at compile time
        print_to_builder(*sb, "{\n");
        print_to_builder(*sb, "    MSG_SIZE :: %;\n", fixed_size);
        print_to_builder(*sb, "    buf: [MSG_SIZE] u8;\n");
        print_to_builder(*sb, "    write_u32(buf.data, `object_id);\n");
        print_to_builder(*sb, "    write_u32(buf.data + 4, cast(u32)(cast(u32) MSG_SIZE << 16) | cast(u32) `opcode);\n");

        offset: u32 = HEADER_SIZE;
        for member: si.members {
            emit_member_write(*sb, member, offset, fixed_size = true);
            if !is_fd_type(member.type) {
                offset += wire_size_of(member.type);
            }
        }

        print_to_builder(*sb, "    connection_queue(`conn, buf.data, MSG_SIZE);\n");
        print_to_builder(*sb, "}\n");
    } else {
        // Variable-size path: compute size at runtime
        print_to_builder(*sb, "{\n");
        print_to_builder(*sb, "    _msg_size: u32 = %;\n", HEADER_SIZE);

        for member: si.members {
            emit_size_calculation(*sb, member);
        }

        print_to_builder(*sb, "    assert(_msg_size <= MAX_MESSAGE_SIZE, \"message too large\");\n");
        print_to_builder(*sb, "    buf: [MAX_MESSAGE_SIZE] u8;\n");
        print_to_builder(*sb, "    write_u32(buf.data, `object_id);\n");
        print_to_builder(*sb, "    _offset: u32 = %;\n", HEADER_SIZE);

        for member: si.members {
            emit_member_write_variable(*sb, member);
        }

        // Write header with final size
        print_to_builder(*sb, "    write_u32(buf.data + 4, cast(u32)(cast(u32) _msg_size << 16) | cast(u32) `opcode);\n");
        print_to_builder(*sb, "    connection_queue(`conn, buf.data, _msg_size);\n");
        print_to_builder(*sb, "}\n");
    }

    return builder_to_string(*sb);
}

// --- Compile-time helpers (run at compile time only) ---

#scope_file

emit_member_write :: (sb: *String_Builder, member: Type_Info_Struct.Member_Info, offset: u32, fixed_size: bool) {
    mt := member.type;
    name := member.name;

    if mt.type == .VARIANT && is_fd_type(mt) {
        // Fd: queue to fd queue, not on wire
        print_to_builder(sb, "    connection_queue_fd(`conn, cast(s32) `args.%);\n", name);
        return;
    }

    if mt.type == .POINTER {
        // Object pointer → write .id
        print_to_builder(sb, "    write_u32(buf.data + %, `args.%.id);\n", offset, name);
    } else if mt.type == .INTEGER {
        ti_int := cast(*Type_Info_Integer) mt;
        if ti_int.signed {
            print_to_builder(sb, "    write_s32(buf.data + %, `args.%);\n", offset, name);
        } else {
            print_to_builder(sb, "    write_u32(buf.data + %, `args.%);\n", offset, name);
        }
    } else if mt.type == .STRUCT && is_fixed_type(mt) {
        // Fixed type (24.8) — write raw s32
        print_to_builder(sb, "    write_s32(buf.data + %, `args.%.raw);\n", offset, name);
    } else if mt.type == .VARIANT && !is_fd_type(mt) {
        // Other distinct types — treat as their base type
        print_to_builder(sb, "    write_u32(buf.data + %, cast(u32) `args.%);\n", offset, name);
    }
}

emit_size_calculation :: (sb: *String_Builder, member: Type_Info_Struct.Member_Info) {
    mt := member.type;
    name := member.name;

    if mt.type == .VARIANT && is_fd_type(mt)  return;  // fd not on wire

    if mt.type == .STRING {
        // string: 4 (length) + align4(count + 1) for non-empty, 4 for empty
        print_to_builder(sb, "    if `args.%.count > 0  _msg_size += 4 + align4(cast(u32)(`args.%.count + 1));\n", name, name);
        print_to_builder(sb, "    else  _msg_size += 4;\n");
    } else if mt.type == .STRUCT && is_u8_slice(mt) {
        // array: 4 (length) + align4(count)
        print_to_builder(sb, "    _msg_size += 4 + align4(cast(u32) `args.%.count);\n", name);
    } else {
        print_to_builder(sb, "    _msg_size += 4;\n");
    }
}

emit_member_write_variable :: (sb: *String_Builder, member: Type_Info_Struct.Member_Info) {
    mt := member.type;
    name := member.name;

    if mt.type == .VARIANT && is_fd_type(mt) {
        print_to_builder(sb, "    connection_queue_fd(`conn, cast(s32) `args.%);\n", name);
        return;
    }

    if mt.type == .STRING {
        print_to_builder(sb, "    _offset += write_string(buf.data + _offset, `args.%);\n", name);
    } else if mt.type == .STRUCT && is_u8_slice(mt) {
        print_to_builder(sb, "    _offset += write_array(buf.data + _offset, `args.%);\n", name);
    } else if mt.type == .POINTER {
        print_to_builder(sb, "    write_u32(buf.data + _offset, `args.%.id); _offset += 4;\n", name);
    } else if mt.type == .INTEGER {
        ti_int := cast(*Type_Info_Integer) mt;
        if ti_int.signed {
            print_to_builder(sb, "    write_s32(buf.data + _offset, `args.%); _offset += 4;\n", name);
        } else {
            print_to_builder(sb, "    write_u32(buf.data + _offset, `args.%); _offset += 4;\n", name);
        }
    } else if mt.type == .STRUCT && is_fixed_type(mt) {
        print_to_builder(sb, "    write_s32(buf.data + _offset, `args.%.raw); _offset += 4;\n", name);
    }
}

is_fd_type :: (ti: *Type_Info) -> bool {
    if ti.type != .VARIANT  return false;
    tiv := cast(*Type_Info_Variant) ti;
    // Check if the variant's base type is s32 and the variant name suggests Fd
    // More robust: check type_info(Fd) identity, but at compile time we can
    // check the variant_of type and the struct name.
    return tiv.variant_of.type == .INTEGER && tiv.variant_of.runtime_size == 4;
    // Note: this is a simplification. In practice, we may need to check the
    // type name or use a more specific marker. Refine during implementation.
}

is_fixed_type :: (ti: *Type_Info) -> bool {
    if ti.type != .STRUCT  return false;
    si := cast(*Type_Info_Struct) ti;
    return si.name == "Fixed";
}

is_u8_slice :: (ti: *Type_Info) -> bool {
    // [] u8 is represented as a struct with data: *u8 and count: s64
    // Actually in Jai, slices are their own type_info type. Check during implementation.
    // This may need to be .ARRAY type check instead.
    return false;  // Placeholder — refine during implementation
}

wire_size_of :: (ti: *Type_Info) -> u32 {
    if ti.type == .POINTER  return 4;
    if ti.type == .INTEGER  return 4;
    if ti.type == .STRUCT && is_fixed_type(ti)  return 4;
    if ti.type == .VARIANT  return 4;
    return 0;  // strings, arrays, fds handled separately
}
```

**Important implementation notes:**
- The `is_fd_type` check needs refinement during implementation. The clean approach is to compare `type_info` identity: `member.type == type_info(Fd)` at compile time. Test this.
- The `is_u8_slice` check depends on how Jai represents `[] u8` in type_info — it may be `.ARRAY` type rather than `.STRUCT`. Verify with `~/jai/jai/how_to/` examples on type_info.
- All backtick-prefixed identifiers (`` `conn ``, `` `args ``, `` `object_id ``, `` `opcode ``) resolve in the caller's scope (the `#expand` macro body).
- After building, inspect `.build/.added_strings_w*.jai` to verify the generated code is correct.

**Step 5: Run tests**

```bash
./build.sh - marshal_test
```

Expected: all 4 marshal tests pass.

**Step 6: Inspect generated code**

```bash
cat .build/.added_strings_w*.jai
```

Verify the emitted code matches expectations (direct stores, correct offsets, fd routing).

**Step 7: Commit**

```bash
git add modules/wayland/marshal.jai tests/marshal_test.jai first.jai modules/wayland/module.jai
git commit -m "feat(wire): compile-time marshal macro with #expand + #insert #run (TDD)"
```

---

### Task 8: marshal_constructor Macro

Variant of `marshal` that allocates a new object ID and returns it.

**Files:**
- Modify: `modules/wayland/marshal.jai`
- Modify: `tests/marshal_test.jai`

**Step 1: Write failing test**

Add to `tests/marshal_test.jai`:

```jai
test_marshal_constructor();

// ...

Test_Constructor_Args :: struct {
    // Typically empty for simple constructors like wl_display.sync
    // The new_id is NOT an arg — it's allocated by marshal_constructor
}

test_marshal_constructor :: () {
    conn: Wayland.Connection;
    args: Test_Constructor_Args;

    new_id := Wayland.marshal_constructor(*conn, object_id = 1, opcode = 0, *args);

    assert(new_id == 1, "first allocated id should be 1");
    assert(conn.next_id == 2, "next_id should advance");

    // Message: header (8) + new_id (4) = 12 bytes
    assert(conn.out_used == 12, "constructor message should include new_id");

    // Verify new_id is in the message body
    written_id := Wayland.read_u32(conn.out_buf.data + 8);
    assert(written_id == 1, "new_id should be written to message");

    print("  PASS: marshal_constructor\n");
}
```

**Step 2: Implement marshal_constructor**

Add to `modules/wayland/marshal.jai`:

```jai
// Marshal a constructor request that allocates a new object.
// Writes the new_id as the FIRST argument before the struct args.
// Returns the allocated object ID.
marshal_constructor :: (conn: *Connection, object_id: u32, opcode: u16, args: *$T) -> u32 #expand {
    new_id := allocate_id(`conn);
    _ctor_code :: #run generate_marshal_constructor_code(type_info(T));
    #insert,scope() _ctor_code;
    return new_id;
}

#scope_file

generate_marshal_constructor_code :: (ti: *Type_Info) -> string {
    // Same as generate_marshal_code but prepends new_id as first arg (4 bytes).
    // The new_id is written right after the header, then the struct args follow.

    si := cast(*Type_Info_Struct) ti;
    sb: String_Builder;

    has_variable := false;
    fixed_size: u32 = HEADER_SIZE + 4;  // +4 for new_id

    for member: si.members {
        // Same size calculation as generate_marshal_code...
        // (reuse or factor out the shared logic)
    }

    // Emit code similar to generate_marshal_code but with new_id written at offset 8
    // and all other args shifted by 4 bytes.
    // ... (follows same pattern as Task 7)

    return builder_to_string(*sb);
}
```

**Note:** The implementation should factor out shared logic with `generate_marshal_code` to stay DRY. A helper like `emit_marshal_body(sb, si, extra_prefix_bytes: u32, prefix_writes: string)` can serve both cases.

**Step 3: Run tests**

```bash
./build.sh - marshal_test
```

**Step 4: Commit**

```bash
git add modules/wayland/marshal.jai tests/marshal_test.jai
git commit -m "feat(wire): marshal_constructor macro for new_id allocation"
```

---

### Task 9: Generator Update — Fd Type, Request Arg Structs, Marshal Calls

Update the code generator to emit:
1. `Fd` instead of `s32` for fd-type args
2. Request arg structs (parallel to existing event arg structs)
3. Real `marshal`/`marshal_constructor` calls instead of TODO stubs
4. `conn: *Connection` field in proxy structs

**Files:**
- Modify: `src/generator.jai`
- Modify: `tests/generator_test.jai` — update tests for new output

**Step 1: Update arg_type_to_jai for FD**

In `src/generator.jai`, change the FD mapping:

```jai
// Before:
case .FD;  return "s32";
// After:
case .FD;  return "Fd";
```

**Step 2: Update generate_interface_struct to include conn field**

```jai
// Before:
print_to_builder(sb, "% :: struct {\n    id: u32;\n    version: u32;\n}\n", type_name);
// After:
print_to_builder(sb, "% :: struct {\n    id: u32;\n    version: u32;\n    conn: *Connection;\n}\n", type_name);
```

**Step 3: Add generate_request_args function**

New function that generates a request arg struct, mirroring the existing event arg struct pattern:

```jai
generate_request_args :: (iface: Interface, req: Message, opcode: int) -> string {
    // Generate struct like: Wl_Surface_Attach_Args :: struct { buffer_id: u32; x: s32; y: s32; }
    // Skip NEW_ID args (typed ones become return values, handled by marshal_constructor)
    // For OBJECT args: store as u32 (the id), not pointer
    // For FD args: use Fd type
    // ...
}
```

**Step 4: Update generate_request to emit marshal calls**

Replace the TODO stub body with actual code:

For non-constructor requests:
```jai
// Generated:
wl_surface_attach :: (self: *Wl_Surface, buffer: *Wl_Buffer, x: s32, y: s32) {
    args := Wl_Surface_Attach_Args.{buffer_id = buffer.id, x = x, y = y};
    marshal(self.conn, self.id, WL_SURFACE_ATTACH, *args);
}
```

For constructor requests (has typed new_id return):
```jai
// Generated:
wl_display_sync :: (self: *Wl_Display) -> *Wl_Callback {
    args: Wl_Display_Sync_Args;
    new_id := marshal_constructor(self.conn, self.id, WL_DISPLAY_SYNC, *args);
    result: Wl_Callback;
    result.id = new_id;
    result.conn = self.conn;
    return *result;  // Note: lifetime management is Phase 4
}
```

**Design decisions for arg structs:**
- Object args (`*Wl_Buffer`) are stored as `u32` in the arg struct (just the id) since the compile-time walker writes `.id`. The calling code extracts `buffer.id` when constructing the struct.
- Alternatively: store the pointer and let the walker emit `.id` access. This is simpler for the generator. **Choose during implementation** — either works since the marshal walker handles both.

**Step 5: Update generator tests**

Update `tests/generator_test.jai` to expect the new output format:
- Request functions now have marshal calls instead of TODO
- Request arg structs are generated
- FD args use `Fd` type
- Struct has `conn: *Connection` field

**Step 6: Run generator tests**

```bash
./build.sh - gen_test
```

**Step 7: Regenerate bindings**

```bash
./build.sh - generate
```

**Step 8: Commit**

```bash
git add src/generator.jai tests/generator_test.jai
git commit -m "feat(gen): emit Fd type, request arg structs, and marshal calls"
```

---

### Task 10: Regenerate Bindings and Compilation Smoke Test

Regenerate all bindings with the updated generator and verify everything compiles.

**Files:**
- Regenerate: `modules/wayland/` (all 233 files)
- Modify: `tests/compile_test.jai` — verify marshal-based code compiles

**Step 1: Regenerate**

```bash
./build.sh - generate
```

Verify output: 56 protocols, 189 interfaces, ~233+ files (may be slightly more due to arg struct additions).

**Step 2: Update compile_test.jai**

Add tests that exercise the new marshal-based request functions:

```jai
test_marshal_compiles :: () {
    // Verify that a generated request function with marshal compiles
    // We can't actually call it (no connection), but we verify the types resolve
    ptr := wl_surface_attach;  // function pointer should resolve
    assert(ptr != null);
    print("  PASS: marshal request functions compile\n");
}

test_request_arg_structs :: () {
    // Verify request arg structs exist
    args: Wl_Surface_Attach_Args;
    print("  PASS: request arg structs compile\n");
}

test_fd_type :: () {
    fd: Fd;
    fd = cast(Fd) 42;
    raw := cast(s32) fd;
    assert(raw == 42);
    print("  PASS: Fd distinct type\n");
}

test_conn_field :: () {
    surface: Wl_Surface;
    assert(surface.conn == null);
    print("  PASS: conn field in proxy struct\n");
}
```

**Step 3: Run all test suites**

```bash
./build.sh - compile_test
./build.sh - wire_test
./build.sh - marshal_test
./build.sh - gen_test
./build.sh - test
```

All should pass.

**Step 4: Inspect marshal expansions**

```bash
cat .build/.added_strings_w*.jai | head -100
```

Verify the compile-time generated code for a few representative requests.

**Step 5: Commit**

```bash
git add modules/wayland/ tests/compile_test.jai
git commit -m "feat(wire): regenerate bindings with marshal calls, update compile tests"
```

---

### Task 11: Documentation and Final Cleanup

Update CLAUDE.md, README.md, and commit.

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

**Step 1: Update CLAUDE.md**

- Add wire protocol section describing `wire.jai`, `connection.jai`, `marshal.jai`
- Document the compile-time marshal pattern
- Update test counts
- Update Phase 3 status to complete, Phase 4 as next

**Step 2: Update README.md**

- Phase 3 status → complete
- Add wire protocol description
- Update build commands (wire_test, marshal_test)
- Update project structure

**Step 3: Run all tests one final time**

```bash
./build.sh - test && ./build.sh - gen_test && ./build.sh - wire_test && ./build.sh - marshal_test && ./build.sh - compile_test
```

**Step 4: Commit and push**

```bash
git add CLAUDE.md README.md
git commit -m "docs: Phase 3 wire protocol complete"
git push
```

---

## Summary

| Task | Description | Tests | Key Files |
|------|-------------|-------|-----------|
| 1 | Shared types (Fd, constants) | — | types.jai |
| 2 | Header + inline writers | 7 | wire.jai, wire_test.jai |
| 3 | String/array encoding | 6 | wire.jai, wire_test.jai |
| 4 | Socket connection | compile | connection.jai |
| 5 | Message send + SCM_RIGHTS | 3 | connection.jai, wire_test.jai |
| 6 | Message receive + SCM_RIGHTS | compile | connection.jai |
| 7 | Compile-time marshal macro | 4 | marshal.jai, marshal_test.jai |
| 8 | marshal_constructor | 1 | marshal.jai, marshal_test.jai |
| 9 | Generator update | ~36 updated | generator.jai |
| 10 | Regenerate + smoke test | ~6+ | modules/wayland/, compile_test.jai |
| 11 | Documentation | — | CLAUDE.md, README.md |

**Total new tests:** ~21+ wire/marshal tests, plus updated generator and compile tests.

**Critical path:** Tasks 1→2→3→7→8 (wire primitives → marshal macro). Tasks 4→5→6 (connection) can be developed in parallel. Task 9→10 depends on both paths.
