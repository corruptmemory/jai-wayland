// hello_vulkan_dmabuf — present a Vulkan-rendered DRM-modifier DMA-BUF in a
// Wayland window. This deliberately avoids VK_KHR_wayland_surface: that WSI path
// wants libwayland-client proxy pointers, while jai-wayland owns only the wire
// protocol objects.

#import,dir "../modules/wayland";
Vulkan :: #import,dir "../modules/Vulkan";

#import "Basic";
#import "File";
#import "POSIX";
#import "String";
#import "System";

DEFAULT_WIDTH  :: 640;
DEFAULT_HEIGHT :: 480;

DRM_FORMAT_ARGB8888 :: #run fourcc(#char "A", #char "R", #char "2", #char "4");
DRM_FORMAT_XRGB8888 :: #run fourcc(#char "X", #char "R", #char "2", #char "4");
DRM_FORMAT_ABGR8888 :: #run fourcc(#char "A", #char "B", #char "2", #char "4");
DRM_FORMAT_XBGR8888 :: #run fourcc(#char "X", #char "B", #char "2", #char "4");

Image_Config :: struct {
    vk_format:           Vulkan.VkFormat;
    wayland_format:      u32;
    usage:               Vulkan.VkImageUsageFlags;
    label:               string;
    drm_format_modifier: u64;
    plane_count:         u32;
}

Vulkan_Context :: struct {
    instance:     Vulkan.VkInstance;
    physical:     Vulkan.VkPhysicalDevice;
    device:       Vulkan.VkDevice;
    queue:        Vulkan.VkQueue;
    queue_family: u32;
    command_pool: Vulkan.VkCommandPool;
}

Vulkan_Triangle :: struct {
    render_pass:     Vulkan.VkRenderPass;
    pipeline_layout: Vulkan.VkPipelineLayout;
    pipeline:        Vulkan.VkPipeline;
}

Vulkan_Buffer :: struct {
    image:       Vulkan.VkImage;
    image_view:  Vulkan.VkImageView;
    framebuffer: Vulkan.VkFramebuffer;
    memory:      Vulkan.VkDeviceMemory;
    buffer:      Wl_Buffer;
    fd:          s32 = -1;
    offset:      u32;
    stride:      u32;
    format:      u32;
    modifier:    u64;
    width:       s32;
    height:      s32;
    in_flight: bool;
    ever_used: bool;
}

