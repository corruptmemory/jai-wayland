// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers

// hello_vkwl_swapchain — THE milestone. A real Vulkan ICD (Mesa RADV) drives our
// duck-type libwayland-client to present frames through a Wayland swapchain.
//
// We build an xdg_toplevel window ENTIRELY through modules/libwayland_shim — our
// from-scratch wire client masquerading as libwayland-client — then hand the bare
// wl_display + wl_surface to Vulkan via vkCreateWaylandSurfaceKHR. From there the ICD
// owns the swapchain: it drives get_registry, registry.bind, wl_buffer creation,
// wl_surface.attach/commit, and frame-callback dispatch THROUGH OUR exported wl_*
// symbols (interposed over the libwayland-client the ICD imports via DT_NEEDED). Real
// libwayland-client is never loaded — asserted in-process by scanning /proc/self/maps,
// and externally by `ldd` (libc + libm only).
//
// The app renders nothing fancy: each swapchain image gets a color-cycling clear via
// vkCmdClearColorImage (no render pass / pipeline needed). Runs N frames, default 240;
// override with JAI_WAYLAND_VKWL_FRAMES=N for bounded or longer smoke runs.

S      :: #import,dir "../modules/libwayland_shim";
Vulkan :: #import,dir "../modules/Vulkan";

#import "Basic";
#import "POSIX";
#import "String";
#import "File";
Math :: #import "Math";

DEFAULT_WIDTH  :: 800;
DEFAULT_HEIGHT :: 600;

// ── Vulkan WSI Wayland surface ──────────────────────────────────────────────────
// Not in the vendored Vulkan module (it was generated without VK_USE_PLATFORM_WAYLAND_KHR,
// since the real create-info references libwayland's wl_display*/wl_surface*). We declare
// the one struct + entry point ourselves. The ICD treats display/surface as opaque
// libwayland pointers and hands them straight back to our exported wl_* functions. Our
// *Wl_Display is reinterpretable as the display's wl_proxy (proxy is its first member).
VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME :: "VK_KHR_wayland_surface";
VK_QUEUE_FAMILY_IGNORED : u32 : 0xFFFF_FFFF;  // not emitted as a flat const by the generator

VkWaylandSurfaceCreateInfoKHR :: struct {
    sType:   Vulkan.VkStructureType = .WAYLAND_SURFACE_CREATE_INFO_KHR;
    pNext:   *void;
    flags:   u32;
    display: *void;  // *wl_display  (our *S.Wl_Display)
    surface: *void;  // *wl_surface  (our *S.Wl_Proxy)
}

PFN_vkCreateWaylandSurfaceKHR :: #type (
    instance:    Vulkan.VkInstance,
    pCreateInfo: *VkWaylandSurfaceCreateInfoKHR,
    pAllocator:  *void,
    pSurface:    *Vulkan.VkSurfaceKHR,
) -> Vulkan.VkResult #c_call;

// ── window / event state (file scope so the #c_call listeners reach it) ──────────
Global :: struct { name: u32; interface_: string; version: u32; }

g_globals:       [256] Global;
g_global_count:  int;

g_display:       *S.Wl_Display;
g_wm_base:       *S.Wl_Proxy;
g_xdg_surface:   *S.Wl_Proxy;

g_configured:    bool;          // xdg_surface.configure has arrived at least once
g_ack_pending:   bool;          // an unacked configure serial is waiting
g_ack_serial:    u32;
g_ping_pending:  bool;
g_ping_serial:   u32;
g_should_close:  bool;          // xdg_toplevel.close

// listener vtables — filled at runtime (proc addresses aren't compile-time constants)
disp_vtable:     [2] *void;
reg_vtable:      [2] *void;
wm_base_vtable:  [1] *void;
xsurf_vtable:    [1] *void;
toplevel_vtable: [4] *void;

// ── listeners (#c_call — no Jai context; only touch file-scope state) ────────────
on_error :: (data: *void, display: *void, object_id: *void, code: u32, message: *u8) #c_call {
    push_context S.shim_context {
        print("  !! wl_display.error: code=%  msg=%\n", code, to_string(message));
    }
}
on_delete_id :: (data: *void, display: *void, id: u32) #c_call {}

