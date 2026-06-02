// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers

// Runtime loader: dlopen libgbm.so.1 and resolve function pointers.

#import "POSIX";

init_gbm :: () -> bool {
    gbm_lib := dlopen("libgbm.so.1", RTLD_LAZY);
    if !gbm_lib  gbm_lib = dlopen("libgbm.so", RTLD_LAZY);
    if !gbm_lib  return false;

    gbm_create_device  = xx dlsym(gbm_lib, "gbm_create_device");
    gbm_device_destroy = xx dlsym(gbm_lib, "gbm_device_destroy");
    gbm_device_get_fd  = xx dlsym(gbm_lib, "gbm_device_get_fd");
    gbm_device_get_backend_name = xx dlsym(gbm_lib, "gbm_device_get_backend_name");
    gbm_device_is_format_supported = xx dlsym(gbm_lib, "gbm_device_is_format_supported");
    gbm_device_get_format_modifier_plane_count = xx dlsym(gbm_lib, "gbm_device_get_format_modifier_plane_count");

    gbm_bo_create = xx dlsym(gbm_lib, "gbm_bo_create");
    gbm_bo_create_with_modifiers = xx dlsym(gbm_lib, "gbm_bo_create_with_modifiers");
    gbm_bo_create_with_modifiers2 = xx dlsym(gbm_lib, "gbm_bo_create_with_modifiers2");
    gbm_bo_destroy = xx dlsym(gbm_lib, "gbm_bo_destroy");
    gbm_bo_get_width = xx dlsym(gbm_lib, "gbm_bo_get_width");
    gbm_bo_get_height = xx dlsym(gbm_lib, "gbm_bo_get_height");
    gbm_bo_get_stride = xx dlsym(gbm_lib, "gbm_bo_get_stride");
    gbm_bo_get_stride_for_plane = xx dlsym(gbm_lib, "gbm_bo_get_stride_for_plane");
    gbm_bo_get_format = xx dlsym(gbm_lib, "gbm_bo_get_format");
    gbm_bo_get_bpp = xx dlsym(gbm_lib, "gbm_bo_get_bpp");
    gbm_bo_get_offset = xx dlsym(gbm_lib, "gbm_bo_get_offset");
    gbm_bo_get_device = xx dlsym(gbm_lib, "gbm_bo_get_device");
    gbm_bo_get_handle = xx dlsym(gbm_lib, "gbm_bo_get_handle");
    gbm_bo_get_fd = xx dlsym(gbm_lib, "gbm_bo_get_fd");
    gbm_bo_get_modifier = xx dlsym(gbm_lib, "gbm_bo_get_modifier");
    gbm_bo_get_plane_count = xx dlsym(gbm_lib, "gbm_bo_get_plane_count");
    gbm_bo_get_handle_for_plane = xx dlsym(gbm_lib, "gbm_bo_get_handle_for_plane");
    gbm_bo_get_fd_for_plane = xx dlsym(gbm_lib, "gbm_bo_get_fd_for_plane");

    return gbm_create_device != null;
}
