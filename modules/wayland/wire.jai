// Wire protocol primitives for Wayland message framing.
// All writes are native-endian (both sides on same machine).

write_u32 :: inline (dst: *u8, value: u32) {
    (cast(*u32) dst).* = value;
}

write_s32 :: inline (dst: *u8, value: s32) {
    (cast(*s32) dst).* = value;
}

read_u32 :: inline (src: *u8) -> u32 {
    return (cast(*u32) src).*;
}

read_s32 :: inline (src: *u8) -> s32 {
    return (cast(*s32) src).*;
}

// Pack a Wayland message header into 8 bytes.
// Format: [object_id: u32][size << 16 | opcode: u32]
pack_header :: inline (dst: *u8, object_id: u32, opcode: u16, size: u32) {
    write_u32(dst, object_id);
    write_u32(dst + 4, (size << 16) | cast(u32) opcode);
}

// Unpack a Wayland message header from 8 bytes.
// Returns: object_id, opcode, size
unpack_header :: (src: *u8) -> u32, u16, u32 {
    object_id := read_u32(src);
    word2 := read_u32(src + 4);
    opcode := cast(u16)(word2 & 0xFFFF);
    size := word2 >> 16;
    return object_id, opcode, size;
}

// Round up to next 4-byte boundary.
align4 :: inline (n: u32) -> u32 {
    return (n + 3) & ~cast(u32)3;
}

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
    // Zero padding bytes
    padded := align4(length);
    if padded > length {
        memset(dst + 4 + length, 0, padded - length);
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
        if padded > length {
            memset(dst + 4 + length, 0, padded - length);
        }
        return 4 + padded;
    }
    return 4;
}