on_global :: (data: *void, registry: *void, name: u32, interface_: *u8, version: u32) #c_call {
    push_context S.shim_context {
        if g_global_count < g_globals.count {
            g_globals[g_global_count] = .{ name, copy_string(to_string(interface_)), version };
            g_global_count += 1;
        }
    }
}
on_global_remove :: (data: *void, registry: *void, name: u32) #c_call {}

on_ping :: (data: *void, wm_base: *void, serial: u32) #c_call {
    g_ping_serial  = serial;
    g_ping_pending = true;
}

on_xdg_surface_configure :: (data: *void, xdg_surface: *void, serial: u32) #c_call {
    g_ack_serial  = serial;
    g_ack_pending = true;
    g_configured  = true;
}

on_toplevel_configure :: (data: *void, toplevel: *void, width: s32, height: s32, states: *void) #c_call {
    // We keep a fixed swapchain size for this smoke; just observe.
    push_context S.shim_context {
        if width > 0 && height > 0  print("  xdg_toplevel.configure: %x%\n", width, height);
    }
}
on_toplevel_close  :: (data: *void, toplevel: *void) #c_call { g_should_close = true; }
on_toplevel_bounds :: (data: *void, toplevel: *void, width: s32, height: s32) #c_call {}
on_toplevel_wmcaps :: (data: *void, toplevel: *void, caps: *void) #c_call {}

// Service the app's window between Vulkan frames: answer ping, ack configure. Runs with
// a real Jai context (called from main), so it may marshal requests.
service_window :: (display: *S.Wl_Display) {
    if g_ping_pending {
        args: [1] S.wl_argument;
        args[0].u = g_ping_serial;
        S.shim_request(g_wm_base, S.XDG_WM_BASE_PONG, null, 0, args);
        g_ping_pending = false;
    }
    if g_ack_pending {
        args: [1] S.wl_argument;
        args[0].u = g_ack_serial;
        S.shim_request(g_xdg_surface, S.XDG_SURFACE_ACK_CONFIGURE, null, 0, args);
        g_ack_pending = false;
    }
}

find_global :: (interface_: string) -> *Global {
    for * g_globals  { if it_index >= g_global_count  break; if it.interface_ == interface_  return it; }
    return null;
}

frame_limit_from_env :: () -> int {
    s := to_string(getenv("JAI_WAYLAND_VKWL_FRAMES"));
    if s.count {
        value, ok := to_integer(s);
        if ok && value > 0  return value;
    }
    return 240;
}

assert_no_real_libwayland :: () -> bool {
    maps, ok := read_entire_file("/proc/self/maps");
    if !ok  { print("  (could not read /proc/self/maps to verify interposition)\n"); return true; }
    defer free(maps.data);
    if contains(maps, "libwayland-client") {
        print("  !! FAIL: real libwayland-client.so is mapped — interposition did NOT hold.\n");
        return false;
    }
    print("  interposition holds: no libwayland-client in /proc/self/maps.\n");
    return true;
}

