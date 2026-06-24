/* Deterministic C test for wl_marshal_varargs.c (Task 3).
 * gcc modules/libwayland_shim/wl_marshal_varargs.c tests/shim_varargs_test.c -o <out>
 *
 * Exercises the trickiest shape — wl_registry.bind's untyped new_id, signature
 * "usun" (name:uint, interface-name:string, version:uint, new_id) — and asserts the
 * variadic entry point unpacks the C varargs into the wl_argument[] the Jai array
 * form expects. A recording stub stands in for the Jai marshaller. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

struct wl_interface;
struct wl_message  { const char *name; const char *signature; const struct wl_interface **types; };
struct wl_interface { const char *name; int version; int method_count; const struct wl_message *methods; int event_count; const struct wl_message *events; };
union  wl_argument { int32_t i; uint32_t u; int32_t f; const char *s; void *o; uint32_t n; void *a; int32_t h; };
struct shim_proxy   { uint32_t id; const struct wl_interface *interface; };

static union wl_argument recorded[20];
static int      recorded_count;
static uint32_t recorded_opcode;

/* Stub standing in for the Jai-exported wl_proxy_marshal_array_flags. */
void *wl_proxy_marshal_array_flags(void *proxy, uint32_t opcode,
        const struct wl_interface *interface, uint32_t version,
        uint32_t flags, union wl_argument *args)
{
    (void)interface; (void)version; (void)flags;
    const struct shim_proxy *p = proxy;
    const char *sig = p->interface->methods[opcode].signature;
    int count = 0;
    for (const char *c = sig; *c; c++) {
        if ((*c >= '0' && *c <= '9') || *c == '?') continue;
        count++;
    }
    recorded_opcode = opcode;
    recorded_count  = count;
    memcpy(recorded, args, (size_t)count * sizeof(union wl_argument));
    return (void *)0xABCD;  /* sentinel return value */
}

extern void *wl_proxy_marshal_flags(void *proxy, uint32_t opcode,
        const struct wl_interface *interface, uint32_t version,
        uint32_t flags, ...);

int main(void)
{
    struct wl_message   reqs[1]  = { { "bind", "usun", 0 } };
    struct wl_interface registry = { "wl_registry", 1, 1, reqs, 0, 0 };
    struct wl_interface target   = { "wl_compositor", 4, 0, 0, 0, 0 };
    struct shim_proxy   proxy    = { 7, &registry };

    void *r = wl_proxy_marshal_flags(&proxy, 0, &target, 4, 0,
            (uint32_t)42, "wl_compositor", (uint32_t)4, (void *)0);

    int ok = 1;
    if (r != (void *)0xABCD)                       { printf("FAIL: return %p\n", r); ok = 0; }
    if (recorded_opcode != 0)                      { printf("FAIL: opcode %u\n", recorded_opcode); ok = 0; }
    if (recorded_count  != 4)                      { printf("FAIL: count %d\n", recorded_count); ok = 0; }
    if (recorded[0].u != 42)                       { printf("FAIL: arg0 (name) %u\n", recorded[0].u); ok = 0; }
    if (strcmp(recorded[1].s, "wl_compositor"))    { printf("FAIL: arg1 (iface) %s\n", recorded[1].s); ok = 0; }
    if (recorded[2].u != 4)                        { printf("FAIL: arg2 (version) %u\n", recorded[2].u); ok = 0; }
    if (recorded[3].o != (void *)0)                { printf("FAIL: arg3 (new_id placeholder) %p\n", recorded[3].o); ok = 0; }

    printf(ok ? "shim_varargs_test: ALL PASS\n" : "shim_varargs_test: FAIL\n");
    return ok ? 0 : 1;
}
