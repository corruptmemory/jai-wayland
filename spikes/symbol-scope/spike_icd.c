/* Fake Vulkan ICD for the symbol-scope spike (libwayland-client-proxy, task 1).
 *
 * Mirrors the relevant ELF shape of /usr/lib/libvulkan_radeon.so:
 *   - DT_NEEDED libwayland-client.so.0   (via -lwayland-client at link time)
 *   - an UNDEFINED import of a wl_proxy_* entry point
 *
 * So when the spike executable dlopen()s this object, REAL libwayland-client is
 * pulled into the process automatically. The question the spike answers is
 * whether the executable's own definition of wl_proxy_get_version *interposes*
 * over that real libwayland — the exact condition the NVIDIA/Mesa ICD imposes.
 */
#include <stdint.h>

extern uint32_t wl_proxy_get_version(void *proxy);

/* Returns the address THIS object resolved the import to. Under correct
 * interposition that is the executable's stub; otherwise real libwayland's. */
void *spike_which_wl_proxy_get_version(void) {
    return (void *)&wl_proxy_get_version;
}

/* Actually invokes the import with NULL. If interposed, the executable's stub
 * runs (it never derefs the arg) and returns its sentinel. If not interposed,
 * real libwayland derefs NULL and crashes — which is why the spike gates this
 * call on the address check before calling. */
uint32_t spike_call_wl_proxy_get_version(void) {
    return wl_proxy_get_version(0);
}
