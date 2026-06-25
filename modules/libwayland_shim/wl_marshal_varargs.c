/* SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Jim Powers
 *
 * The ENTIRE C surface of the libwayland-client proxy.
 *
 * The Vulkan ICD imports the *variadic* wl_proxy_marshal_flags(proxy, opcode,
 * interface, version, flags, ...). Jai cannot author a function that READS C
 * varargs (its only vararg facility is ..Any, which needs Jai type-info that raw
 * C varargs lack; the compiler even rejects forwarding — see Android/Jni.jai). So
 * this one function unpacks the varargs into a wl_argument[] per the message
 * signature and tail-calls the pure-Jai wl_proxy_marshal_array_flags. It mirrors
 * libwayland's own wl_argument_from_va_list. Our own compiled-in object — no
 * external library; the linkage thesis is intact.
 */
#include <stdint.h>
#include <stdarg.h>

struct wl_interface;

struct wl_message {
    const char *name;
    const char *signature;
    const struct wl_interface **types;
};

struct wl_interface {
    const char *name;
    int version;
    int method_count;
    const struct wl_message *methods;
    int event_count;
    const struct wl_message *events;
};

union wl_argument {
    int32_t i;
    uint32_t u;
    int32_t f;        /* wl_fixed_t */
    const char *s;
    void *o;
    uint32_t n;
    void *a;
    int32_t h;
};

/* The leading fields of libwayland_shim's Wl_Proxy: { u32 id; *wl_interface
 * interface_; ... }. The interface pointer sits at offset 8 (4-byte id + 4 pad).
 * We only read the message signature off it, exactly as libwayland does. */
struct shim_proxy {
    uint32_t id;
    const struct wl_interface *interface;
};

/* Implemented in Jai (#program_export, modules/libwayland_shim/marshal_runtime.jai). */
extern void *wl_proxy_marshal_array_flags(void *proxy, uint32_t opcode,
        const struct wl_interface *interface, uint32_t version,
        uint32_t flags, union wl_argument *args);

#define WL_CLOSURE_MAX_ARGS 20

void *wl_proxy_marshal_flags(void *proxy, uint32_t opcode,
        const struct wl_interface *interface, uint32_t version,
        uint32_t flags, ...)
{
    const struct wl_message *msg =
        &((const struct shim_proxy *)proxy)->interface->methods[opcode];
    const char *sig = msg->signature;

    union wl_argument args[WL_CLOSURE_MAX_ARGS];
    int count = 0;
    va_list ap;
    va_start(ap, flags);
    for (const char *p = sig; *p; p++) {
        if (*p >= '0' && *p <= '9') continue;  /* "since" version digits */
        if (*p == '?')             continue;   /* nullable modifier      */
        switch (*p) {
            case 'i': args[count].i = va_arg(ap, int32_t);      break;
            case 'u': args[count].u = va_arg(ap, uint32_t);     break;
            case 'f': args[count].f = va_arg(ap, int32_t);      break; /* wl_fixed_t */
            case 's': args[count].s = va_arg(ap, const char *); break;
            case 'o': args[count].o = va_arg(ap, void *);       break;
            case 'n': args[count].o = va_arg(ap, void *);       break; /* new_id placeholder */
            case 'a': args[count].a = va_arg(ap, void *);       break;
            case 'h': args[count].h = va_arg(ap, int32_t);      break;
            default:  continue;
        }
        count++;
    }
    va_end(ap);

    return wl_proxy_marshal_array_flags(proxy, opcode, interface, version, flags, args);
}
