// libgbm types + DRM fourcc helpers + function-pointer declarations.

Gbm_Device :: *void;
Gbm_Bo     :: *void;

// Buffer-object usage flags.
GBM_BO_USE_SCANOUT   :: 1 << 0;
GBM_BO_USE_CURSOR    :: 1 << 1;
GBM_BO_USE_RENDERING :: 1 << 2;
GBM_BO_USE_WRITE     :: 1 << 3;
GBM_BO_USE_LINEAR    :: 1 << 4;

// DRM fourcc packing: four ASCII chars, little-endian u32.
gbm_fourcc :: (a: u8, b: u8, c: u8, d: u8) -> u32 {
    return cast(u32) a | (cast(u32) b << 8) | (cast(u32) c << 16) | (cast(u32) d << 24);
}

GBM_FORMAT_XRGB8888 :: #run gbm_fourcc(#char "X", #char "R", #char "2", #char "4");
GBM_FORMAT_ARGB8888 :: #run gbm_fourcc(#char "A", #char "R", #char "2", #char "4");
GBM_FORMAT_ABGR8888 :: #run gbm_fourcc(#char "A", #char "B", #char "2", #char "4");
GBM_FORMAT_XBGR8888 :: #run gbm_fourcc(#char "X", #char "B", #char "2", #char "4");

// Function pointers — populated by init_gbm() via dlsym.
// We only need a gbm_device to drive EGL_PLATFORM_GBM_KHR; we render to GL textures,
// not gbm BOs directly, so the bo_* API is omitted.
gbm_create_device:  #type (fd: s32) -> Gbm_Device #c_call;
gbm_device_destroy: #type (gbm: Gbm_Device) #c_call;
gbm_device_get_fd:  #type (gbm: Gbm_Device) -> s32 #c_call;
