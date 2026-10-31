// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers

// DRM sync objects for explicit sync (linux-drm-syncobj-v1): raw ioctls on a DRM fd,
// no libdrm, so nothing new is linked (ioctl is libc).
//
// A timeline sync object holds a fence per point. The client attaches its GPU fence
// to an acquire point and the compositor attaches one to a release point; points on
// one timeline must be added in increasing order. The kernel structs below are the
// long-standing layouts. Newer kernels extend drm_syncobj_handle (+ point) and
// drm_syncobj_timeline_wait (+ deadline_nsec); the kernel zero-fills the tail of an
// older-sized request, and the ioctl table is indexed by number, not size.
//
// A wait that times out is an answer, not a failure. Every other failure is logged
// with its errno.

#import "Basic";
#import "POSIX";

Syncobj_Wait_Result :: enum { SIGNALED; TIMED_OUT; ERROR; }

// True when the driver behind `drm_fd` supports timeline sync objects.
syncobj_timeline_supported :: (drm_fd: s32) -> bool {
    cap := Drm_Get_Cap.{ capability = DRM_CAP_SYNCOBJ_TIMELINE };
    if drm_ioctl(drm_fd, DRM_IOCTL_GET_CAP, *cap) != 0  return false;
    return cap.value != 0;
}

syncobj_create :: (drm_fd: s32) -> u32, bool {
    args: Drm_Syncobj_Create;
    if drm_ioctl(drm_fd, DRM_IOCTL_SYNCOBJ_CREATE, *args) != 0 {
        log_error("DRM_IOCTL_SYNCOBJ_CREATE failed (errno %)", errno());
        return 0, false;
    }
    return args.handle, true;
}

syncobj_destroy :: (drm_fd: s32, handle: u32) {
    if handle == 0  return;
    args := Drm_Syncobj_Destroy.{ handle = handle };
    if drm_ioctl(drm_fd, DRM_IOCTL_SYNCOBJ_DESTROY, *args) != 0 {
        log_error("DRM_IOCTL_SYNCOBJ_DESTROY(%) failed (errno %)", handle, errno());
    }
}

// The fd another process (the compositor) imports to share this sync object. The
// caller owns it; -1 on failure.
syncobj_export :: (drm_fd: s32, handle: u32) -> s32 {
    args := Drm_Syncobj_Handle.{ handle = handle, fd = -1 };
    if drm_ioctl(drm_fd, DRM_IOCTL_SYNCOBJ_HANDLE_TO_FD, *args) != 0 {
        log_error("DRM_IOCTL_SYNCOBJ_HANDLE_TO_FD(%) failed (errno %)", handle, errno());
        return -1;
    }
    return args.fd;
}

// A handle on this fd for a sync object exported elsewhere. Does not close `fd`.
syncobj_import :: (drm_fd: s32, fd: s32) -> u32, bool {
    args := Drm_Syncobj_Handle.{ fd = fd };
    if drm_ioctl(drm_fd, DRM_IOCTL_SYNCOBJ_FD_TO_HANDLE, *args) != 0 {
        log_error("DRM_IOCTL_SYNCOBJ_FD_TO_HANDLE(fd %) failed (errno %)", fd, errno());
        return 0, false;
    }
    return args.handle, true;
}

// Attach the fence in `sync_file` to `point` of `timeline`: import it into a
// throwaway binary sync object, then transfer that to the point. Does not close
// `sync_file`.
syncobj_import_sync_file :: (drm_fd: s32, timeline: u32, point: u64, sync_file: s32) -> bool {
    binary, ok := syncobj_create(drm_fd);
    if !ok  return false;
    defer syncobj_destroy(drm_fd, binary);

    import := Drm_Syncobj_Handle.{ handle = binary, flags = DRM_SYNCOBJ_FD_TO_HANDLE_FLAGS_IMPORT_SYNC_FILE, fd = sync_file };
    if drm_ioctl(drm_fd, DRM_IOCTL_SYNCOBJ_FD_TO_HANDLE, *import) != 0 {
        log_error("importing sync_file fd % into a sync object failed (errno %)", sync_file, errno());
        return false;
    }
    transfer := Drm_Syncobj_Transfer.{ src_handle = binary, dst_handle = timeline, src_point = 0, dst_point = point };
    if drm_ioctl(drm_fd, DRM_IOCTL_SYNCOBJ_TRANSFER, *transfer) != 0 {
        log_error("transferring a sync_file fence to timeline % point % failed (errno %)", timeline, point, errno());
        return false;
    }
    return true;
}

