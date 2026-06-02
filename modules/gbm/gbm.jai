// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers

// libgbm types + DRM fourcc helpers + function-pointer declarations.

Gbm_Device :: *void;
Gbm_Bo     :: *void;

Gbm_Bo_Handle :: union {
    as_ptr: *void;
    as_s32: s32;
    as_u32: u32;
    as_s64: s64;
    as_u64: u64;
}

// Buffer-object usage flags.
GBM_BO_USE_SCANOUT   :: 1 << 0;
GBM_BO_USE_CURSOR    :: 1 << 1;
GBM_BO_USE_RENDERING :: 1 << 2;
GBM_BO_USE_WRITE     :: 1 << 3;
GBM_BO_USE_LINEAR    :: 1 << 4;
GBM_BO_USE_PROTECTED :: 1 << 5;
GBM_BO_USE_FRONT_RENDERING :: 1 << 6;

// DRM fourcc packing: four ASCII chars, little-endian u32.
// Note the explicit parenthesization on each cast+shift — in Jai's grammar,
// `cast(u32) b << 8` parses as `cast(u32) (b << 8)`, which silently
// truncates b to u8 before shifting (producing 0). Been there, debugged
// that — the explicit parens here are load-bearing.
gbm_fourcc :: (a: u8, b: u8, c: u8, d: u8) -> u32 {
    return (cast(u32) a)
         | ((cast(u32) b) << 8)
         | ((cast(u32) c) << 16)
         | ((cast(u32) d) << 24);
}

GBM_FORMAT_XRGB8888 :: #run gbm_fourcc(#char "X", #char "R", #char "2", #char "4");
GBM_FORMAT_ARGB8888 :: #run gbm_fourcc(#char "A", #char "R", #char "2", #char "4");
GBM_FORMAT_ABGR8888 :: #run gbm_fourcc(#char "A", #char "B", #char "2", #char "4");
GBM_FORMAT_XBGR8888 :: #run gbm_fourcc(#char "X", #char "B", #char "2", #char "4");

// Function pointers — populated by init_gbm() via dlsym.
// Keep these runtime-resolved; do not add #foreign/#library link-time deps.
gbm_create_device:  #type (fd: s32) -> Gbm_Device #c_call;
gbm_device_destroy: #type (gbm: Gbm_Device) #c_call;
gbm_device_get_fd:  #type (gbm: Gbm_Device) -> s32 #c_call;
gbm_device_get_backend_name: #type (gbm: Gbm_Device) -> *u8 #c_call;
gbm_device_is_format_supported: #type (gbm: Gbm_Device, format: u32, flags: u32) -> s32 #c_call;
gbm_device_get_format_modifier_plane_count: #type (gbm: Gbm_Device, format: u32, modifier: u64) -> s32 #c_call;

gbm_bo_create: #type (gbm: Gbm_Device, width: u32, height: u32, format: u32, flags: u32) -> Gbm_Bo #c_call;
gbm_bo_create_with_modifiers: #type (gbm: Gbm_Device, width: u32, height: u32, format: u32, modifiers: *u64, count: u32) -> Gbm_Bo #c_call;
gbm_bo_create_with_modifiers2: #type (gbm: Gbm_Device, width: u32, height: u32, format: u32, modifiers: *u64, count: u32, flags: u32) -> Gbm_Bo #c_call;
gbm_bo_destroy: #type (bo: Gbm_Bo) #c_call;
gbm_bo_get_width: #type (bo: Gbm_Bo) -> u32 #c_call;
gbm_bo_get_height: #type (bo: Gbm_Bo) -> u32 #c_call;
gbm_bo_get_stride: #type (bo: Gbm_Bo) -> u32 #c_call;
gbm_bo_get_stride_for_plane: #type (bo: Gbm_Bo, plane: s32) -> u32 #c_call;
gbm_bo_get_format: #type (bo: Gbm_Bo) -> u32 #c_call;
gbm_bo_get_bpp: #type (bo: Gbm_Bo) -> u32 #c_call;
gbm_bo_get_offset: #type (bo: Gbm_Bo, plane: s32) -> u32 #c_call;
gbm_bo_get_device: #type (bo: Gbm_Bo) -> Gbm_Device #c_call;
gbm_bo_get_handle: #type (bo: Gbm_Bo) -> Gbm_Bo_Handle #c_call;
gbm_bo_get_fd: #type (bo: Gbm_Bo) -> s32 #c_call;
gbm_bo_get_modifier: #type (bo: Gbm_Bo) -> u64 #c_call;
gbm_bo_get_plane_count: #type (bo: Gbm_Bo) -> s32 #c_call;
gbm_bo_get_handle_for_plane: #type (bo: Gbm_Bo, plane: s32) -> Gbm_Bo_Handle #c_call;
gbm_bo_get_fd_for_plane: #type (bo: Gbm_Bo, plane: s32) -> s32 #c_call;
