// Wayland Unix socket connection and object ID allocator.

#import "Basic";
#import "Socket";
#import "POSIX";

// sockaddr_un is not in Jai's Socket module — define manually.
// Matches struct sockaddr_un from <sys/un.h> on Linux.
sockaddr_un :: struct {
    sun_family: u16;
    sun_path: [108] u8;
}

// Wayland connection: socket fd and object ID allocator.
Connection :: struct {
    socket_fd: s32 = -1;

    // Object ID allocator — client IDs start at 1, server IDs at 0xFF000000.
    next_id: u32 = 1;

    // Legacy fields — kept for backward compatibility with marshal.jai,
    // registry.jai, session.jai, and generated bindings. Will be removed
    // once those are updated to use MessageBuilder/ReceiveBuffer.
    out_buf: [MAX_MESSAGE_SIZE * 2] u8;
    out_used: u32;
    out_fds: [MAX_FDS_OUT] s32;
    out_fds_count: u32;
    in_buf: [MAX_MESSAGE_SIZE * 4] u8;
    in_used: u32;
    in_read: u32;
    in_fds: [MAX_FDS_OUT] s32;
    in_fds_count: u32;
    in_fds_read: u32;
}

// Outgoing message batch buffer.
MessageBuilder :: struct ($MMS: u32 = MAX_MESSAGE_SIZE * 2, $MFDS: u32 = MAX_FDS_OUT) {
    out_buf: [MMS] u8;
    out_used: u32;
    out_fds: [MFDS] s32;
    out_fds_count: u32;
}

// Incoming message receive buffer.
ReceiveBuffer :: struct ($MMS: u32 = MAX_MESSAGE_SIZE * 4, $MFDS: u32 = MAX_FDS_OUT) {
    in_buf: [MMS] u8;
    in_used: u32;
    in_read: u32;
    in_fds: [MFDS] s32;
    in_fds_count: u32;
    in_fds_read: u32;
}

// Connect to the Wayland compositor via Unix socket.
// Path: $XDG_RUNTIME_DIR / $WAYLAND_DISPLAY (defaults to "wayland-0").
// Returns true on success, false on failure (socket_fd remains -1).
wayland_connect :: (conn: *Connection) -> bool {
    runtime_dir_ptr := getenv("XDG_RUNTIME_DIR");
    if runtime_dir_ptr == null  return false;
    runtime_dir := to_string(runtime_dir_ptr);

    display_name: string;
    display_ptr := getenv("WAYLAND_DISPLAY");
    if display_ptr != null {
        display_name = to_string(display_ptr);
    } else {
        display_name = "wayland-0";
    }

    path := tprint("%/%", runtime_dir, display_name);
    if path.count >= 108  return false;  // sun_path limit

    fd := socket(AF_LOCAL, .STREAM, cast(IPPROTO) 0);
    if fd < 0  return false;

    addr: sockaddr_un;
    addr.sun_family = AF_LOCAL;
    memcpy(addr.sun_path.data, path.data, path.count);
    addr.sun_path[path.count] = 0;  // NUL terminate

    result := connect(fd, cast(*sockaddr) *addr, cast(socklen_t)(2 + path.count + 1));
    if result < 0 {
        close(fd);
        return false;
    }

    conn.socket_fd = fd;
    return true;
}

// Close the Wayland connection.
wayland_disconnect :: (conn: *Connection) {
    if conn.socket_fd >= 0 {
        close(conn.socket_fd);
        conn.socket_fd = -1;
    }
}

// Allocate the next client-side object ID.
allocate_id :: (conn: *Connection) -> u32 {
    id := conn.next_id;
    conn.next_id += 1;
    return id;
}

// --- New API: MessageBuilder helpers ---

// Queue message bytes into a MessageBuilder.
message_queue :: (batch: *MessageBuilder, data: *u8, size: u32) {
    assert(batch.out_used + size <= batch.out_buf.count, "outgoing buffer overflow");
    memcpy(batch.out_buf.data + batch.out_used, data, size);
    batch.out_used += size;
}

// Queue a file descriptor for SCM_RIGHTS transmission.
message_queue_fd :: (batch: *MessageBuilder, fd: s32) {
    assert(batch.out_fds_count < batch.out_fds.count, "fd queue overflow");
    batch.out_fds[batch.out_fds_count] = fd;
    batch.out_fds_count += 1;
}

// --- New API: ReceiveBuffer helpers ---

// Peek at the next incoming message header.
// Returns pointer to message data and its size, or null/0 if incomplete.
receive_peek_message :: (buf: *ReceiveBuffer) -> *u8, u32 {
    available := buf.in_used - buf.in_read;
    if available < HEADER_SIZE  return null, 0;
    src := buf.in_buf.data + buf.in_read;
    _, _, size := unpack_header(src);
    if available < size  return null, 0;
    return src, size;
}

// Advance the read cursor past a consumed message.
receive_consume_message :: (buf: *ReceiveBuffer, size: u32) {
    buf.in_read += size;
}

