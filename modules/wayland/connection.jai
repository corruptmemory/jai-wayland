// Wayland Unix socket connection and object ID allocator.

#import "Socket";
#import "POSIX";

// sockaddr_un is not in Jai's Socket module — define manually.
// Matches struct sockaddr_un from <sys/un.h> on Linux.
sockaddr_un :: struct {
    sun_family: u16;
    sun_path: [108] u8;
}

// Wayland connection state: socket, I/O buffers, fd queues, ID allocator.
Connection :: struct {
    socket_fd: s32 = -1;

    // Outgoing message buffer
    out_buf: [MAX_MESSAGE_SIZE * 2] u8;
    out_used: u32;
    out_fds: [MAX_FDS_OUT] s32;
    out_fds_count: u32;

    // Incoming message buffer
    in_buf: [MAX_MESSAGE_SIZE * 4] u8;
    in_used: u32;
    in_read: u32;
    in_fds: [MAX_FDS_OUT] s32;
    in_fds_count: u32;
    in_fds_read: u32;

    // Object ID allocator — client IDs start at 1, server IDs at 0xFF000000.
    next_id: u32 = 1;
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