main :: () {
    if !init_wayland_session() {
        print("Failed to create Wayland session\n");
        return;
    }
    defer end_wayland_session();

    dmabuf_info, dmabuf_ok := get_dmabuf_info();
    if !dmabuf_ok {
        print("Compositor does not support zwp_linux_dmabuf_v1\n");
        return;
    }

    batch: MessageBuilder;
    surface := Wl_Surface.{ id = allocate_id() };
    xdg_surface := Xdg_Surface.{ id = allocate_id() };
    toplevel := Xdg_Toplevel.{ id = allocate_id() };
    wl_compositor_create_surface(*batch, compositor(), surface.id);
    xdg_wm_base_get_xdg_surface(*batch, wm_base(), xdg_surface.id, *surface);
    xdg_surface_get_toplevel(*batch, *xdg_surface, toplevel.id);
    xdg_toplevel_set_title(*batch, *toplevel, "hello_vulkan_dmabuf");
    wl_surface_commit(*batch, *surface);
    wayland_send(*batch);

    win_width:  s32 = DEFAULT_WIDTH;
    win_height: s32 = DEFAULT_HEIGHT;
    configure_serial: u32 = 0;
    for session() {
        if it.object_id == toplevel.id && it.opcode == XDG_TOPLEVEL_CONFIGURE {
            args: Xdg_Toplevel_Configure_Args;
            unmarshal(*args, it.payload, recv);
            if args.width > 0 && args.height > 0 {
                win_width = args.width;
                win_height = args.height;
            }
        } else if it.object_id == xdg_surface.id && it.opcode == XDG_SURFACE_CONFIGURE {
            configure_serial = read_u32(it.payload);
            break;
        }
    }
    if configure_serial == 0 {
        print("Did not receive xdg_surface.configure\n");
        return;
    }
    print("Configured window: %x%\n", win_width, win_height);

    ctx: Vulkan_Context;
    if !init_vulkan_context(*ctx)  return;
    defer destroy_vulkan_context(*ctx);

    feedback: Dmabuf_Feedback_Info;
    feedback_ok := false;
    if dmabuf_info.feedback_supported {
        feedback, feedback_ok = get_surface_dmabuf_feedback(*dmabuf_info.dmabuf, *surface);
        if feedback_ok  print("Using dmabuf surface feedback for Vulkan format selection\n");
    }

    config, config_ok := choose_image_config(ctx.physical, dmabuf_info, feedback, feedback_ok);
    if !config_ok {
        print("No compositor-compatible Vulkan DMA-BUF image configuration found.\n");
        return;
    }

    print("Using image config: % fourcc=0x% modifier=0x% planes=%\n",
        config.label,
        formatInt(config.wayland_format, base=16),
        formatInt(config.drm_format_modifier, base=16, minimum_digits=16),
        config.plane_count);

    tri: Vulkan_Triangle;
    if !init_vulkan_triangle(*ctx, config, *tri)  return;
    defer destroy_vulkan_triangle(*ctx, *tri);

    slots: [2] Vulkan_Buffer;
    for * slot, i: slots {
        if !init_vulkan_slot(*ctx, *tri, config, *dmabuf_info.dmabuf, *batch, win_width, win_height, slot) {
            print("Failed to initialize Vulkan slot %\n", i);
            return;
        }
    }
    defer for * slots  destroy_vulkan_buffer(*ctx, it);

    rotation_start := monotonic_seconds();
    if !paint_vulkan_slot(ctx, tri, *slots[0], rotation_angle(rotation_start))  return;

    frame_cache: Id_Cache;
    frame_callback_id := cache_alloc(*frame_cache);
    xdg_surface_ack_configure(*batch, *xdg_surface, configure_serial);
    wl_surface_frame(*batch, *surface, frame_callback_id);
    wl_surface_attach(*batch, *surface, *slots[0].buffer, 0, 0);
    wl_surface_damage_buffer(*batch, *surface, 0, 0, slots[0].width, slots[0].height);
    wl_surface_commit(*batch, *surface);
    wayland_send(*batch);
    slots[0].in_flight = true;

    frame_limit := frame_limit_from_env();
    frames_submitted: u32 = 1;
    frame_requested := true;
    dirty := true;
    pending_width:  s32 = 0;
    pending_height: s32 = 0;
    resize_width:   s32 = 0;
    resize_height:  s32 = 0;
    resize_serial:  u32 = 0;
    resize_pending := false;
    retired_slots: [..] Vulkan_Buffer;
    defer for * retired_slots  destroy_vulkan_buffer(*ctx, it);

    if frame_limit > 0 {
        print("hello_vulkan_dmabuf: frame-paced Vulkan triangle smoke (% frames).\n", frame_limit);
    } else {
        print("hello_vulkan_dmabuf: spinning Vulkan triangle. Close the window to exit.\n");
    }

    for session() {
        defer {
            if resize_pending && !frame_requested {
                retire_slots(*ctx, *batch, *retired_slots, slots);

                for * slot, i: slots {
                    if !init_vulkan_slot(*ctx, *tri, config, *dmabuf_info.dmabuf, *batch, resize_width, resize_height, slot) {
                        assert(false, "Failed to initialize resized Vulkan slot %", i);
                    }
                }

                win_width = resize_width;
                win_height = resize_height;

                if !paint_vulkan_slot(ctx, tri, *slots[0], rotation_angle(rotation_start)) {
                    assert(false, "Failed to draw resized Vulkan slot");
                }

                frame_callback_id = cache_alloc(*frame_cache);
                xdg_surface_ack_configure(*batch, *xdg_surface, resize_serial);
                wl_surface_frame(*batch, *surface, frame_callback_id);
                wl_surface_attach(*batch, *surface, *slots[0].buffer, 0, 0);
                wl_surface_damage_buffer(*batch, *surface, 0, 0, slots[0].width, slots[0].height);
                wl_surface_commit(*batch, *surface);
                wayland_send(*batch);

                slots[0].in_flight = true;
                frames_submitted += 1;
                frame_requested = true;
                dirty = false;
                resize_pending = false;
            } else if dirty && !frame_requested && !resize_pending {
                slot_idx := find_free_slot(slots);
                if slot_idx >= 0 {
                    slot := *slots[slot_idx];
                    if !paint_vulkan_slot(ctx, tri, slot, rotation_angle(rotation_start)) {
                        assert(false, "Failed to draw Vulkan slot");
                    }

                    frame_callback_id = cache_alloc(*frame_cache);
                    wl_surface_frame(*batch, *surface, frame_callback_id);
                    wl_surface_attach(*batch, *surface, *slot.buffer, 0, 0);
                    wl_surface_damage_buffer(*batch, *surface, 0, 0, slot.width, slot.height);
                    wl_surface_commit(*batch, *surface);
                    wayland_send(*batch);

                    slot.in_flight = true;
                    frames_submitted += 1;
                    frame_requested = true;
                    dirty = false;
                }
            }
        };

        if it.object_id == frame_callback_id && it.opcode == WL_CALLBACK_DONE {
            cache_free(*frame_cache, frame_callback_id);
            frame_requested = false;
            if frame_limit > 0 && frames_submitted >= frame_limit {
                dirty = false;
                print("Frame limit reached (% frames submitted).\n", frames_submitted);
                break;
            }
            dirty = true;
            continue;
        }

        if it.opcode == WL_BUFFER_RELEASE {
            matched := false;
            obj_id := it.object_id;
            for * slots  if it.buffer.id == obj_id {
                it.in_flight = false;
                matched = true;
                break;
            }
            if matched  continue;
            if release_retired_slot(*ctx, *batch, *retired_slots, obj_id) {
                wayland_send(*batch);
                continue;
            }
        }

        if it.object_id == toplevel.id {
            if it.opcode == XDG_TOPLEVEL_CLOSE {
                print("Close requested.\n");
                break;
            } else if it.opcode == XDG_TOPLEVEL_CONFIGURE {
                args: Xdg_Toplevel_Configure_Args;
                unmarshal(*args, it.payload, recv);
                if args.width > 0 && args.height > 0 {
                    pending_width = args.width;
                    pending_height = args.height;
                }
                continue;
            }
        } else if it.object_id == xdg_surface.id && it.opcode == XDG_SURFACE_CONFIGURE {
            serial := read_u32(it.payload);
            if pending_width > 0 && pending_height > 0 &&
               (pending_width != win_width || pending_height != win_height)
            {
                resize_width = pending_width;
                resize_height = pending_height;
                resize_serial = serial;
                resize_pending = true;
                dirty = false;
            } else {
                xdg_surface_ack_configure(*batch, *xdg_surface, serial);
                wayland_send(*batch);
            }
            continue;
        }
    }
}

fourcc :: (a: u8, b: u8, c: u8, d: u8) -> u32 {
    return (cast(u32) a)
         | ((cast(u32) b) << 8)
         | ((cast(u32) c) << 16)
         | ((cast(u32) d) << 24);
}

queue_dmabuf_buffer :: (batch: *MessageBuilder, dmabuf: *Zwp_Linux_Dmabuf_V1, buffer: *Wl_Buffer,
                        fd: s32, offset: u32, stride: u32, format: u32, modifier: u64, width: s32, height: s32) {
    params := Zwp_Linux_Buffer_Params_V1.{ id = allocate_id() };
    zwp_linux_dmabuf_v1_create_params(batch, dmabuf, params.id);
    zwp_linux_buffer_params_v1_add(batch, *params,
        fd          = cast(Fd) fd,
        plane_idx   = 0,
        offset      = offset,
        stride      = stride,
        modifier_hi = cast(u32)(modifier >> 32),
        modifier_lo = cast(u32)(modifier & 0xFFFFFFFF));

    buffer.* = Wl_Buffer.{ id = allocate_id() };
    zwp_linux_buffer_params_v1_create_immed(batch, *params,
        new_id = buffer.id,
        width  = width,
        height = height,
        format = format,
        flags  = 0);
    zwp_linux_buffer_params_v1_destroy(batch, *params);
}

init_vulkan_slot :: (ctx: *Vulkan_Context, tri: *Vulkan_Triangle, config: Image_Config, dmabuf: *Zwp_Linux_Dmabuf_V1,
                     batch: *MessageBuilder, width: s32, height: s32, slot: *Vulkan_Buffer) -> bool {
    slot.* = .{};
    if !create_vulkan_buffer(ctx, config, width, height, slot)  return false;
    if !create_vulkan_slot_render_targets(ctx, tri, config, slot) {
        destroy_vulkan_buffer_without_wayland(ctx, slot);
        return false;
    }
    queue_dmabuf_buffer(batch, dmabuf, *slot.buffer,
        slot.fd, slot.offset, slot.stride, slot.format, slot.modifier, slot.width, slot.height);
    return true;
}