// Attach the work a commit waits on to `point`: the fence in `sync_file`, or, when
// there is none (-1), signal the point from the CPU because the caller knows the work
// is already complete. Two callers pass -1: the GL path after its glFinish fallback,
// and Vulkan, whose SYNC_FD export may legally return -1 for a semaphore that has
// already signalled. Does not close `sync_file`.
syncobj_attach_fence :: (drm_fd: s32, timeline: u32, point: u64, sync_file: s32) -> bool {
    if sync_file < 0  return syncobj_signal(drm_fd, timeline, point);
    return syncobj_import_sync_file(drm_fd, timeline, point, sync_file);
}

// The fence at `point` of `timeline` as a sync_file the caller owns; -1 on failure
// (including a point nobody has attached a fence to yet).
syncobj_export_sync_file :: (drm_fd: s32, timeline: u32, point: u64) -> s32 {
    binary, ok := syncobj_create(drm_fd);
    if !ok  return -1;
    defer syncobj_destroy(drm_fd, binary);

    transfer := Drm_Syncobj_Transfer.{ src_handle = timeline, dst_handle = binary, src_point = point, dst_point = 0 };
    if drm_ioctl(drm_fd, DRM_IOCTL_SYNCOBJ_TRANSFER, *transfer) != 0 {
        log_error("transferring timeline % point % to a binary sync object failed (errno %)", timeline, point, errno());
        return -1;
    }
    export := Drm_Syncobj_Handle.{ handle = binary, flags = DRM_SYNCOBJ_HANDLE_TO_FD_FLAGS_EXPORT_SYNC_FILE, fd = -1 };
    if drm_ioctl(drm_fd, DRM_IOCTL_SYNCOBJ_HANDLE_TO_FD, *export) != 0 {
        log_error("exporting timeline % point % as a sync_file failed (errno %)", timeline, point, errno());
        return -1;
    }
    return export.fd;
}

// Signal `point` from the CPU: for work the CPU already knows is complete.
syncobj_signal :: (drm_fd: s32, timeline: u32, point: u64) -> bool {
    handle := timeline;
    value  := point;
    args := Drm_Syncobj_Timeline_Array.{ handles = cast(u64) *handle, points = cast(u64) *value, count_handles = 1 };
    if drm_ioctl(drm_fd, DRM_IOCTL_SYNCOBJ_TIMELINE_SIGNAL, *args) != 0 {
        log_error("DRM_IOCTL_SYNCOBJ_TIMELINE_SIGNAL(timeline %, point %) failed (errno %)", timeline, point, errno());
        return false;
    }
    return true;
}

// Wait until ANY of the points is signalled, for at most `timeout_ns` from now (0
// polls). A point nobody has attached a fence to yet counts as not signalled
// (WAIT_FOR_SUBMIT), which is the normal state of a release point before the
// compositor has used its buffer. `first_signaled` indexes `handles`.
syncobj_wait :: (drm_fd: s32, handles: [] u32, points: [] u64, timeout_ns: s64) -> Syncobj_Wait_Result, first_signaled: u32 {
    assert(handles.count == points.count && handles.count > 0);

    // The kernel takes an ABSOLUTE CLOCK_MONOTONIC deadline. A deadline of 0 is in
    // the past, so a zero timeout stays 0 and the call polls.
    deadline: s64 = 0;
    if timeout_ns > 0 {
        now: timespec;
        clock_gettime(.MONOTONIC, *now);
        deadline = now.tv_sec * 1_000_000_000 + now.tv_nsec + timeout_ns;
    }

    args := Drm_Syncobj_Timeline_Wait.{
        handles       = cast(u64) handles.data,
        points        = cast(u64) points.data,
        timeout_nsec  = deadline,
        count_handles = cast(u32) handles.count,
        flags         = DRM_SYNCOBJ_WAIT_FLAGS_WAIT_FOR_SUBMIT,
    };
    if drm_ioctl(drm_fd, DRM_IOCTL_SYNCOBJ_TIMELINE_WAIT, *args) != 0 {
        err := errno();
        if err == ETIME  return .TIMED_OUT, 0;
        log_error("DRM_IOCTL_SYNCOBJ_TIMELINE_WAIT on % handle(s) failed (errno %)", handles.count, err);
        return .ERROR, 0;
    }
    return .SIGNALED, args.first_signaled;
}

