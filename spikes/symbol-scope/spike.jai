// SYMBOL-SCOPE SPIKE  (libwayland-client-proxy, task 1)
//
// Linchpin question for the whole duck-type approach:
//   Can a Jai EXECUTABLE interpose its own definition of a libwayland symbol
//   over a *real* libwayland-client that a dlopened .so pulls in via DT_NEEDED?
//
// That is the exact ELF condition the Vulkan ICD imposes: libvulkan_radeon.so
// (and NVIDIA's equivalent) DT_NEEDEDs libwayland-client.so.0 AND imports
// wl_proxy_* as undefined symbols. For our from-scratch client to masquerade
// as libwayland behind vkCreateWaylandSurfaceKHR, the ICD's wl_* calls must
// land in OUR code, not real libwayland's.
//
//   YES -> the proxy is mechanically possible; design can proceed.
//   NO  -> the proxy approach is dead; game-bootstrap's real-libwayland path
//          stays the only route.

#import "Basic";
#import "POSIX";

SENTINEL : u32 : 0xDEAD_BEEF;

// Our masquerade definition of a genuine libwayland-client entry point.
// #c_call = C ABI, no Jai context. We deliberately do NOT deref `proxy`, so a
// NULL argument is harmless when (and only when) OUR code is the one running.
#program_export
wl_proxy_get_version :: (proxy: *void) -> u32 #c_call {
    return SENTINEL;
}

Which_Proc :: #type () -> *void #c_call;
Call_Proc  :: #type () -> u32   #c_call;

ICD_PATH :: "/home/jim/projects/jai-wayland/spikes/symbol-scope/build/libspike_icd.so";
REAL_ICD :: "/usr/lib/libvulkan_radeon.so";

main :: () {
    print("\n=== symbol-scope spike: does a Jai exe interpose libwayland? ===\n");

    // --- Primary test: our fake ICD (DT_NEEDEDs real libwayland) -----------
    h := dlopen(to_c_string(ICD_PATH), RTLD_NOW | RTLD_GLOBAL);
    if !h {
        print("FAIL: dlopen(%) -> %\n", ICD_PATH, to_string(dlerror()));
        return;
    }

    which := cast(Which_Proc) dlsym(h, to_c_string("spike_which_wl_proxy_get_version"));
    call  := cast(Call_Proc)  dlsym(h, to_c_string("spike_call_wl_proxy_get_version"));
    if which == null || call == null {
        print("FAIL: dlsym -> %\n", to_string(dlerror()));
        return;
    }

    our_addr := cast(*void) wl_proxy_get_version;
    icd_addr := which();
    interposed := icd_addr == our_addr;

    print("\nour  wl_proxy_get_version @ %\n", our_addr);
    print("icd-resolved wl_proxy_... @ %\n", icd_addr);
    print("address interposition     : %\n", ifx interposed then "YES" else "NO");

    landed := false;
    if interposed {
        // Safe now: the call routes into our NULL-tolerant stub.
        ret := call();
        landed = ret == SENTINEL;
        print("live call returned        : % (sentinel %)\n", ret, SENTINEL);
        print("live call ran OUR stub    : %\n", ifx landed then "YES" else "NO");
    } else {
        print("live call skipped         : would dispatch into real libwayland on NULL\n");
    }

    // --- Secondary sanity: does the REAL Mesa ICD coexist in-process? -------
    rh := dlopen(to_c_string(REAL_ICD), RTLD_NOW | RTLD_LOCAL);
    print("\nreal radeon ICD dlopen    : %\n",
          ifx rh then "OK (coexists in-process with our interposed symbol)"
                 else tprint("not loaded (%)", to_string(dlerror())));

    ok := interposed && landed;
    print("\n=================================================================\n");
    print("VERDICT: %\n", ifx ok
        then "LINCHPIN HOLDS - a Jai exe interposes libwayland; duck-type is mechanically possible."
        else "LINCHPIN FAILED - exe cannot interpose; proxy approach is blocked.");
    print("=================================================================\n");
}