main :: () {
    print("hello_vkwl_swapchain — Vulkan ICD → duck-type libwayland → live Hyprland\n\n");

    // ── 0. Disable implicit Vulkan layers that open their OWN libwayland connection ──
    // The MESA device-select layer (and friends) wl_display_connect() to the compositor
    // to pick a GPU. Our wl_* symbols are exported with default visibility, so the loader
    // hijacks THOSE calls too — feeding a real-libwayland proxy (different struct layout)
    // into our marshaller, which then crashes. Those layers are orthogonal to the WSI
    // present path we are proving, so we exclude them. This is a genuine property of
    // GLOBAL symbol interposition: any co-resident real-libwayland user in the same
    // process gets captured. A production duck-type would need to guarantee it is the
    // ONLY libwayland consumer in-process (or scope the interposition). Set before the
    // loader reads them at vkCreateInstance.
    setenv("NODEVICE_SELECT",              "1", 1);
    setenv("DISABLE_MANGOHUD",             "1", 1);
    setenv("DISABLE_LAYER_MESA_ANTI_LAG",  "1", 1);

    // ── 1. Connect + build the xdg window through OUR shim ──────────────────────
    display := S.shim_connect();
    if display == null  { print("FAILED: shim_connect.\n"); exit(1); }
    g_display = display;

    disp_vtable[0] = cast(*void) on_error;
    disp_vtable[1] = cast(*void) on_delete_id;
    S.wl_proxy_add_listener(*display.proxy, disp_vtable.data, null);

    registry := S.shim_get_registry(display);
    if registry == null  { print("FAILED: get_registry.\n"); exit(1); }
    reg_vtable[0] = cast(*void) on_global;
    reg_vtable[1] = cast(*void) on_global_remove;
    S.wl_proxy_add_listener(registry, reg_vtable.data, null);
    S.shim_roundtrip(display);
    print("registry: % globals advertised.\n", g_global_count);

    comp_g := find_global("wl_compositor");
    wm_g   := find_global("xdg_wm_base");
    if comp_g == null || wm_g == null {
        print("FAILED: compositor=%  xdg_wm_base=% — cannot build a window.\n",
            comp_g != null, wm_g != null);
        exit(1);
    }

    compositor := bind_global(registry, comp_g, *S.wl_compositor_interface, 6);
    g_wm_base   = bind_global(registry, wm_g,   *S.xdg_wm_base_interface, min(wm_g.version, 7));
    wm_base_vtable[0] = cast(*void) on_ping;
    S.wl_proxy_add_listener(g_wm_base, wm_base_vtable.data, null);

    // wl_surface ← compositor.create_surface ("n")
    surface := request1(compositor, S.WL_COMPOSITOR_CREATE_SURFACE, *S.wl_surface_interface, compositor.version);

    // xdg_surface ← xdg_wm_base.get_xdg_surface ("no": new_id, surface)
    {
        args: [2] S.wl_argument;
        args[1].o = cast(*void) surface;
        g_xdg_surface = S.shim_request(g_wm_base, S.XDG_WM_BASE_GET_XDG_SURFACE, *S.xdg_surface_interface, g_wm_base.version, args);
    }
    xsurf_vtable[0] = cast(*void) on_xdg_surface_configure;
    S.wl_proxy_add_listener(g_xdg_surface, xsurf_vtable.data, null);

    // xdg_toplevel ← xdg_surface.get_toplevel ("n")
    toplevel := request1(g_xdg_surface, S.XDG_SURFACE_GET_TOPLEVEL, *S.xdg_toplevel_interface, g_xdg_surface.version);
    toplevel_vtable[0] = cast(*void) on_toplevel_configure;
    toplevel_vtable[1] = cast(*void) on_toplevel_close;
    toplevel_vtable[2] = cast(*void) on_toplevel_bounds;
    toplevel_vtable[3] = cast(*void) on_toplevel_wmcaps;
    S.wl_proxy_add_listener(toplevel, toplevel_vtable.data, null);
    set_title(toplevel, "hello_vkwl_swapchain");

    // Initial commit → compositor responds with the first xdg_surface.configure.
    S.shim_request(surface, S.WL_SURFACE_COMMIT, null, 0, .[]);

    attempts := 0;
    while !g_configured && attempts < 200 {
        S.shim_pump(display, 100);
        service_window(display);
        attempts += 1;
    }
    if !g_configured  { print("FAILED: no first xdg_surface.configure.\n"); exit(1); }
    print("window configured; handing display+surface to Vulkan.\n\n");

    // ── 2. Vulkan: instance + Wayland surface over OUR objects ──────────────────
    if !Vulkan.init_vulkan()  { print("FAILED: init_vulkan (libvulkan not loadable).\n"); exit(1); }

    app_info: Vulkan.VkApplicationInfo;
    app_info.pApplicationName = "jai-wayland hello_vkwl_swapchain".data;
    app_info.applicationVersion = Vulkan.VK_MAKE_VERSION(0, 1, 0);
    app_info.pEngineName = "jai-wayland".data;
    app_info.apiVersion = Vulkan.VK_API_VERSION_1_1;

    inst_exts: [2] *u8;
    inst_exts[0] = Vulkan.VK_KHR_SURFACE_EXTENSION_NAME.data;
    inst_exts[1] = VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME.data;

    ici: Vulkan.VkInstanceCreateInfo;
    ici.pApplicationInfo = *app_info;
    ici.enabledExtensionCount = 2;
    ici.ppEnabledExtensionNames = inst_exts.data;

    instance: Vulkan.VkInstance;
    if Vulkan.vkCreateInstance(*ici, null, *instance) != .SUCCESS {
        print("FAILED: vkCreateInstance (need VK_KHR_surface + VK_KHR_wayland_surface).\n");
        exit(1);
    }
    if !Vulkan.load_vulkan_instance_functions(instance)  { print("FAILED: load instance funcs.\n"); exit(1); }

    // The ICD is now loaded into our process — verify it did NOT drag in real libwayland.
    if !assert_no_real_libwayland()  exit(1);

    vkCreateWaylandSurfaceKHR := cast(PFN_vkCreateWaylandSurfaceKHR)
        Vulkan.vkGetInstanceProcAddr(instance, "vkCreateWaylandSurfaceKHR");
    if vkCreateWaylandSurfaceKHR == null  { print("FAILED: vkCreateWaylandSurfaceKHR not exposed.\n"); exit(1); }

    surf_ci: VkWaylandSurfaceCreateInfoKHR;
    surf_ci.display = cast(*void) display;   // *wl_display  (id 1; proxy is first member)
    surf_ci.surface = cast(*void) surface;   // *wl_surface
    vk_surface: Vulkan.VkSurfaceKHR;
    if vkCreateWaylandSurfaceKHR(instance, *surf_ci, null, *vk_surface) != .SUCCESS {
        print("FAILED: vkCreateWaylandSurfaceKHR.\n"); exit(1);
    }
    print("vkCreateWaylandSurfaceKHR: ICD accepted OUR wl_display + wl_surface.\n");

    // ── 3. Physical device + present queue family + logical device ──────────────
    physical, queue_family, ok := choose_device_and_present_queue(instance, vk_surface);
    if !ok  { print("FAILED: no device with a graphics+present queue on our surface.\n"); exit(1); }

    props: Vulkan.VkPhysicalDeviceProperties;
    Vulkan.vkGetPhysicalDeviceProperties(physical, *props);
    print("physical device: %  (present queue family %)\n", to_string(props.deviceName.data), queue_family);

    device := create_device(physical, queue_family);
    if device == null  { print("FAILED: vkCreateDevice (+VK_KHR_swapchain).\n"); exit(1); }
    if !Vulkan.load_vulkan_device_functions(device)  { print("FAILED: load device funcs.\n"); exit(1); }

    queue: Vulkan.VkQueue;
    Vulkan.vkGetDeviceQueue(device, queue_family, 0, *queue);

    // ── 4. Swapchain over the Wayland surface ───────────────────────────────────
    caps: Vulkan.VkSurfaceCapabilitiesKHR;
    Vulkan.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical, vk_surface, *caps);

    fmt := choose_surface_format(physical, vk_surface);
    extent := caps.currentExtent;
    if extent.width == 0xFFFF_FFFF  extent = .{ DEFAULT_WIDTH, DEFAULT_HEIGHT };

    image_count := caps.minImageCount + 1;
    if caps.maxImageCount > 0 && image_count > caps.maxImageCount  image_count = caps.maxImageCount;

    needed_usage: Vulkan.VkImageUsageFlags = .TRANSFER_DST_BIT | .COLOR_ATTACHMENT_BIT;
    supported_usage := cast(u32) caps.supportedUsageFlags;
    if (supported_usage & cast(u32) Vulkan.VkImageUsageFlagBits.TRANSFER_DST_BIT) == 0 {
        print("FAILED: surface does not support TRANSFER_DST usage (cannot clear).\n"); exit(1);
    }

    sci: Vulkan.VkSwapchainCreateInfoKHR;
    sci.surface          = vk_surface;
    sci.minImageCount    = image_count;
    sci.imageFormat      = fmt.format;
    sci.imageColorSpace  = fmt.colorSpace;
    sci.imageExtent      = extent;
    sci.imageArrayLayers = 1;
    sci.imageUsage       = needed_usage;
    sci.imageSharingMode = .EXCLUSIVE;
    sci.preTransform     = caps.currentTransform;
    sci.compositeAlpha   = .OPAQUE_BIT_KHR;
    sci.presentMode      = .FIFO_KHR;
    sci.clipped          = 1;

    swapchain: Vulkan.VkSwapchainKHR;
    if Vulkan.vkCreateSwapchainKHR(device, *sci, null, *swapchain) != .SUCCESS {
        print("FAILED: vkCreateSwapchainKHR.\n"); exit(1);
    }

    n_images: u32;
    Vulkan.vkGetSwapchainImagesKHR(device, swapchain, *n_images, null);
    images: [8] Vulkan.VkImage;
    if n_images > images.count  n_images = cast(u32) images.count;
    Vulkan.vkGetSwapchainImagesKHR(device, swapchain, *n_images, images.data);
    print("swapchain: % images  %x%  format=%\n\n", n_images, extent.width, extent.height, fmt.format);

    // ── 5. Command pool + buffers + sync ────────────────────────────────────────
    pool_info: Vulkan.VkCommandPoolCreateInfo;
    pool_info.flags = .RESET_COMMAND_BUFFER_BIT;
    pool_info.queueFamilyIndex = queue_family;
    command_pool: Vulkan.VkCommandPool;
    Vulkan.vkCreateCommandPool(device, *pool_info, null, *command_pool);

    cmd_alloc: Vulkan.VkCommandBufferAllocateInfo;
    cmd_alloc.commandPool = command_pool;
    cmd_alloc.level = .PRIMARY;
    cmd_alloc.commandBufferCount = n_images;
    cmds: [8] Vulkan.VkCommandBuffer;
    Vulkan.vkAllocateCommandBuffers(device, *cmd_alloc, cmds.data);

    sem_info: Vulkan.VkSemaphoreCreateInfo;
    acquire_sem, render_sem: Vulkan.VkSemaphore;
    Vulkan.vkCreateSemaphore(device, *sem_info, null, *acquire_sem);
    Vulkan.vkCreateSemaphore(device, *sem_info, null, *render_sem);

    // ── 6. Present loop ─────────────────────────────────────────────────────────
    frame_limit := frame_limit_from_env();
    print("presenting % frames (JAI_WAYLAND_VKWL_FRAMES)…\n", frame_limit);

    presented := 0;
    for frame: 0..frame_limit-1 {
        if g_should_close  { print("xdg_toplevel.close — stopping.\n"); break; }

        index: u32;
        ar := Vulkan.vkAcquireNextImageKHR(device, swapchain, 0xFFFF_FFFF_FFFF_FFFF, acquire_sem, null, *index);
        if ar == .ERROR_OUT_OF_DATE_KHR  { print("swapchain out of date — stopping smoke.\n"); break; }
        if ar != .SUCCESS && ar != .SUBOPTIMAL_KHR  { print("vkAcquireNextImageKHR: %\n", ar); break; }

        record_clear(cmds[index], images[index], frame);

        wait_stage: Vulkan.VkPipelineStageFlags = .TRANSFER_BIT;
        submit: Vulkan.VkSubmitInfo;
        submit.waitSemaphoreCount   = 1;
        submit.pWaitSemaphores      = *acquire_sem;
        submit.pWaitDstStageMask    = *wait_stage;
        submit.commandBufferCount   = 1;
        submit.pCommandBuffers      = *cmds[index];
        submit.signalSemaphoreCount = 1;
        submit.pSignalSemaphores    = *render_sem;
        if Vulkan.vkQueueSubmit(queue, 1, *submit, null) != .SUCCESS  { print("vkQueueSubmit failed.\n"); break; }

        present: Vulkan.VkPresentInfoKHR;
        present.waitSemaphoreCount = 1;
        present.pWaitSemaphores    = *render_sem;
        present.swapchainCount     = 1;
        present.pSwapchains        = *swapchain;
        present.pImageIndices      = *index;
        pr := Vulkan.vkQueuePresentKHR(queue, *present);
        if pr == .ERROR_OUT_OF_DATE_KHR  { print("present: swapchain out of date — stopping.\n"); break; }

        Vulkan.vkQueueWaitIdle(queue);   // smoke: serialize so the two semaphores recycle safely

        // Service OUR window (ping/configure/close) while the ICD owns the swapchain.
        S.shim_pump(display, 0);
        service_window(display);
        presented += 1;
    }

    print("\npresented % frames through the duck-type libwayland → ICD swapchain.\n", presented);

    // ── 7. Teardown ─────────────────────────────────────────────────────────────
    Vulkan.vkDeviceWaitIdle(device);
    Vulkan.vkDestroySemaphore(device, acquire_sem, null);
    Vulkan.vkDestroySemaphore(device, render_sem, null);
    Vulkan.vkDestroyCommandPool(device, command_pool, null);
    Vulkan.vkDestroySwapchainKHR(device, swapchain, null);
    Vulkan.vkDestroySurfaceKHR(instance, vk_surface, null);
    Vulkan.vkDestroyDevice(device, null);
    Vulkan.vkDestroyInstance(instance, null);

    if presented > 0 {
        print("\nhello_vkwl_swapchain: OK — a real Vulkan ICD presented through our wire client.\n");
        exit(0);
    }
    print("\nhello_vkwl_swapchain: FAILED — no frames presented.\n");
    exit(1);
}

