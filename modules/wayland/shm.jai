// Shared memory helpers for wl_shm buffer allocation.

#import "POSIX";

// Create an anonymous shared memory file descriptor.
memfd_create :: (name: *u8, flags: u32) -> s32 {
    return cast(s32) syscall(SYS_memfd_create, cast(u64) name, cast(u64) flags);
}
