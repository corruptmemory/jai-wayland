// Runtime loader: dlopen libgbm.so.1 and resolve function pointers.

#import "POSIX";

init_gbm :: () -> bool {
    gbm_lib := dlopen("libgbm.so.1", RTLD_LAZY);
    if !gbm_lib  gbm_lib = dlopen("libgbm.so", RTLD_LAZY);
    if !gbm_lib  return false;

    gbm_create_device  = xx dlsym(gbm_lib, "gbm_create_device");
    gbm_device_destroy = xx dlsym(gbm_lib, "gbm_device_destroy");
    gbm_device_get_fd  = xx dlsym(gbm_lib, "gbm_device_get_fd");

    return gbm_create_device != null;
}