// ── small request helpers over the shim ──────────────────────────────────────────

// A request whose only arg is the new_id placeholder ("n"): create_surface / get_toplevel.
// marshal_impl reads args[0] for the 'n' char (and ignores its value), so we must pass a
// 1-slot array — never an empty slice (that would deref null).
request1 :: (proxy: *S.Wl_Proxy, opcode: u32, new_iface: *S.wl_interface, version: u32) -> *S.Wl_Proxy {
    args: [1] S.wl_argument;
    return S.shim_request(proxy, opcode, new_iface, version, args);
}

bind_global :: (registry: *S.Wl_Proxy, g: *Global, iface: *S.wl_interface, version: u32) -> *S.Wl_Proxy {
    // wl_registry.bind signature "usun": name(u), interface-name(s), version(u), new_id(n).
    bind_version := min(g.version, version);
    args: [4] S.wl_argument;
    args[0].u = g.name;
    args[1].s = iface.name;
    args[2].u = bind_version;
    return S.shim_request(registry, S.WL_REGISTRY_BIND, iface, bind_version, args);
}

set_title :: (toplevel: *S.Wl_Proxy, title: string) {
    ctitle := to_c_string(title);
    defer free(ctitle);
    args: [1] S.wl_argument;
    args[0].s = ctitle;
    S.shim_request(toplevel, S.XDG_TOPLEVEL_SET_TITLE, null, 0, args);
}