paint_vulkan_slot :: (ctx: Vulkan_Context, tri: Vulkan_Triangle, slot: *Vulkan_Buffer, angle: float) -> bool {
    first_use := !slot.ever_used;
    if !draw_vulkan_triangle(ctx, tri, slot, angle, first_use)  return false;
    slot.ever_used = true;
    return true;
}

frame_limit_from_env :: () -> u32 {
    value_ptr := getenv("JAI_WAYLAND_VULKAN_FRAMES");
    if value_ptr == null  return 0;

    text := to_string(value_ptr);
    if text.count == 0  return 0;

    value: u32 = 0;
    for text {
        if it < #char "0" || it > #char "9"  break;
        value = value * 10 + cast(u32)(it - #char "0");
    }

    return value;
}

find_free_slot :: (slots: [] Vulkan_Buffer) -> int {
    for slots  if !it.in_flight  return it_index;
    return -1;
}

retire_slots :: (ctx: *Vulkan_Context, batch: *MessageBuilder, retired: *[..] Vulkan_Buffer, slots: [] Vulkan_Buffer) {
    for * slot: slots {
        if slot.buffer.id == 0  continue;

        if slot.in_flight {
            array_add(retired, slot.*);
        } else {
            wl_buffer_destroy(batch, *slot.buffer);
            destroy_vulkan_buffer_without_wayland(ctx, slot);
        }

        slot.* = .{};
    }
}

release_retired_slot :: (ctx: *Vulkan_Context, batch: *MessageBuilder, retired: *[..] Vulkan_Buffer, object_id: u32) -> bool {
    for * slot, i: retired.* {
        if slot.buffer.id == object_id {
            wl_buffer_destroy(batch, *slot.buffer);
            destroy_vulkan_buffer_without_wayland(ctx, slot);
            array_unordered_remove_by_index(retired, i);
            return true;
        }
    }

    return false;
}

init_vulkan_context :: (ctx: *Vulkan_Context) -> bool {
    if !Vulkan.init_vulkan() {
        print("Could not load Vulkan runtime.\n");
        return false;
    }

    api_version := get_loader_api_version();
    version := Vulkan.vk_unmake_version(api_version);
    print("Vulkan loader API %.%.%\n", version.major, version.minor, version.patch);

    app_info: Vulkan.VkApplicationInfo;
    app_info.pApplicationName = "jai-wayland hello_vulkan_dmabuf".data;
    app_info.applicationVersion = Vulkan.VK_MAKE_VERSION(0, 1, 0);
    app_info.pEngineName = "jai-wayland".data;
    app_info.engineVersion = Vulkan.VK_MAKE_VERSION(0, 1, 0);
    app_info.apiVersion = ifx api_version >= Vulkan.VK_API_VERSION_1_1 then Vulkan.VK_API_VERSION_1_1 else Vulkan.VK_API_VERSION_1_0;

    create_info: Vulkan.VkInstanceCreateInfo;
    create_info.pApplicationInfo = *app_info;

    result := Vulkan.vkCreateInstance(*create_info, null, *ctx.instance);
    if result != .SUCCESS {
        print("vkCreateInstance failed: %\n", result);
        if result == .ERROR_INCOMPATIBLE_DRIVER  print_vulkan_loader_overrides();
        return false;
    }

    if !Vulkan.load_vulkan_instance_functions(ctx.instance) {
        print("Could not load required Vulkan instance functions.\n");
        return false;
    }

    ok: bool;
    ctx.physical, ok = choose_physical_device(ctx.instance);
    if !ok  return false;

    props: Vulkan.VkPhysicalDeviceProperties;
    Vulkan.vkGetPhysicalDeviceProperties(ctx.physical, *props);
    device_version := Vulkan.vk_unmake_version(props.apiVersion);
    print("Physical device: % vendor=0x% device=0x% api=%.%.%\n",
        to_string(props.deviceName.data),
        formatInt(props.vendorID, base=16, minimum_digits=4),
        formatInt(props.deviceID, base=16, minimum_digits=4),
        device_version.major, device_version.minor, device_version.patch);

    ctx.queue_family, ok = find_graphics_queue_family(ctx.physical);
    if !ok {
        print("No graphics queue family found.\n");
        return false;
    }

    ctx.device, ok = create_device(ctx.physical, ctx.queue_family);
    if !ok  return false;
    if !Vulkan.load_vulkan_device_functions(ctx.device) ||
       Vulkan.vkGetMemoryFdKHR == null ||
       Vulkan.vkGetImageDrmFormatModifierPropertiesEXT == null ||
       Vulkan.vkCreateImageView == null ||
       Vulkan.vkCreateFramebuffer == null ||
       Vulkan.vkCreateRenderPass == null ||
       Vulkan.vkCreateShaderModule == null ||
       Vulkan.vkCreatePipelineLayout == null ||
       Vulkan.vkCreateGraphicsPipelines == null ||
       Vulkan.vkCmdBeginRenderPass == null ||
       Vulkan.vkCmdEndRenderPass == null ||
       Vulkan.vkCmdBindPipeline == null ||
       Vulkan.vkCmdSetViewport == null ||
       Vulkan.vkCmdSetScissor == null ||
       Vulkan.vkCmdPushConstants == null ||
       Vulkan.vkCmdDraw == null
    {
        print("Could not load required Vulkan device functions.\n");
        return false;
    }

    Vulkan.vkGetDeviceQueue(ctx.device, ctx.queue_family, 0, *ctx.queue);

    pool_info: Vulkan.VkCommandPoolCreateInfo;
    pool_info.flags = .RESET_COMMAND_BUFFER_BIT;
    pool_info.queueFamilyIndex = ctx.queue_family;
    result = Vulkan.vkCreateCommandPool(ctx.device, *pool_info, null, *ctx.command_pool);
    if result != .SUCCESS {
        print("vkCreateCommandPool failed: %\n", result);
        return false;
    }

    return true;
}

destroy_vulkan_context :: (ctx: *Vulkan_Context) {
    if ctx.device != null {
        Vulkan.vkDeviceWaitIdle(ctx.device);
        if ctx.command_pool != null  Vulkan.vkDestroyCommandPool(ctx.device, ctx.command_pool, null);
        Vulkan.vkDestroyDevice(ctx.device, null);
    }
    if ctx.instance != null  Vulkan.vkDestroyInstance(ctx.instance, null);
}

get_loader_api_version :: () -> Vulkan.VkVersion {
    api_version := Vulkan.VK_API_VERSION_1_0;
    if Vulkan.vkEnumerateInstanceVersion != null {
        result := Vulkan.vkEnumerateInstanceVersion(*api_version);
        if result != .SUCCESS  api_version = Vulkan.VK_API_VERSION_1_0;
    }
    return api_version;
}

choose_physical_device :: (instance: Vulkan.VkInstance) -> Vulkan.VkPhysicalDevice, bool {
    count: u32;
    result := Vulkan.vkEnumeratePhysicalDevices(instance, *count, null);
    if result != .SUCCESS || count == 0  return null, false;

    devices: [32] Vulkan.VkPhysicalDevice;
    if count > devices.count  return null, false;

    result = Vulkan.vkEnumeratePhysicalDevices(instance, *count, devices.data);
    if result != .SUCCESS  return null, false;

    for 0..count - 1 {
        if device_supports_extension(devices[it], Vulkan.VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME) &&
           device_supports_extension(devices[it], Vulkan.VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME) &&
           device_supports_extension(devices[it], Vulkan.VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME)
        {
            return devices[it], true;
        }
    }

    print("No Vulkan physical device supports DRM-modifier DMA-BUF export.\n");
    return null, false;
}

find_graphics_queue_family :: (physical: Vulkan.VkPhysicalDevice) -> u32, bool {
    count: u32;
    Vulkan.vkGetPhysicalDeviceQueueFamilyProperties(physical, *count, null);
    if count == 0  return 0, false;

    props: [64] Vulkan.VkQueueFamilyProperties;
    if count > props.count  count = cast(u32) props.count;
    Vulkan.vkGetPhysicalDeviceQueueFamilyProperties(physical, *count, props.data);

    for 0..count - 1 {
        flags := cast(u32) props[it].queueFlags;
        if (flags & cast(u32) Vulkan.VkQueueFlagBits.GRAPHICS_BIT) != 0 && props[it].queueCount > 0 {
            return it, true;
        }
    }

    return 0, false;
}

device_supports_extension :: (physical: Vulkan.VkPhysicalDevice, name: string) -> bool {
    count: u32;
    result := Vulkan.vkEnumerateDeviceExtensionProperties(physical, null, *count, null);
    if result != .SUCCESS || count == 0  return false;

    props: [512] Vulkan.VkExtensionProperties;
    if count > props.count  count = cast(u32) props.count;

    result = Vulkan.vkEnumerateDeviceExtensionProperties(physical, null, *count, props.data);
    if result != .SUCCESS  return false;

    for 0..count - 1 {
        if to_string(props[it].extensionName.data) == name  return true;
    }

    return false;
}

create_device :: (physical: Vulkan.VkPhysicalDevice, queue_family: u32) -> Vulkan.VkDevice, bool {
    priority: float = 1.0;
    queue_info: Vulkan.VkDeviceQueueCreateInfo;
    queue_info.queueFamilyIndex = queue_family;
    queue_info.queueCount = 1;
    queue_info.pQueuePriorities = *priority;

    extension_names: [8] *u8;
    extension_count: u32;
    extension_names[extension_count] = Vulkan.VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME.data; extension_count += 1;
    extension_names[extension_count] = Vulkan.VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME.data; extension_count += 1;
    extension_names[extension_count] = Vulkan.VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME.data; extension_count += 1;

    if device_supports_extension(physical, Vulkan.VK_KHR_EXTERNAL_MEMORY_EXTENSION_NAME) {
        extension_names[extension_count] = Vulkan.VK_KHR_EXTERNAL_MEMORY_EXTENSION_NAME.data; extension_count += 1;
    }
    if device_supports_extension(physical, Vulkan.VK_KHR_DEDICATED_ALLOCATION_EXTENSION_NAME) {
        extension_names[extension_count] = Vulkan.VK_KHR_DEDICATED_ALLOCATION_EXTENSION_NAME.data; extension_count += 1;
    }
    if device_supports_extension(physical, Vulkan.VK_KHR_GET_MEMORY_REQUIREMENTS_2_EXTENSION_NAME) {
        extension_names[extension_count] = Vulkan.VK_KHR_GET_MEMORY_REQUIREMENTS_2_EXTENSION_NAME.data; extension_count += 1;
    }
    if device_supports_extension(physical, Vulkan.VK_KHR_BIND_MEMORY_2_EXTENSION_NAME) {
        extension_names[extension_count] = Vulkan.VK_KHR_BIND_MEMORY_2_EXTENSION_NAME.data; extension_count += 1;
    }
    if device_supports_extension(physical, Vulkan.VK_KHR_IMAGE_FORMAT_LIST_EXTENSION_NAME) {
        extension_names[extension_count] = Vulkan.VK_KHR_IMAGE_FORMAT_LIST_EXTENSION_NAME.data; extension_count += 1;
    }

    create_info: Vulkan.VkDeviceCreateInfo;
    create_info.queueCreateInfoCount = 1;
    create_info.pQueueCreateInfos = *queue_info;
    create_info.enabledExtensionCount = extension_count;
    create_info.ppEnabledExtensionNames = extension_names.data;

    device: Vulkan.VkDevice;
    result := Vulkan.vkCreateDevice(physical, *create_info, null, *device);
    if result != .SUCCESS {
        print("vkCreateDevice failed: %\n", result);
        return null, false;
    }

    return device, true;
}

choose_image_config :: (physical: Vulkan.VkPhysicalDevice, info: Dmabuf_Info, feedback: Dmabuf_Feedback_Info, feedback_ok: bool) -> Image_Config, bool {
    usage := Vulkan.VkImageUsageFlagBits.COLOR_ATTACHMENT_BIT
           | Vulkan.VkImageUsageFlagBits.TRANSFER_SRC_BIT
           | Vulkan.VkImageUsageFlagBits.TRANSFER_DST_BIT;

    if feedback_ok && feedback.complete {
        for tranche: feedback.tranches {
            for fm: tranche.formats {
                cfg, ok := config_for_wayland_format(fm.format, fm.modifier, usage);
                if !ok  continue;
                if config_supported_by_vulkan(physical, *cfg)  return cfg, true;
            }
        }
    }

    for fm: info.supported {
        cfg, ok := config_for_wayland_format(fm.format, fm.modifier, usage);
        if !ok  continue;
        if config_supported_by_vulkan(physical, *cfg)  return cfg, true;
    }

    return .{}, false;
}

config_for_wayland_format :: (format: u32, modifier: u64, usage: Vulkan.VkImageUsageFlags) -> Image_Config, bool {
    if modifier == DRM_FORMAT_MOD_INVALID  return .{}, false;

    if format == DRM_FORMAT_ARGB8888 || format == DRM_FORMAT_XRGB8888 {
        return .{
            vk_format = .B8G8R8A8_UNORM,
            wayland_format = format,
            usage = usage,
            label = ifx format == DRM_FORMAT_ARGB8888 then "B8G8R8A8/AR24" else "B8G8R8A8/XR24",
            drm_format_modifier = modifier,
        }, true;
    }

    if format == DRM_FORMAT_ABGR8888 || format == DRM_FORMAT_XBGR8888 {
        return .{
            vk_format = .R8G8B8A8_UNORM,
            wayland_format = format,
            usage = usage,
            label = ifx format == DRM_FORMAT_ABGR8888 then "R8G8B8A8/AB24" else "R8G8B8A8/XB24",
            drm_format_modifier = modifier,
        }, true;
    }

    return .{}, false;
}

config_supported_by_vulkan :: (physical: Vulkan.VkPhysicalDevice, config: *Image_Config) -> bool {
    modifier_props, mod_ok := get_modifier_properties(physical, config.vk_format, config.drm_format_modifier);
    if !mod_ok || modifier_props.drmFormatModifierPlaneCount != 1  return false;

    external_info: Vulkan.VkPhysicalDeviceExternalImageFormatInfo;
    external_info.handleType = .DMA_BUF_BIT_EXT;

    drm_info: Vulkan.VkPhysicalDeviceImageDrmFormatModifierInfoEXT;
    drm_info.pNext = *external_info;
    drm_info.drmFormatModifier = config.drm_format_modifier;
    drm_info.sharingMode = .EXCLUSIVE;

    format_info: Vulkan.VkPhysicalDeviceImageFormatInfo2;
    format_info.pNext = *drm_info;
    format_info.format = config.vk_format;
    format_info.type = ._2D;
    format_info.tiling = Vulkan.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT;
    format_info.usage = config.usage;

    external_props: Vulkan.VkExternalImageFormatProperties;
    image_props: Vulkan.VkImageFormatProperties2;
    image_props.pNext = *external_props;

    result := Vulkan.vkGetPhysicalDeviceImageFormatProperties2(physical, *format_info, *image_props);
    if result != .SUCCESS  return false;

    feature_bits := cast(u32) external_props.externalMemoryProperties.externalMemoryFeatures;
    if (feature_bits & cast(u32) Vulkan.VkExternalMemoryFeatureFlagBits.EXPORTABLE_BIT) == 0  return false;

    config.plane_count = modifier_props.drmFormatModifierPlaneCount;
    return true;
}

get_modifier_properties :: (physical: Vulkan.VkPhysicalDevice, format: Vulkan.VkFormat, modifier: u64) -> Vulkan.VkDrmFormatModifierPropertiesEXT, bool {
    list: Vulkan.VkDrmFormatModifierPropertiesListEXT;
    props: Vulkan.VkFormatProperties2;
    props.pNext = *list;
    Vulkan.vkGetPhysicalDeviceFormatProperties2(physical, format, *props);
    if list.drmFormatModifierCount == 0  return .{}, false;

    modifiers: [256] Vulkan.VkDrmFormatModifierPropertiesEXT;
    if list.drmFormatModifierCount > modifiers.count {
        list.drmFormatModifierCount = cast(u32) modifiers.count;
    }

    list.pDrmFormatModifierProperties = modifiers.data;
    props.pNext = *list;
    Vulkan.vkGetPhysicalDeviceFormatProperties2(physical, format, *props);

    for 0..list.drmFormatModifierCount - 1 {
        if modifiers[it].drmFormatModifier == modifier  return modifiers[it], true;
    }

    return .{}, false;
}

create_vulkan_buffer :: (ctx: *Vulkan_Context, config: Image_Config, width: s32, height: s32, out: *Vulkan_Buffer) -> bool {
    external_info: Vulkan.VkExternalMemoryImageCreateInfo;
    external_info.handleTypes = .DMA_BUF_BIT_EXT;

    modifier := config.drm_format_modifier;
    modifier_info: Vulkan.VkImageDrmFormatModifierListCreateInfoEXT;
    modifier_info.pNext = *external_info;
    modifier_info.drmFormatModifierCount = 1;
    modifier_info.pDrmFormatModifiers = *modifier;

    image_info: Vulkan.VkImageCreateInfo;
    image_info.pNext = *modifier_info;
    image_info.imageType = ._2D;
    image_info.format = config.vk_format;
    image_info.extent = .{ width = cast(u32) width, height = cast(u32) height, depth = 1 };
    image_info.mipLevels = 1;
    image_info.arrayLayers = 1;
    image_info.samples = ._1_BIT;
    image_info.tiling = Vulkan.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT;
    image_info.usage = config.usage;
    image_info.sharingMode = .EXCLUSIVE;
    image_info.initialLayout = .UNDEFINED;

    result := Vulkan.vkCreateImage(ctx.device, *image_info, null, *out.image);
    if result != .SUCCESS {
        print("vkCreateImage failed: %\n", result);
        return false;
    }

    actual_mod: Vulkan.VkImageDrmFormatModifierPropertiesEXT;
    result = Vulkan.vkGetImageDrmFormatModifierPropertiesEXT(ctx.device, out.image, *actual_mod);
    if result == .SUCCESS {
        out.modifier = actual_mod.drmFormatModifier;
    } else {
        out.modifier = config.drm_format_modifier;
    }

    req: Vulkan.VkMemoryRequirements;
    Vulkan.vkGetImageMemoryRequirements(ctx.device, out.image, *req);

    memory_type, memory_ok := find_memory_type(ctx.physical, req.memoryTypeBits, .DEVICE_LOCAL_BIT);
    if !memory_ok {
        memory_type, memory_ok = find_memory_type(ctx.physical, req.memoryTypeBits, cast(Vulkan.VkMemoryPropertyFlags) 0);
    }
    if !memory_ok {
        print("No compatible memory type for exportable image.\n");
        return false;
    }

    dedicated_info: Vulkan.VkMemoryDedicatedAllocateInfo;
    dedicated_info.image = out.image;

    export_info: Vulkan.VkExportMemoryAllocateInfo;
    export_info.pNext = *dedicated_info;
    export_info.handleTypes = .DMA_BUF_BIT_EXT;

    alloc_info: Vulkan.VkMemoryAllocateInfo;
    alloc_info.pNext = *export_info;
    alloc_info.allocationSize = req.size;
    alloc_info.memoryTypeIndex = memory_type;

    result = Vulkan.vkAllocateMemory(ctx.device, *alloc_info, null, *out.memory);
    if result != .SUCCESS {
        print("vkAllocateMemory failed: %\n", result);
        return false;
    }

    result = Vulkan.vkBindImageMemory(ctx.device, out.image, out.memory, 0);
    if result != .SUCCESS {
        print("vkBindImageMemory failed: %\n", result);
        return false;
    }

    sub: Vulkan.VkImageSubresource;
    sub.aspectMask = Vulkan.VK_IMAGE_ASPECT_MEMORY_PLANE_0_BIT_EXT;
    layout: Vulkan.VkSubresourceLayout;
    Vulkan.vkGetImageSubresourceLayout(ctx.device, out.image, *sub, *layout);

    get_fd: Vulkan.VkMemoryGetFdInfoKHR;
    get_fd.memory = out.memory;
    get_fd.handleType = .DMA_BUF_BIT_EXT;
    result = Vulkan.vkGetMemoryFdKHR(ctx.device, *get_fd, *out.fd);
    if result != .SUCCESS {
        print("vkGetMemoryFdKHR failed: %\n", result);
        return false;
    }

    out.offset = cast(u32) layout.offset;
    out.stride = cast(u32) layout.rowPitch;
    out.format = config.wayland_format;
    out.width = width;
    out.height = height;

    print("Vulkan DMA-BUF fd=% offset=% stride=% image_modifier=0x%\n",
        out.fd, out.offset, out.stride, formatInt(out.modifier, base=16, minimum_digits=16));

    return true;
}

destroy_vulkan_buffer :: (ctx: *Vulkan_Context, buf: *Vulkan_Buffer) {
    if buf.buffer.id != 0 {
        batch: MessageBuilder;
        wl_buffer_destroy(*batch, *buf.buffer);
        wayland_send(*batch);
    }
    destroy_vulkan_buffer_without_wayland(ctx, buf);
}

destroy_vulkan_buffer_without_wayland :: (ctx: *Vulkan_Context, buf: *Vulkan_Buffer) {
    if buf.framebuffer != null  Vulkan.vkDestroyFramebuffer(ctx.device, buf.framebuffer, null);
    if buf.image_view != null   Vulkan.vkDestroyImageView(ctx.device, buf.image_view, null);
    if buf.fd >= 0  close(buf.fd);
    if buf.memory != null  Vulkan.vkFreeMemory(ctx.device, buf.memory, null);
    if buf.image != null  Vulkan.vkDestroyImage(ctx.device, buf.image, null);
    buf.* = .{};
}

find_memory_type :: (physical: Vulkan.VkPhysicalDevice, type_bits: u32, required: Vulkan.VkMemoryPropertyFlags) -> u32, bool {
    props: Vulkan.VkPhysicalDeviceMemoryProperties;
    Vulkan.vkGetPhysicalDeviceMemoryProperties(physical, *props);

    for 0..props.memoryTypeCount - 1 {
        bit := (cast(u32) 1) << it;
        if (type_bits & bit) == 0  continue;

        flags := cast(u32) props.memoryTypes[it].propertyFlags;
        want := cast(u32) required;
        if (flags & want) == want  return it, true;
    }

    return 0, false;
}

ROTATION_RADIANS_PER_SECOND :: 1.2;

monotonic_seconds :: () -> float64 {
    ts: timespec;
    if clock_gettime(.MONOTONIC, *ts) != 0  return 0;
    return cast(float64) ts.tv_sec + cast(float64) ts.tv_nsec / 1000000000.0;
}

rotation_angle :: (start_time: float64) -> float {
    return cast(float) ((monotonic_seconds() - start_time) * ROTATION_RADIANS_PER_SECOND);
}

init_vulkan_triangle :: (ctx: *Vulkan_Context, config: Image_Config, tri: *Vulkan_Triangle) -> bool {
    tri.* = .{};

    ok: bool;
    tri.render_pass, ok = create_triangle_render_pass(ctx, config);
    if !ok  return false;

    tri.pipeline_layout, tri.pipeline, ok = create_triangle_pipeline(ctx, config, tri.render_pass);
    if !ok {
        destroy_vulkan_triangle(ctx, tri);
        return false;
    }

    return true;
}

destroy_vulkan_triangle :: (ctx: *Vulkan_Context, tri: *Vulkan_Triangle) {
    if tri.pipeline != null         Vulkan.vkDestroyPipeline(ctx.device, tri.pipeline, null);
    if tri.pipeline_layout != null  Vulkan.vkDestroyPipelineLayout(ctx.device, tri.pipeline_layout, null);
    if tri.render_pass != null      Vulkan.vkDestroyRenderPass(ctx.device, tri.render_pass, null);
    tri.* = .{};
}

create_triangle_render_pass :: (ctx: *Vulkan_Context, config: Image_Config) -> Vulkan.VkRenderPass, bool {
    attachment := Vulkan.VkAttachmentDescription.{
        format         = config.vk_format,
        samples        = ._1_BIT,
        loadOp         = .CLEAR,
        storeOp        = .STORE,
        stencilLoadOp  = .DONT_CARE,
        stencilStoreOp = .DONT_CARE,
        initialLayout  = .COLOR_ATTACHMENT_OPTIMAL,
        finalLayout    = .COLOR_ATTACHMENT_OPTIMAL,
    };

    color_ref := Vulkan.VkAttachmentReference.{
        attachment = 0,
        layout     = .COLOR_ATTACHMENT_OPTIMAL,
    };

    subpass := Vulkan.VkSubpassDescription.{
        pipelineBindPoint    = .GRAPHICS,
        colorAttachmentCount = 1,
        pColorAttachments    = *color_ref,
    };

    info := Vulkan.VkRenderPassCreateInfo.{
        attachmentCount = 1,
        pAttachments    = *attachment,
        subpassCount    = 1,
        pSubpasses      = *subpass,
    };

    render_pass: Vulkan.VkRenderPass;
    result := Vulkan.vkCreateRenderPass(ctx.device, *info, null, *render_pass);
    if result != .SUCCESS {
        print("vkCreateRenderPass failed: %\n", result);
        return null, false;
    }

    return render_pass, true;
}

create_triangle_pipeline :: (ctx: *Vulkan_Context, config: Image_Config, render_pass: Vulkan.VkRenderPass) -> Vulkan.VkPipelineLayout, Vulkan.VkPipeline, bool {
    vertex_module, vertex_ok := load_shader_module(ctx, "hello_vulkan_triangle.vert.spv");
    if !vertex_ok  return null, null, false;
    defer Vulkan.vkDestroyShaderModule(ctx.device, vertex_module, null);

    fragment_module, fragment_ok := load_shader_module(ctx, "hello_vulkan_triangle.frag.spv");
    if !fragment_ok  return null, null, false;
    defer Vulkan.vkDestroyShaderModule(ctx.device, fragment_module, null);

    shader_stages := Vulkan.VkPipelineShaderStageCreateInfo.[
        .{ stage = .VERTEX_BIT,   module = vertex_module,   pName = "main".data },
        .{ stage = .FRAGMENT_BIT, module = fragment_module, pName = "main".data },
    ];

    push_range := Vulkan.VkPushConstantRange.{
        stageFlags = .VERTEX_BIT,
        offset     = 0,
        size       = cast(u32) size_of(float),
    };

    layout_info := Vulkan.VkPipelineLayoutCreateInfo.{
        pushConstantRangeCount = 1,
        pPushConstantRanges    = *push_range,
    };

    pipeline_layout: Vulkan.VkPipelineLayout;
    result := Vulkan.vkCreatePipelineLayout(ctx.device, *layout_info, null, *pipeline_layout);
    if result != .SUCCESS {
        print("vkCreatePipelineLayout failed: %\n", result);
        return null, null, false;
    }

    vertex_input: Vulkan.VkPipelineVertexInputStateCreateInfo;

    input_assembly := Vulkan.VkPipelineInputAssemblyStateCreateInfo.{
        topology = .TRIANGLE_LIST,
    };

    viewport := Vulkan.VkViewport.{
        width    = 1.0,
        height   = 1.0,
        maxDepth = 1.0,
    };

    scissor := Vulkan.VkRect2D.{
        extent = .{ width = 1, height = 1 },
    };

    viewport_state := Vulkan.VkPipelineViewportStateCreateInfo.{
        viewportCount = 1,
        pViewports    = *viewport,
        scissorCount  = 1,
        pScissors     = *scissor,
    };

    rasterizer := Vulkan.VkPipelineRasterizationStateCreateInfo.{
        polygonMode = .FILL,
        cullMode    = .NONE,
        frontFace   = .COUNTER_CLOCKWISE,
        lineWidth   = 1.0,
    };

    multisample := Vulkan.VkPipelineMultisampleStateCreateInfo.{
        rasterizationSamples = ._1_BIT,
    };

    color_blend_attachment := Vulkan.VkPipelineColorBlendAttachmentState.{
        colorWriteMask      = .R_BIT | .G_BIT | .B_BIT | .A_BIT,
        srcColorBlendFactor = .ONE,
        dstColorBlendFactor = .ZERO,
        colorBlendOp        = .ADD,
        srcAlphaBlendFactor = .ONE,
        dstAlphaBlendFactor = .ZERO,
        alphaBlendOp        = .ADD,
    };

    color_blend := Vulkan.VkPipelineColorBlendStateCreateInfo.{
        attachmentCount = 1,
        pAttachments    = *color_blend_attachment,
    };

    dynamic_states := Vulkan.VkDynamicState.[.VIEWPORT, .SCISSOR];
    dynamic_state := Vulkan.VkPipelineDynamicStateCreateInfo.{
        dynamicStateCount = cast(u32) dynamic_states.count,
        pDynamicStates    = dynamic_states.data,
    };

    pipeline_info := Vulkan.VkGraphicsPipelineCreateInfo.{
        stageCount          = cast(u32) shader_stages.count,
        pStages             = shader_stages.data,
        pVertexInputState   = *vertex_input,
        pInputAssemblyState = *input_assembly,
        pViewportState      = *viewport_state,
        pRasterizationState = *rasterizer,
        pMultisampleState   = *multisample,
        pColorBlendState    = *color_blend,
        pDynamicState       = *dynamic_state,
        layout              = pipeline_layout,
        renderPass          = render_pass,
    };

    pipeline: Vulkan.VkPipeline;
    result = Vulkan.vkCreateGraphicsPipelines(ctx.device, null, 1, *pipeline_info, null, *pipeline);
    if result != .SUCCESS {
        print("vkCreateGraphicsPipelines failed: %\n", result);
        Vulkan.vkDestroyPipelineLayout(ctx.device, pipeline_layout, null);
        return null, null, false;
    }

    return pipeline_layout, pipeline, true;
}

load_shader_module :: (ctx: *Vulkan_Context, filename: string) -> Vulkan.VkShaderModule, bool {
    shader_path := tprint("%shaders/%", path_strip_filename(get_path_of_running_executable()), filename);
    code, ok := read_entire_file(shader_path);
    if !ok {
        print("Could not read shader: %\n", shader_path);
        return null, false;
    }
    defer free(code);

    if (code.count & 3) != 0 {
        print("SPIR-V file size is not 4-byte aligned: %\n", shader_path);
        return null, false;
    }

    info := Vulkan.VkShaderModuleCreateInfo.{
        codeSize = cast(u64) code.count,
        pCode    = cast(*u32) code.data,
    };

    module: Vulkan.VkShaderModule;
    result := Vulkan.vkCreateShaderModule(ctx.device, *info, null, *module);
    if result != .SUCCESS {
        print("vkCreateShaderModule failed for %: %\n", filename, result);
        return null, false;
    }

    return module, true;
}

create_vulkan_slot_render_targets :: (ctx: *Vulkan_Context, tri: *Vulkan_Triangle, config: Image_Config, slot: *Vulkan_Buffer) -> bool {
    view_info := Vulkan.VkImageViewCreateInfo.{
        image            = slot.image,
        viewType         = ._2D,
        format           = config.vk_format,
        subresourceRange = .{
            aspectMask = .COLOR_BIT,
            levelCount = 1,
            layerCount = 1,
        },
    };

    result := Vulkan.vkCreateImageView(ctx.device, *view_info, null, *slot.image_view);
    if result != .SUCCESS {
        print("vkCreateImageView failed: %\n", result);
        return false;
    }

    fb_info := Vulkan.VkFramebufferCreateInfo.{
        renderPass      = tri.render_pass,
        attachmentCount = 1,
        pAttachments    = *slot.image_view,
        width           = cast(u32) slot.width,
        height          = cast(u32) slot.height,
        layers          = 1,
    };

    result = Vulkan.vkCreateFramebuffer(ctx.device, *fb_info, null, *slot.framebuffer);
    if result != .SUCCESS {
        print("vkCreateFramebuffer failed: %\n", result);
        Vulkan.vkDestroyImageView(ctx.device, slot.image_view, null);
        slot.image_view = null;
        return false;
    }

    return true;
}

draw_vulkan_triangle :: (ctx: Vulkan_Context, tri: Vulkan_Triangle, slot: *Vulkan_Buffer, angle: float, first_use: bool) -> bool {
    alloc := Vulkan.VkCommandBufferAllocateInfo.{
        commandPool        = ctx.command_pool,
        level              = .PRIMARY,
        commandBufferCount = 1,
    };

    cmd: Vulkan.VkCommandBuffer;
    result := Vulkan.vkAllocateCommandBuffers(ctx.device, *alloc, *cmd);
    if result != .SUCCESS {
        print("vkAllocateCommandBuffers failed: %\n", result);
        return false;
    }
    defer Vulkan.vkFreeCommandBuffers(ctx.device, ctx.command_pool, 1, *cmd);

    begin := Vulkan.VkCommandBufferBeginInfo.{
        flags = .ONE_TIME_SUBMIT_BIT,
    };
    result = Vulkan.vkBeginCommandBuffer(cmd, *begin);
    if result != .SUCCESS {
        print("vkBeginCommandBuffer failed: %\n", result);
        return false;
    }

    range := Vulkan.VkImageSubresourceRange.{
        aspectMask = .COLOR_BIT,
        levelCount = 1,
        layerCount = 1,
    };

    acquire_src_family := ifx first_use then Vulkan.VK_QUEUE_FAMILY_IGNORED else Vulkan.VK_QUEUE_FAMILY_EXTERNAL;
    acquire_dst_family := ifx first_use then Vulkan.VK_QUEUE_FAMILY_IGNORED else ctx.queue_family;
    to_color := Vulkan.VkImageMemoryBarrier.{
        dstAccessMask       = .COLOR_ATTACHMENT_WRITE_BIT,
        oldLayout           = ifx first_use then Vulkan.VkImageLayout.UNDEFINED else Vulkan.VkImageLayout.GENERAL,
        newLayout           = .COLOR_ATTACHMENT_OPTIMAL,
        srcQueueFamilyIndex = acquire_src_family,
        dstQueueFamilyIndex = acquire_dst_family,
        image               = slot.image,
        subresourceRange    = range,
    };
    Vulkan.vkCmdPipelineBarrier(cmd,
        .TOP_OF_PIPE_BIT, .COLOR_ATTACHMENT_OUTPUT_BIT,
        cast(Vulkan.VkDependencyFlags) 0,
        0, null, 0, null, 1, *to_color);

    clear: Vulkan.VkClearValue;
    clear.color._float32[0] = 0.05;
    clear.color._float32[1] = 0.05;
    clear.color._float32[2] = 0.08;
    clear.color._float32[3] = 1.0;

    render_area := Vulkan.VkRect2D.{
        extent = .{ width = cast(u32) slot.width, height = cast(u32) slot.height },
    };

    pass_begin := Vulkan.VkRenderPassBeginInfo.{
        renderPass      = tri.render_pass,
        framebuffer     = slot.framebuffer,
        renderArea      = render_area,
        clearValueCount = 1,
        pClearValues    = *clear,
    };

    Vulkan.vkCmdBeginRenderPass(cmd, *pass_begin, .INLINE);

    viewport := Vulkan.VkViewport.{
        width    = cast(float) slot.width,
        height   = cast(float) slot.height,
        maxDepth = 1.0,
    };
    Vulkan.vkCmdSetViewport(cmd, 0, 1, *viewport);

    scissor := Vulkan.VkRect2D.{
        extent = .{ width = cast(u32) slot.width, height = cast(u32) slot.height },
    };
    Vulkan.vkCmdSetScissor(cmd, 0, 1, *scissor);

    Vulkan.vkCmdBindPipeline(cmd, .GRAPHICS, tri.pipeline);
    Vulkan.vkCmdPushConstants(cmd, tri.pipeline_layout, .VERTEX_BIT, 0, cast(u32) size_of(float), cast(*void) *angle);
    Vulkan.vkCmdDraw(cmd, 3, 1, 0, 0);
    Vulkan.vkCmdEndRenderPass(cmd);

    to_general := Vulkan.VkImageMemoryBarrier.{
        srcAccessMask       = .COLOR_ATTACHMENT_WRITE_BIT,
        oldLayout           = .COLOR_ATTACHMENT_OPTIMAL,
        newLayout           = .GENERAL,
        srcQueueFamilyIndex = ctx.queue_family,
        dstQueueFamilyIndex = Vulkan.VK_QUEUE_FAMILY_EXTERNAL,
        image               = slot.image,
        subresourceRange    = range,
    };
    Vulkan.vkCmdPipelineBarrier(cmd,
        .COLOR_ATTACHMENT_OUTPUT_BIT, .BOTTOM_OF_PIPE_BIT,
        cast(Vulkan.VkDependencyFlags) 0,
        0, null, 0, null, 1, *to_general);

    result = Vulkan.vkEndCommandBuffer(cmd);
    if result != .SUCCESS {
        print("vkEndCommandBuffer failed: %\n", result);
        return false;
    }

    submit := Vulkan.VkSubmitInfo.{
        commandBufferCount = 1,
        pCommandBuffers    = *cmd,
    };
    result = Vulkan.vkQueueSubmit(ctx.queue, 1, *submit, null);
    if result != .SUCCESS {
        print("vkQueueSubmit failed: %\n", result);
        return false;
    }

    result = Vulkan.vkQueueWaitIdle(ctx.queue);
    if result != .SUCCESS {
        print("vkQueueWaitIdle failed: %\n", result);
        return false;
    }

    return true;
}

print_vulkan_loader_overrides :: () {
    icd_filenames := getenv("VK_ICD_FILENAMES");
    driver_files := getenv("VK_DRIVER_FILES");

    if icd_filenames != null {
        print("  VK_ICD_FILENAMES=%\n", to_string(icd_filenames));
        print("  This overrides Vulkan ICD discovery; stale manifest paths can hide installed drivers.\n");
    }

    if driver_files != null {
        print("  VK_DRIVER_FILES=%\n", to_string(driver_files));
        print("  This overrides Vulkan ICD discovery; stale manifest paths can hide installed drivers.\n");
    }
}