// Pop the next incoming file descriptor from the queue.
receive_pop_fd :: (buf: *ReceiveBuffer) -> s32 {
    assert(buf.in_fds_read < buf.in_fds_count, "no incoming fds");
    fd := buf.in_fds[buf.in_fds_read];
    buf.in_fds_read += 1;
    return fd;
}

// --- New API: Send/Receive ---

// Send queued messages from a MessageBuilder via the connection socket.
// Resets the batch on success.
wayland_send :: (conn: *Connection, batch: *MessageBuilder) -> bool {
    if batch.out_used == 0  return true;

    iov: iovec;
    iov.iov_base = batch.out_buf.data;
    iov.iov_len = cast(u64) batch.out_used;

    msg: msghdr;
    msg.msg_iov = *iov;
    msg.msg_iovlen = 1;

    // Set up ancillary data for fd passing if we have queued fds.
    cmsg_buf: [CMSG_BUF_SIZE] u8;
    if batch.out_fds_count > 0 {
        fd_data_size := cast(int)(batch.out_fds_count * size_of(s32));
        msg.msg_control = cmsg_buf.data;
        msg.msg_controllen = cast(u64) CMSG_SPACE(fd_data_size);

        cmsg := CMSG_FIRSTHDR(*msg);
        cmsg.cmsg_level = SOL_SOCKET;
        cmsg.cmsg_type = cast(s32) SCM.RIGHTS;
        cmsg.cmsg_len = cast(u64) CMSG_LEN(fd_data_size);
        memcpy(CMSG_DATA(cmsg), cast(*u8) batch.out_fds.data, fd_data_size);
    }

    bytes_sent := sendmsg(conn.socket_fd, *msg, cast(MSG) 0);
    if bytes_sent < 0  return false;

    batch.out_used = 0;
    batch.out_fds_count = 0;
    return true;
}

// Read incoming data into a ReceiveBuffer via the connection socket.
// Returns number of bytes read, or -1 on error.
wayland_receive :: (conn: *Connection, buf: *ReceiveBuffer) -> s64 {
    // Compact the incoming message buffer: move unread data to front.
    available := buf.in_used - buf.in_read;
    if buf.in_read > 0 && available > 0 {
        src := buf.in_buf.data + buf.in_read;
        dst := buf.in_buf.data;
        for i: 0..cast(s64)(available - 1) {
            dst[i] = src[i];
        }
    }
    buf.in_used = available;
    buf.in_read = 0;

    // Compact the incoming fd queue.
    fds_available := buf.in_fds_count - buf.in_fds_read;
    if buf.in_fds_read > 0 && fds_available > 0 {
        for i: 0..cast(s64)(fds_available - 1) {
            buf.in_fds[i] = buf.in_fds[buf.in_fds_read + cast(u32) i];
        }
    }
    buf.in_fds_count = fds_available;
    buf.in_fds_read = 0;

    // Set up iovec for remaining buffer space.
    iov: iovec;
    iov.iov_base = buf.in_buf.data + buf.in_used;
    iov.iov_len = cast(u64)(buf.in_buf.count - buf.in_used);

    msg: msghdr;
    msg.msg_iov = *iov;
    msg.msg_iovlen = 1;

    // Set up ancillary data buffer for receiving fds.
    cmsg_buf: [CMSG_BUF_SIZE] u8;
    msg.msg_control = cmsg_buf.data;
    msg.msg_controllen = cast(u64) cmsg_buf.count;

    bytes_read := recvmsg(conn.socket_fd, *msg, cast(MSG) 0);
    if bytes_read <= 0  return bytes_read;

    buf.in_used += cast(u32) bytes_read;

    // Walk the cmsg chain extracting file descriptors.
    cmsg := CMSG_FIRSTHDR(*msg);
    while cmsg != null {
        if cmsg.cmsg_level == SOL_SOCKET && cmsg.cmsg_type == cast(s32) SCM.RIGHTS {
            fd_data := CMSG_DATA(cmsg);
            payload_size := cmsg.cmsg_len - cast(u64) size_of(cmsghdr);
            num_fds := payload_size / cast(u64) size_of(s32);
            for i: 0..cast(s64)(num_fds - 1) {
                if buf.in_fds_count < buf.in_fds.count {
                    buf.in_fds[buf.in_fds_count] = (cast(*s32)(fd_data + i * size_of(s32))).*;
                    buf.in_fds_count += 1;
                }
            }
        }
        cmsg = __cmsg_nxthdr(*msg, cmsg);
    }

    return bytes_read;
}

// Send then receive in one call.
wayland_send_receive :: (conn: *Connection, batch: *MessageBuilder, buf: *ReceiveBuffer) -> bool, s64 {
    if !wayland_send(conn, batch)  return false, 0;
    bts := wayland_receive(conn, buf);
    return true, bts;
}

// --- Legacy API: Connection-based helpers ---
// These operate on Connection's embedded buffers for backward compatibility
// with marshal.jai, registry.jai, session.jai, and generated bindings.
// They will be removed once those are updated to use MessageBuilder/ReceiveBuffer.

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