// ── Vulkan helpers ────────────────────────────────────────────────────────────────

choose_device_and_present_queue :: (instance: Vulkan.VkInstance, surface: Vulkan.VkSurfaceKHR) -> Vulkan.VkPhysicalDevice, u32, bool {
    count: u32;
    if Vulkan.vkEnumeratePhysicalDevices(instance, *count, null) != .SUCCESS || count == 0  return null, 0, false;
    devices: [16] Vulkan.VkPhysicalDevice;
    if count > devices.count  count = cast(u32) devices.count;
    Vulkan.vkEnumeratePhysicalDevices(instance, *count, devices.data);

    for di: 0..count-1 {
        phys := devices[di];
        if !device_supports_extension(phys, Vulkan.VK_KHR_SWAPCHAIN_EXTENSION_NAME)  continue;

        qcount: u32;
        Vulkan.vkGetPhysicalDeviceQueueFamilyProperties(phys, *qcount, null);
        if qcount == 0  continue;
        qprops: [32] Vulkan.VkQueueFamilyProperties;
        if qcount > qprops.count  qcount = cast(u32) qprops.count;
        Vulkan.vkGetPhysicalDeviceQueueFamilyProperties(phys, *qcount, qprops.data);

        for qi: 0..qcount-1 {
            flags := cast(u32) qprops[qi].queueFlags;
            is_graphics := (flags & cast(u32) Vulkan.VkQueueFlagBits.GRAPHICS_BIT) != 0;
            if !is_graphics  continue;
            supported: Vulkan.VkBool32;
            Vulkan.vkGetPhysicalDeviceSurfaceSupportKHR(phys, qi, surface, *supported);
            if supported != 0  return phys, qi, true;
        }
    }
    return null, 0, false;
}

