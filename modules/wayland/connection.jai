// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers

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
    next_id: u32 = 1;
}

// Outgoing message batch buffer.
MessageBuilder :: struct ($MMS: u32 = MAX_MESSAGE_SIZE * 2, $MFDS: u32 = MAX_FDS_OUT) {
    out_buf: [MMS] u8;
    out_used: u32;
    out_fds: [MFDS] s32;
    out_fds_count: u32;
    // Set when a message_queue or message_queue_fd did not fit. The batch then
    // holds an incomplete request stream, so wayland_send refuses to send it.
    overflowed: bool;
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

    addr := sockaddr_un.{ sun_family = AF_LOCAL };
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

WAYLAND_SERVER_ID_START :: 0xff000000;

// A stateful ID recycler for short-lived Wayland objects (e.g. wl_callback).
//
// Mutter (and libwayland in general) requires client-allocated IDs to be
// strictly sequential — no gaps. Pre-reserving a block by advancing next_id
// violates this: the compositor rejects the first message whose new_id skips
// any value. Id_Cache avoids this by falling back to allocate_id() when all
// cached entries are live. Destroyed IDs are marked reusable via cache_free and
// returned on the next allocation without touching next_id.
Cached_Id :: struct {
    id:   u32;
    live: bool;
}

Id_Cache :: struct {
    entries: [..] Cached_Id;
}

// Allocate an ID: reuse a dead cached entry, or fall back to sequential allocation.
cache_alloc :: (cache: *Id_Cache, conn: *Connection) -> u32 {
    for * entry: cache.entries {
        if !entry.live {
            entry.live = true;
            return entry.id;
        }
    }

    id := allocate_id(conn);
    if id == 0  return 0;  // allocate_id logged why; a failed id never enters the cache
    array_add(*cache.entries, .{ id = id, live = true });
    return id;
}

// Mark a destroyed ID reusable. The ID must belong to this cache and be live;
// a double free or an unknown id is logged and changes nothing.
cache_free :: (cache: *Id_Cache, id: u32) {
    for * entry: cache.entries {
        if entry.id == id {
            if !entry.live {
                log_error("Wayland ID cache double free: id=%", id);
                return;
            }
            entry.live = false;
            return;
        }
    }

    log_error("Wayland ID cache free of unknown id=%", id);
}

// Close the Wayland connection.
wayland_disconnect :: (conn: *Connection) {
    if conn.socket_fd >= 0 {
        close(conn.socket_fd);
        conn.socket_fd = -1;
    }
}

// Allocate the next client-side object ID.
// Returns 0 after a log_error when the allocator is uninitialised or the client
// id space is exhausted. 0 is never a valid client id, so a request that uses it
// fails loudly at the compositor rather than aliasing wl_display (id 1) or a
// server-allocated id.
allocate_id :: (conn: *Connection) -> u32 {
    if conn.next_id <= 1 {
        log_error("Wayland client object ID allocator was not initialized past wl_display id=1 (next_id=%)", conn.next_id);
        return 0;
    }
    if conn.next_id >= WAYLAND_SERVER_ID_START {
        log_error("Wayland client object ID space exhausted (next_id=%)", conn.next_id);
        return 0;
    }

    id := conn.next_id;
    conn.next_id += 1;
    return id;
}

// --- New API: MessageBuilder helpers ---

// Queue message bytes into a MessageBuilder.
// A message that does not fit is logged and not written, and the batch is marked
// overflowed so wayland_send refuses it.
message_queue :: (batch: *MessageBuilder, data: *u8, size: u32) {
    if cast(s64) batch.out_used + cast(s64) size > batch.out_buf.count {
        log_error("Wayland outgoing batch overflow: % bytes do not fit (% of % used); batch marked overflowed", size, batch.out_used, batch.out_buf.count);
        batch.overflowed = true;
        return;
    }
    memcpy(batch.out_buf.data + batch.out_used, data, size);
    batch.out_used += size;
}

// Queue a file descriptor for SCM_RIGHTS transmission.
// An fd that does not fit is logged and not queued, and the batch is marked
// overflowed so wayland_send refuses it. The caller still owns the fd.
message_queue_fd :: (batch: *MessageBuilder, fd: s32) {
    if batch.out_fds_count >= batch.out_fds.count {
        log_error("Wayland outgoing fd queue overflow: fd % does not fit (% of % queued); batch marked overflowed", fd, batch.out_fds_count, batch.out_fds.count);
        batch.overflowed = true;
        return;
    }
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
// Returns -1 after a log_error when the queue is empty.
receive_pop_fd :: (buf: *ReceiveBuffer) -> s32 {
    if buf.in_fds_read >= buf.in_fds_count {
        log_error("Wayland incoming fd queue is empty: a message expected an fd that was not received");
        return -1;
    }
    fd := buf.in_fds[buf.in_fds_read];
    buf.in_fds_read += 1;
    return fd;
}

// --- New API: Send/Receive ---

// Send queued messages from a MessageBuilder via the connection socket.
// A stream socket can take part of a batch in one sendmsg (a signal, a full
// socket buffer), so this loops until every byte has gone. The queued fds ride
// only the first sendmsg that moves bytes. Resets the batch on success.
// A sendmsg failure is logged and returns false without resetting the batch: it
// keeps only the bytes (and fds) that never left, so a later send carries on with
// the stream instead of repeating part of it.
// An overflowed batch is refused: it is logged, nothing is sent, the batch is
// left as it is, and the result is false.
// MSG_NOSIGNAL: a peer that has closed is an EPIPE failure the path above logs,
// not a SIGPIPE whose default action kills the process.
wayland_send :: (conn: *Connection, batch: *MessageBuilder) -> bool {
    if batch.overflowed {
        log_error("Wayland batch overflowed while queueing (% bytes, % fds held); refusing to send an incomplete request stream", batch.out_used, batch.out_fds_count);
        return false;
    }
    if batch.out_used == 0  return true;

    cmsg_buf: [CMSG_BUF_SIZE] u8;
    sent: u32 = 0;
    while sent < batch.out_used {
        iov := iovec.{ iov_base = batch.out_buf.data + sent, iov_len = cast(u64)(batch.out_used - sent) };
        msg := msghdr.{ msg_iov = *iov, msg_iovlen = 1 };

        // Ancillary data for fd passing, on the first sendmsg only.
        if sent == 0 && batch.out_fds_count > 0 {
            fd_data_size := cast(int)(batch.out_fds_count * size_of(s32));
            msg.msg_control = cmsg_buf.data;
            msg.msg_controllen = cast(u64) CMSG_SPACE(fd_data_size);

            cmsg := CMSG_FIRSTHDR(*msg);
            cmsg.cmsg_level = SOL_SOCKET;
            cmsg.cmsg_type = cast(s32) SCM.RIGHTS;
            cmsg.cmsg_len = cast(u64) CMSG_LEN(fd_data_size);
            memcpy(CMSG_DATA(cmsg), cast(*u8) batch.out_fds.data, fd_data_size);
        }

        bytes_sent := sendmsg(conn.socket_fd, *msg, MSG.NOSIGNAL);
        if bytes_sent <= 0 {
            err := errno();
            if bytes_sent < 0 && err == EINTR  continue;  // interrupted before any byte moved: retry

            log_error("Wayland sendmsg returned % (errno %) after % of % bytes; the % unsent bytes stay in the batch", bytes_sent, err, sent, batch.out_used, batch.out_used - sent);
            if sent > 0 {
                // Drop the prefix that did go out, fds included: they left with it.
                remaining := batch.out_used - sent;
                for i: 0..(cast(s64) remaining) - 1  batch.out_buf[i] = batch.out_buf[(cast(s64) sent) + i];
                batch.out_used = remaining;
                batch.out_fds_count = 0;
            }
            return false;
        }
        sent += cast(u32) bytes_sent;
    }

    batch.out_used = 0;
    batch.out_fds_count = 0;
    return true;
}

// Read incoming data into a ReceiveBuffer via the connection socket.
// Returns the number of bytes read, or <= 0 when the connection is lost, and
// every <= 0 result is logged with its cause (callers treat <= 0 as a lost
// connection, but are not the only signal):
//   0  the peer closed the socket, or the buffer is full of one unread partial
//      message (a message larger than the buffer), which nothing can complete;
//  -1  recvmsg failed (errno logged; EINTR is retried, not reported), the
//      control data was truncated (MSG_CTRUNC), or more fds arrived than the
//      incoming fd queue holds. In the last two the fd queue no longer lines up
//      with the messages that reference it, so the connection is unusable.
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

    // A buffer still full after compaction holds one unread partial message that
    // fills all of it. There is no room to read the rest, and a zero-length
    // recvmsg on a live, quiet socket would block rather than return.
    if buf.in_used >= buf.in_buf.count {
        log_error("Wayland receive buffer is full: % unread bytes and no complete message (an incoming message larger than the buffer?); the connection cannot make progress", buf.in_used);
        return 0;
    }

    // Set up iovec for remaining buffer space.
    iov := iovec.{ iov_base = buf.in_buf.data + buf.in_used, iov_len = cast(u64)(buf.in_buf.count - buf.in_used) };
    msg := msghdr.{ msg_iov = *iov, msg_iovlen = 1 };

    // Set up ancillary data buffer for receiving fds.
    cmsg_buf: [CMSG_BUF_SIZE] u8;

    bytes_read: s64;
    while true {
        msg.msg_control = cmsg_buf.data;
        msg.msg_controllen = cast(u64) cmsg_buf.count;
        msg.msg_flags = 0;
        bytes_read = recvmsg(conn.socket_fd, *msg, cast(MSG) 0);
        if bytes_read >= 0  break;
        err := errno();
        if err == EINTR  continue;  // interrupted before any byte arrived: retry
        log_error("Wayland recvmsg failed (errno %); the connection is lost", err);
        return -1;
    }
    if bytes_read == 0 {
        log_error("Wayland compositor closed the connection (recvmsg returned 0)");
        return 0;
    }

    // MSG_CTRUNC: the control data did not fit, so the kernel discarded fds the
    // compositor sent. The fd queue no longer lines up with the messages that
    // reference it, so the connection is unusable; libwayland treats this case
    // the same way. The fds that did arrive are closed below, and the result is -1,
    // which callers treat as a lost connection.
    truncated := (msg.msg_flags & cast(s32) MSG.CTRUNC) != 0;

    buf.in_used += cast(u32) bytes_read;

    // More fds than the incoming queue holds breaks the FIFO the same way: the
    // fds that do not fit (and every later one in this read) are closed, and the
    // result is -1.
    fd_overflow := false;

    // Walk the cmsg chain extracting file descriptors.
    cmsg := CMSG_FIRSTHDR(*msg);
    while cmsg != null {
        if cmsg.cmsg_level == SOL_SOCKET && cmsg.cmsg_type == cast(s32) SCM.RIGHTS {
            fd_data := CMSG_DATA(cmsg);
            payload_size := cmsg.cmsg_len - cast(u64) size_of(cmsghdr);
            num_fds := payload_size / cast(u64) size_of(s32);
            for i: 0..cast(s64)(num_fds - 1) {
                fd := (cast(*s32)(fd_data + i * size_of(s32))).*;
                if truncated || fd_overflow {
                    close(fd);
                } else if buf.in_fds_count < buf.in_fds.count {
                    buf.in_fds[buf.in_fds_count] = fd;
                    buf.in_fds_count += 1;
                } else {
                    // Nothing can ever pop this fd, so close it rather than leak it.
                    fd_overflow = true;
                    close(fd);
                }
            }
        }
        cmsg = __cmsg_nxthdr(*msg, cmsg);
    }

    if truncated {
        log_error("Wayland recvmsg truncated the control data (MSG_CTRUNC): the kernel discarded received fds, so the connection is unusable");
        return -1;
    }
    if fd_overflow {
        log_error("Wayland incoming fd queue overflow: more fds arrived than its % slots hold; the extra fds were closed and the fd queue no longer lines up with its messages, so the connection is unusable", buf.in_fds.count);
        return -1;
    }
    return bytes_read;
}

// Send then receive in one call.
wayland_send_receive :: (conn: *Connection, batch: *MessageBuilder, buf: *ReceiveBuffer) -> bool, s64 {
    if !wayland_send(conn, batch)  return false, 0;
    bts := wayland_receive(conn, buf);
    return true, bts;
}

#scope_file

// Compute the space needed for a cmsg with the given data length.
// Equivalent to CMSG_SPACE from Linux headers.
CMSG_SPACE :: (len: int) -> int {
    return CMSG_ALIGN(size_of(cmsghdr)) + CMSG_ALIGN(len);
}

// Pre-computed at compile time for use as array sizes.
CMSG_BUF_SIZE :: #run CMSG_SPACE(MAX_FDS_OUT * size_of(s32));