// Flush the outgoing buffer via sendmsg with SCM_RIGHTS ancillary data.
connection_flush :: (conn: *Connection) -> bool {
    if conn.out_used == 0  return true;

    iov: iovec;
    iov.iov_base = conn.out_buf.data;
    iov.iov_len = cast(u64) conn.out_used;

    msg: msghdr;
    msg.msg_iov = *iov;
    msg.msg_iovlen = 1;

    cmsg_buf: [CMSG_BUF_SIZE] u8;
    if conn.out_fds_count > 0 {
        fd_data_size := cast(int)(conn.out_fds_count * size_of(s32));
        msg.msg_control = cmsg_buf.data;
        msg.msg_controllen = cast(u64) CMSG_SPACE(fd_data_size);

        cmsg := CMSG_FIRSTHDR(*msg);
        cmsg.cmsg_level = SOL_SOCKET;
        cmsg.cmsg_type = cast(s32) SCM.RIGHTS;
        cmsg.cmsg_len = cast(u64) CMSG_LEN(fd_data_size);
        memcpy(CMSG_DATA(cmsg), cast(*u8) conn.out_fds.data, fd_data_size);
    }

    bytes_sent := sendmsg(conn.socket_fd, *msg, cast(MSG) 0);
    if bytes_sent < 0  return false;

    conn.out_used = 0;
    conn.out_fds_count = 0;
    return true;
}

// Read incoming data via recvmsg with SCM_RIGHTS ancillary data.
connection_read :: (conn: *Connection) -> s64 {
    available := conn.in_used - conn.in_read;
    if conn.in_read > 0 && available > 0 {
        src := conn.in_buf.data + conn.in_read;
        dst := conn.in_buf.data;
        for i: 0..cast(s64)(available - 1) {
            dst[i] = src[i];
        }
    }
    conn.in_used = available;
    conn.in_read = 0;

    fds_available := conn.in_fds_count - conn.in_fds_read;
    if conn.in_fds_read > 0 && fds_available > 0 {
        for i: 0..cast(s64)(fds_available - 1) {
            conn.in_fds[i] = conn.in_fds[conn.in_fds_read + cast(u32) i];
        }
    }
    conn.in_fds_count = fds_available;
    conn.in_fds_read = 0;

    iov: iovec;
    iov.iov_base = conn.in_buf.data + conn.in_used;
    iov.iov_len = cast(u64)(conn.in_buf.count - conn.in_used);

    msg: msghdr;
    msg.msg_iov = *iov;
    msg.msg_iovlen = 1;

    cmsg_buf: [CMSG_BUF_SIZE] u8;
    msg.msg_control = cmsg_buf.data;
    msg.msg_controllen = cast(u64) cmsg_buf.count;

    bytes_read := recvmsg(conn.socket_fd, *msg, cast(MSG) 0);
    if bytes_read <= 0  return bytes_read;

    conn.in_used += cast(u32) bytes_read;

    cmsg := CMSG_FIRSTHDR(*msg);
    while cmsg != null {
        if cmsg.cmsg_level == SOL_SOCKET && cmsg.cmsg_type == cast(s32) SCM.RIGHTS {
            fd_data := CMSG_DATA(cmsg);
            payload_size := cmsg.cmsg_len - cast(u64) size_of(cmsghdr);
            num_fds := payload_size / cast(u64) size_of(s32);
            for i: 0..cast(s64)(num_fds - 1) {
                if conn.in_fds_count < MAX_FDS_OUT {
                    conn.in_fds[conn.in_fds_count] = (cast(*s32)(fd_data + i * size_of(s32))).*;
                    conn.in_fds_count += 1;
                }
            }
        }
        cmsg = __cmsg_nxthdr(*msg, cmsg);
    }

    return bytes_read;
}

// Peek at the next incoming message header.
connection_peek_message :: (conn: *Connection) -> *u8, u32 {
    available := conn.in_used - conn.in_read;
    if available < HEADER_SIZE  return null, 0;
    src := conn.in_buf.data + conn.in_read;
    _, _, size := unpack_header(src);
    if available < size  return null, 0;
    return src, size;
}

// Advance the read cursor past a consumed message.
connection_consume_message :: (conn: *Connection, size: u32) {
    conn.in_read += size;
}

// Pop the next incoming file descriptor from the queue.
connection_pop_fd :: (conn: *Connection) -> s32 {
    assert(conn.in_fds_read < conn.in_fds_count, "no incoming fds");
    fd := conn.in_fds[conn.in_fds_read];
    conn.in_fds_read += 1;
    return fd;
}

#scope_file

// Compute the space needed for a cmsg with the given data length.
// Equivalent to CMSG_SPACE from Linux headers.
CMSG_SPACE :: (len: int) -> int {
    return CMSG_ALIGN(size_of(cmsghdr)) + CMSG_ALIGN(len);
}

// Pre-computed at compile time for use as array sizes.
CMSG_BUF_SIZE :: #run CMSG_SPACE(MAX_FDS_OUT * size_of(s32));