device_supports_extension :: (physical: Vulkan.VkPhysicalDevice, name: string) -> bool {
    count: u32;
    if Vulkan.vkEnumerateDeviceExtensionProperties(physical, null, *count, null) != .SUCCESS || count == 0  return false;
    props: [512] Vulkan.VkExtensionProperties;
    if count > props.count  count = cast(u32) props.count;
    if Vulkan.vkEnumerateDeviceExtensionProperties(physical, null, *count, props.data) != .SUCCESS  return false;
    for 0..count-1  if to_string(props[it].extensionName.data) == name  return true;
    return false;
}

create_device :: (physical: Vulkan.VkPhysicalDevice, queue_family: u32) -> Vulkan.VkDevice {
    priority: float = 1.0;
    qci: Vulkan.VkDeviceQueueCreateInfo;
    qci.queueFamilyIndex = queue_family;
    qci.queueCount = 1;
    qci.pQueuePriorities = *priority;

    exts: [1] *u8;
    exts[0] = Vulkan.VK_KHR_SWAPCHAIN_EXTENSION_NAME.data;

    dci: Vulkan.VkDeviceCreateInfo;
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = *qci;
    dci.enabledExtensionCount = 1;
    dci.ppEnabledExtensionNames = exts.data;

    device: Vulkan.VkDevice;
    if Vulkan.vkCreateDevice(physical, *dci, null, *device) != .SUCCESS  return null;
    return device;
}