syncobj_point_signaled :: (drm_fd: s32, handle: u32, point: u64) -> bool {
    result := syncobj_wait(drm_fd, .[handle], .[point], 0);
    return result == .SIGNALED;
}

#scope_file

// _IOWR('d', nr, size): read/write direction bits, the struct size, the DRM type 'd'.
drm_iowr :: (nr: u64, size: s64) -> u64 {
    return 0xC000_0000 | ((cast(u64) size) << 16) | (0x64 << 8) | nr;
}

DRM_IOCTL_GET_CAP                 :: #run drm_iowr(0x0C, size_of(Drm_Get_Cap));
DRM_IOCTL_SYNCOBJ_CREATE          :: #run drm_iowr(0xBF, size_of(Drm_Syncobj_Create));
DRM_IOCTL_SYNCOBJ_DESTROY         :: #run drm_iowr(0xC0, size_of(Drm_Syncobj_Destroy));
DRM_IOCTL_SYNCOBJ_HANDLE_TO_FD    :: #run drm_iowr(0xC1, size_of(Drm_Syncobj_Handle));
DRM_IOCTL_SYNCOBJ_FD_TO_HANDLE    :: #run drm_iowr(0xC2, size_of(Drm_Syncobj_Handle));
DRM_IOCTL_SYNCOBJ_TIMELINE_WAIT   :: #run drm_iowr(0xCA, size_of(Drm_Syncobj_Timeline_Wait));
DRM_IOCTL_SYNCOBJ_TRANSFER        :: #run drm_iowr(0xCC, size_of(Drm_Syncobj_Transfer));
DRM_IOCTL_SYNCOBJ_TIMELINE_SIGNAL :: #run drm_iowr(0xCD, size_of(Drm_Syncobj_Timeline_Array));

DRM_CAP_SYNCOBJ_TIMELINE :: 0x14;

DRM_SYNCOBJ_FD_TO_HANDLE_FLAGS_IMPORT_SYNC_FILE : u32 : 1 << 0;
DRM_SYNCOBJ_HANDLE_TO_FD_FLAGS_EXPORT_SYNC_FILE : u32 : 1 << 0;
DRM_SYNCOBJ_WAIT_FLAGS_WAIT_FOR_SUBMIT          : u32 : 1 << 1;

Drm_Get_Cap :: struct {
    capability: u64;
    value:      u64;
}

Drm_Syncobj_Create :: struct {
    handle: u32;
    flags:  u32;
}

Drm_Syncobj_Destroy :: struct {
    handle: u32;
    pad:    u32;
}

Drm_Syncobj_Handle :: struct {
    handle: u32;
    flags:  u32;
    fd:     s32;
    pad:    u32;
}

Drm_Syncobj_Timeline_Wait :: struct {
    handles:        u64;   // user pointer to u32 handles
    points:         u64;   // user pointer to u64 points
    timeout_nsec:   s64;   // absolute CLOCK_MONOTONIC
    count_handles:  u32;
    flags:          u32;
    first_signaled: u32;
    pad:            u32;
}

Drm_Syncobj_Transfer :: struct {
    src_handle: u32;
    dst_handle: u32;
    src_point:  u64;
    dst_point:  u64;
    flags:      u32;
    pad:        u32;
}

Drm_Syncobj_Timeline_Array :: struct {
    handles:       u64;
    points:        u64;
    count_handles: u32;
    flags:         u32;
}

#assert size_of(Drm_Get_Cap) == 16;
#assert size_of(Drm_Syncobj_Handle) == 16;
#assert size_of(Drm_Syncobj_Timeline_Wait) == 40;
#assert size_of(Drm_Syncobj_Transfer) == 32;
#assert size_of(Drm_Syncobj_Timeline_Array) == 24;

// ioctl, retried on EINTR / EAGAIN as libdrm's drmIoctl does.
drm_ioctl :: (fd: s32, request: u64, arg: *void) -> s32 {
    while true {
        result := ioctl(fd, request, arg);
        if result == -1 {
            err := errno();
            if err == EINTR || err == EAGAIN  continue;
        }
        return result;
    }
    return -1;
}