choose_surface_format :: (physical: Vulkan.VkPhysicalDevice, surface: Vulkan.VkSurfaceKHR) -> Vulkan.VkSurfaceFormatKHR {
    count: u32;
    Vulkan.vkGetPhysicalDeviceSurfaceFormatsKHR(physical, surface, *count, null);
    formats: [64] Vulkan.VkSurfaceFormatKHR;
    if count > formats.count  count = cast(u32) formats.count;
    Vulkan.vkGetPhysicalDeviceSurfaceFormatsKHR(physical, surface, *count, formats.data);

    if count == 0  return .{};  // no formats — swapchain creation will fail downstream
    for 0..count-1 {
        if formats[it].format == .B8G8R8A8_UNORM || formats[it].format == .B8G8R8A8_SRGB  return formats[it];
    }
    return formats[0];
}

record_clear :: (cmd: Vulkan.VkCommandBuffer, image: Vulkan.VkImage, frame: int) {
    Vulkan.vkResetCommandBuffer(cmd, 0);
    begin: Vulkan.VkCommandBufferBeginInfo;
    begin.flags = .ONE_TIME_SUBMIT_BIT;
    Vulkan.vkBeginCommandBuffer(cmd, *begin);

    range: Vulkan.VkImageSubresourceRange;
    range.aspectMask = .COLOR_BIT;
    range.levelCount = 1;
    range.layerCount = 1;

    to_dst: Vulkan.VkImageMemoryBarrier;
    to_dst.oldLayout = .UNDEFINED;
    to_dst.newLayout = .TRANSFER_DST_OPTIMAL;
    to_dst.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    to_dst.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    to_dst.image = image;
    to_dst.subresourceRange = range;
    to_dst.dstAccessMask = .TRANSFER_WRITE_BIT;
    Vulkan.vkCmdPipelineBarrier(cmd, .TOP_OF_PIPE_BIT, .TRANSFER_BIT, 0, 0, null, 0, null, 1, *to_dst);

    t := cast(float) frame * 0.05;
    clear: Vulkan.VkClearColorValue;
    clear._float32 = float.[ 0.5 + 0.5 * Math.sin(t),
                             0.5 + 0.5 * Math.sin(t + 2.094),
                             0.5 + 0.5 * Math.sin(t + 4.188),
                             1.0 ];
    Vulkan.vkCmdClearColorImage(cmd, image, .TRANSFER_DST_OPTIMAL, *clear, 1, *range);

    to_present: Vulkan.VkImageMemoryBarrier;
    to_present.oldLayout = .TRANSFER_DST_OPTIMAL;
    to_present.newLayout = .PRESENT_SRC_KHR;
    to_present.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    to_present.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    to_present.image = image;
    to_present.subresourceRange = range;
    to_present.srcAccessMask = .TRANSFER_WRITE_BIT;
    Vulkan.vkCmdPipelineBarrier(cmd, .TRANSFER_BIT, .BOTTOM_OF_PIPE_BIT, 0, 0, null, 0, null, 1, *to_present);

    Vulkan.vkEndCommandBuffer(cmd);
}
