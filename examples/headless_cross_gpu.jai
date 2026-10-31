// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers

// headless_cross_gpu — the cross-GPU copy path, proven with no compositor involved.
//
// On a hybrid laptop the compositor runs on one GPU (the iGPU) while an app may render
// on another (the dGPU). Handing the compositor the dGPU's own buffers does not work: on
// nomad-artix (2026-10-31) Hyprland 0.57 on the Intel iGPU accepted NVIDIA-rendered
// dma-bufs, block-linear and LINEAR alike, then aborted inside Mesa iris on its next
// frame. NVIDIA's own Wayland WSI presents across GPUs by copying every frame into a
// LINEAR buffer in SYSTEM memory, which the other GPU can read (see the laptop section
// of docs/plans/2026-10-26-game-bootstrap-backport-audit.md).
//
// This test makes that copy and checks it FROM THE OTHER GPU, sending nothing to any
// compositor:
//   1. The IMPORTER is the render node the gpu module selects (JAI_WAYLAND_RENDER_NODE /
//      JAI_WAYLAND_GPU_VENDOR override it; otherwise the first node, the iGPU on the
//      laptop). It stands in for the compositor's GPU.
//   2. The RENDERER is the first Vulkan device whose DRM render node is NOT the
//      importer's (VK_EXT_physical_device_drm). A box with one GPU prints SKIP.
//   3. Vulkan uploads a pattern in which every pixel differs into a device-local OPTIMAL
//      image (the stand-in for a rendered frame), copies that image into a VkBuffer
//      whose memory lives in a heap that is NOT device-local, and exports that memory as
//      a dma-buf. The width is not a multiple of 64, and the rows are padded to a
//      256-byte pitch, so the copy has to honour bufferRowLength and the importer the
//      pitch.
//   4. EGL on the importer's GBM device imports the fd as ABGR8888 with the LINEAR
//      modifier, and the importer's GPU SAMPLES it, as a compositor would, in a draw
//      into a texture of its own (so the GPU reads the pages, not a CPU mapping); that
//      texture is read back.
//   5. Every pixel must match, and so must a CPU read of the exported memory.
//
// A pass means the buffer is the kind NVIDIA's own WSI hands an iGPU compositor: LINEAR,
// in system memory, exported by the rendering GPU's driver, and readable by the other
// GPU. The kernel's view of who has the buffer attached is in
// /sys/kernel/debug/dma_buf/bufinfo, which needs root; the test prints its own
// buffer's entry when that file is readable and says so when it is not.

#import,dir "../modules/EGL";
#import,dir "../modules/gbm";
Gpu    :: #import,dir "../modules/gpu";
GL     :: #import,dir "../modules/GL";
Vulkan :: #import,dir "../modules/Vulkan";

#import "Basic";
#import "File";
#import "POSIX";
#import "String";

WIDTH       :: 250;   // not a multiple of 64 pixels, so the pitch below carries padding
HEIGHT      :: 130;
PITCH_ALIGN :: 256;
PITCH       :: ((WIDTH * 4 + PITCH_ALIGN - 1) / PITCH_ALIGN) * PITCH_ALIGN;  // bytes per row: 1024

DRM_FORMAT_MOD_LINEAR : u64 : 0;

// VK_QUEUE_FAMILY_FOREIGN_EXT. The generated binding spells it `~0-2`, an untyped
// constant; this is the u32 the spec defines.
QUEUE_FAMILY_FOREIGN : u32 : 0xffff_fffd;

// The pattern: R = x and G = y make every pixel unique at this size; B and A vary
// too, so a swapped or dropped channel cannot pass.
pattern :: (x: int, y: int) -> [4] u8 {
    p: [4] u8;
    p[0] = cast,trunc(u8) x;
    p[1] = cast,trunc(u8) y;
    p[2] = cast,trunc(u8) (x * 7 + y * 13);
    p[3] = cast,trunc(u8) (255 - (x + y) % 128);
    return p;
}

Renderer :: struct {
    instance:     Vulkan.VkInstance;
    physical:     Vulkan.VkPhysicalDevice;
    device:       Vulkan.VkDevice;
    queue:        Vulkan.VkQueue;
    queue_family: u32;
    command_pool: Vulkan.VkCommandPool;
    has_foreign:  bool;   // VK_EXT_queue_family_foreign enabled
    integrated:   bool;   // an iGPU: all of its memory is system memory
}

Exported :: struct {
    buffer:        Vulkan.VkBuffer;
    memory:        Vulkan.VkDeviceMemory;
    size:          u64;
    host_visible:  bool;
    fd:            s32 = -1;
}

main :: () {
    // 1. The importer: the GPU that stands in for the compositor's.
    importer, importer_ok := Gpu.select_render_node();
    if !importer_ok  fail("no DRM render node to import on");
    importer_major, importer_minor, dev_ok := render_node_major_minor(importer.name);
    if !dev_ok  fail("cannot read /sys/class/drm/%/dev", importer.name);
    print("Importer: % (%, %:%)\n", importer.path, Gpu.vendor_name(importer.vendor), importer_major, importer_minor);

    // 2. The renderer: a Vulkan device on any OTHER GPU.
    r: Renderer;
    if !init_renderer(*r, importer_major, importer_minor) {
        print("headless_cross_gpu: SKIP: no Vulkan device on a GPU other than %; this box has one GPU, or its other driver lacks DMA-BUF export\n", importer.path);
        return;
    }

    // 3. Render, copy into system memory, export.
    exported := render_and_export(*r);
    defer destroy_exported(*r, *exported);
    print_fdinfo(exported.fd);

    vulkan_side := ifx exported.host_visible then cpu_check(*r, exported) else -1;
    if vulkan_side < 0  print("Exported memory is not host-visible; skipping the CPU check\n");
    else if vulkan_side > 0  fail("the CPU read of the exported memory has % wrong pixel(s): the Vulkan copy itself is broken", vulkan_side);
    else  print("CPU read of the exported memory: all % pixels match\n", WIDTH * HEIGHT);

    // 4. Import on the other GPU and read it back through that GPU.
    import_and_check(importer, exported);

    destroy_renderer(*r);
    print("headless_cross_gpu: PASS: % read a %x% LINEAR system-memory dma-buf that the other GPU rendered, pixel for pixel\n",
        importer.path, WIDTH, HEIGHT);
}

fail :: (format: string, args: ..Any) {
    print("headless_cross_gpu: FAIL: ");
    print(format, ..args);
    print("\n");
    exit(1);
}

// /sys/class/drm/renderDN/dev holds "major:minor", the node's dev_t.
render_node_major_minor :: (name: string) -> s64, s64, bool {
    text, ok := read_entire_file(tprint("/sys/class/drm/%/dev", name), log_errors = false);
    if !ok  return 0, 0, false;
    text = trim(text);
    found, major_text, minor_text := split_from_left(text, #char ":");
    if !found  return 0, 0, false;
    major, major_ok := string_to_int(major_text);
    minor, minor_ok := string_to_int(minor_text);
    return major, minor, major_ok && minor_ok;
}

// ---------------------------------------------------------------------------------
// Renderer side (Vulkan)

init_renderer :: (r: *Renderer, importer_major: s64, importer_minor: s64) -> bool {
    if !Vulkan.init_vulkan() {
        print("Could not load the Vulkan runtime.\n");
        return false;
    }

    app_info: Vulkan.VkApplicationInfo;
    app_info.pApplicationName = "jai-wayland headless_cross_gpu".data;
    app_info.pEngineName      = "jai-wayland".data;
    app_info.apiVersion       = Vulkan.VK_API_VERSION_1_1;   // vkGetPhysicalDeviceProperties2 and external memory are core here

    create_info: Vulkan.VkInstanceCreateInfo;
    create_info.pApplicationInfo = *app_info;
    result := Vulkan.vkCreateInstance(*create_info, null, *r.instance);
    if result != .SUCCESS {
        print("vkCreateInstance failed: %\n", result);
        return false;
    }
    if !Vulkan.load_vulkan_instance_functions(r.instance) || Vulkan.vkGetPhysicalDeviceProperties2 == null ||
       Vulkan.vkGetPhysicalDeviceExternalBufferProperties == null
    {
        print("Could not load the Vulkan 1.1 instance functions this test needs.\n");
        return false;
    }

    count: u32;
    Vulkan.vkEnumeratePhysicalDevices(r.instance, *count, null);
    devices: [32] Vulkan.VkPhysicalDevice;
    if count > devices.count  count = devices.count;
    Vulkan.vkEnumeratePhysicalDevices(r.instance, *count, devices.data);

    for i: 0..cast(s64) count - 1 {
        physical := devices[i];
        props: Vulkan.VkPhysicalDeviceProperties;
        Vulkan.vkGetPhysicalDeviceProperties(physical, *props);
        name := to_string(props.deviceName.data);

        if !device_supports_extension(physical, Vulkan.VK_EXT_PHYSICAL_DEVICE_DRM_EXTENSION_NAME) {
            print("Vulkan device %: % reports no DRM node (no %); skipped\n", i, name, Vulkan.VK_EXT_PHYSICAL_DEVICE_DRM_EXTENSION_NAME);
            continue;
        }
        drm: Vulkan.VkPhysicalDeviceDrmPropertiesEXT;
        props2: Vulkan.VkPhysicalDeviceProperties2;
        props2.pNext = *drm;
        Vulkan.vkGetPhysicalDeviceProperties2(physical, *props2);

        same := drm.hasRender != 0 && drm.renderMajor == importer_major && drm.renderMinor == importer_minor;
        if same {
            print("Vulkan device %: % render %:% is the importer's GPU; skipped\n", i, name, drm.renderMajor, drm.renderMinor);
            continue;
        }
        if !device_supports_extension(physical, Vulkan.VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME) ||
           !device_supports_extension(physical, Vulkan.VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME)
        {
            print("Vulkan device %: % cannot export DMA-BUF memory; skipped\n", i, name);
            continue;
        }

        print("Renderer: Vulkan device %: % (vendor 0x%, render %:%)\n",
            i, name, formatInt(props.vendorID, base=16, minimum_digits=4), drm.renderMajor, drm.renderMinor);
        r.physical = physical;
        r.integrated = props.deviceType == .INTEGRATED_GPU;
        break;
    }
    if r.physical == null  return false;

    queue_ok: bool;
    r.queue_family, queue_ok = find_queue_family(r.physical);
    if !queue_ok {
        print("The renderer has no graphics or transfer queue.\n");
        return false;
    }

    r.has_foreign = device_supports_extension(r.physical, Vulkan.VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME);
    names: [4] *u8;
    name_count: u32;
    names[name_count] = Vulkan.VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME.data;     name_count += 1;
    names[name_count] = Vulkan.VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME.data; name_count += 1;
    if r.has_foreign {
        names[name_count] = Vulkan.VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME.data; name_count += 1;
    }

    priority: float = 1.0;
    queue_info: Vulkan.VkDeviceQueueCreateInfo;
    queue_info.queueFamilyIndex = r.queue_family;
    queue_info.queueCount       = 1;
    queue_info.pQueuePriorities = *priority;

    device_info: Vulkan.VkDeviceCreateInfo;
    device_info.queueCreateInfoCount    = 1;
    device_info.pQueueCreateInfos       = *queue_info;
    device_info.enabledExtensionCount   = name_count;
    device_info.ppEnabledExtensionNames = names.data;
    result = Vulkan.vkCreateDevice(r.physical, *device_info, null, *r.device);
    if result != .SUCCESS {
        print("vkCreateDevice failed: %\n", result);
        return false;
    }
    if !Vulkan.load_vulkan_device_functions(r.device) || Vulkan.vkGetMemoryFdKHR == null {
        print("Could not load the Vulkan device functions this test needs.\n");
        return false;
    }
    Vulkan.vkGetDeviceQueue(r.device, r.queue_family, 0, *r.queue);

    pool_info: Vulkan.VkCommandPoolCreateInfo;
    pool_info.queueFamilyIndex = r.queue_family;
    result = Vulkan.vkCreateCommandPool(r.device, *pool_info, null, *r.command_pool);
    if result != .SUCCESS {
        print("vkCreateCommandPool failed: %\n", result);
        return false;
    }
    return true;
}

destroy_renderer :: (r: *Renderer) {
    if r.device {
        Vulkan.vkDeviceWaitIdle(r.device);
        if r.command_pool  Vulkan.vkDestroyCommandPool(r.device, r.command_pool, null);
        Vulkan.vkDestroyDevice(r.device, null);
        r.device = null;
    }
    if r.instance  Vulkan.vkDestroyInstance(r.instance, null);
    r.instance = null;
}

// Upload the pattern into a device-local OPTIMAL image, copy the image into a buffer in
// a non-device-local heap, and export that buffer's memory as a dma-buf. The image and
// the staging buffer are gone when this returns; only the exported buffer survives.
render_and_export :: (r: *Renderer) -> Exported {
    out: Exported;
    handle_type := Vulkan.VkExternalMemoryHandleTypeFlagBits.DMA_BUF_BIT_EXT;

    // Can this driver export a transfer-destination buffer as a dma-buf at all?
    buffer_query: Vulkan.VkPhysicalDeviceExternalBufferInfo;
    buffer_query.usage      = .TRANSFER_DST_BIT;
    buffer_query.handleType = handle_type;
    buffer_props: Vulkan.VkExternalBufferProperties;
    Vulkan.vkGetPhysicalDeviceExternalBufferProperties(r.physical, *buffer_query, *buffer_props);
    features := buffer_props.externalMemoryProperties.externalMemoryFeatures;
    print("DMA_BUF buffer export: features 0x% (exportable %, dedicated-only %)\n",
        formatInt(cast(u32) features, base=16),
        (features & .EXPORTABLE_BIT) != 0, (features & .DEDICATED_ONLY_BIT) != 0);
    if !(features & .EXPORTABLE_BIT)  fail("the renderer cannot export a transfer-destination VkBuffer as a dma-buf");

    // The exported buffer: one row every PITCH bytes.
    out.size = cast(u64) (PITCH * HEIGHT);
    external_buffer_info: Vulkan.VkExternalMemoryBufferCreateInfo;
    external_buffer_info.handleTypes = handle_type;
    buffer_info: Vulkan.VkBufferCreateInfo;
    buffer_info.pNext       = *external_buffer_info;
    buffer_info.size        = out.size;
    buffer_info.usage       = .TRANSFER_DST_BIT;
    buffer_info.sharingMode = .EXCLUSIVE;
    check(Vulkan.vkCreateBuffer(r.device, *buffer_info, null, *out.buffer), "vkCreateBuffer(exported)");

    req: Vulkan.VkMemoryRequirements;
    Vulkan.vkGetBufferMemoryRequirements(r.device, out.buffer, *req);
    type_index, host_visible, type_ok := find_system_memory_type(r.physical, req.memoryTypeBits, r.integrated);
    if !type_ok  fail("no system-memory type fits the exported buffer (type bits 0x%)", formatInt(req.memoryTypeBits, base=16));
    out.host_visible = host_visible;

    dedicated: Vulkan.VkMemoryDedicatedAllocateInfo;
    dedicated.buffer = out.buffer;
    export_info: Vulkan.VkExportMemoryAllocateInfo;
    export_info.pNext       = *dedicated;
    export_info.handleTypes = handle_type;
    alloc_info: Vulkan.VkMemoryAllocateInfo;
    alloc_info.pNext           = *export_info;
    alloc_info.allocationSize  = req.size;
    alloc_info.memoryTypeIndex = type_index;
    check(Vulkan.vkAllocateMemory(r.device, *alloc_info, null, *out.memory), "vkAllocateMemory(exported, system memory)");
    check(Vulkan.vkBindBufferMemory(r.device, out.buffer, out.memory, 0), "vkBindBufferMemory(exported)");

    get_fd: Vulkan.VkMemoryGetFdInfoKHR;
    get_fd.memory     = out.memory;
    get_fd.handleType = handle_type;
    check(Vulkan.vkGetMemoryFdKHR(r.device, *get_fd, *out.fd), "vkGetMemoryFdKHR(DMA_BUF)");
    print("Exported: % bytes (pitch %, % rows) as dma-buf fd %\n", req.size, PITCH, HEIGHT, out.fd);

    // The source: a device-local OPTIMAL image, as a rendered frame would be.
    image_info: Vulkan.VkImageCreateInfo;
    image_info.imageType   = ._2D;
    image_info.format      = .R8G8B8A8_UNORM;
    image_info.extent      = .{ width = WIDTH, height = HEIGHT, depth = 1 };
    image_info.mipLevels   = 1;
    image_info.arrayLayers = 1;
    image_info.samples     = ._1_BIT;
    image_info.tiling      = .OPTIMAL;
    image_info.usage       = .TRANSFER_DST_BIT | .TRANSFER_SRC_BIT | .COLOR_ATTACHMENT_BIT;
    image_info.sharingMode = .EXCLUSIVE;
    image_info.initialLayout = .UNDEFINED;
    image: Vulkan.VkImage;
    check(Vulkan.vkCreateImage(r.device, *image_info, null, *image), "vkCreateImage(source)");
    defer Vulkan.vkDestroyImage(r.device, image, null);

    Vulkan.vkGetImageMemoryRequirements(r.device, image, *req);
    image_type, image_type_ok := find_memory_type(r.physical, req.memoryTypeBits, .DEVICE_LOCAL_BIT);
    if !image_type_ok  fail("no device-local memory type for the source image");
    image_alloc: Vulkan.VkMemoryAllocateInfo;
    image_alloc.allocationSize  = req.size;
    image_alloc.memoryTypeIndex = image_type;
    image_memory: Vulkan.VkDeviceMemory;
    check(Vulkan.vkAllocateMemory(r.device, *image_alloc, null, *image_memory), "vkAllocateMemory(source image)");
    defer Vulkan.vkFreeMemory(r.device, image_memory, null);
    check(Vulkan.vkBindImageMemory(r.device, image, image_memory, 0), "vkBindImageMemory(source)");

    // The staging buffer the pattern is uploaded from, tightly packed.
    staging_size := cast(u64) (WIDTH * HEIGHT * 4);
    staging_info: Vulkan.VkBufferCreateInfo;
    staging_info.size        = staging_size;
    staging_info.usage       = .TRANSFER_SRC_BIT;
    staging_info.sharingMode = .EXCLUSIVE;
    staging: Vulkan.VkBuffer;
    check(Vulkan.vkCreateBuffer(r.device, *staging_info, null, *staging), "vkCreateBuffer(staging)");
    defer Vulkan.vkDestroyBuffer(r.device, staging, null);
    Vulkan.vkGetBufferMemoryRequirements(r.device, staging, *req);
    staging_type, staging_type_ok := find_memory_type(r.physical, req.memoryTypeBits, .HOST_VISIBLE_BIT | .HOST_COHERENT_BIT);
    if !staging_type_ok  fail("no host-visible coherent memory type for the staging buffer");
    staging_alloc: Vulkan.VkMemoryAllocateInfo;
    staging_alloc.allocationSize  = req.size;
    staging_alloc.memoryTypeIndex = staging_type;
    staging_memory: Vulkan.VkDeviceMemory;
    check(Vulkan.vkAllocateMemory(r.device, *staging_alloc, null, *staging_memory), "vkAllocateMemory(staging)");
    defer Vulkan.vkFreeMemory(r.device, staging_memory, null);
    check(Vulkan.vkBindBufferMemory(r.device, staging, staging_memory, 0), "vkBindBufferMemory(staging)");

    mapped: *void;
    check(Vulkan.vkMapMemory(r.device, staging_memory, 0, staging_size, 0, *mapped), "vkMapMemory(staging)");
    pixels := cast(*u8) mapped;
    for y: 0..HEIGHT - 1  for x: 0..WIDTH - 1 {
        p := pattern(x, y);
        memcpy(pixels + (y * WIDTH + x) * 4, p.data, 4);
    }
    Vulkan.vkUnmapMemory(r.device, staging_memory);

    cmd := begin_commands(r);
    range := Vulkan.VkImageSubresourceRange.{ aspectMask = .COLOR_BIT, levelCount = 1, layerCount = 1 };
    layers := Vulkan.VkImageSubresourceLayers.{ aspectMask = .COLOR_BIT, layerCount = 1 };

    to_dst := Vulkan.VkImageMemoryBarrier.{
        dstAccessMask       = .TRANSFER_WRITE_BIT,
        oldLayout           = .UNDEFINED,
        newLayout           = .TRANSFER_DST_OPTIMAL,
        srcQueueFamilyIndex = Vulkan.VK_QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = Vulkan.VK_QUEUE_FAMILY_IGNORED,
        image               = image,
        subresourceRange    = range,
    };
    Vulkan.vkCmdPipelineBarrier(cmd, .TOP_OF_PIPE_BIT, .TRANSFER_BIT, 0, 0, null, 0, null, 1, *to_dst);

    upload := Vulkan.VkBufferImageCopy.{ imageSubresource = layers, imageExtent = .{ width = WIDTH, height = HEIGHT, depth = 1 } };
    Vulkan.vkCmdCopyBufferToImage(cmd, staging, image, .TRANSFER_DST_OPTIMAL, 1, *upload);

    to_src := Vulkan.VkImageMemoryBarrier.{
        srcAccessMask       = .TRANSFER_WRITE_BIT,
        dstAccessMask       = .TRANSFER_READ_BIT,
        oldLayout           = .TRANSFER_DST_OPTIMAL,
        newLayout           = .TRANSFER_SRC_OPTIMAL,
        srcQueueFamilyIndex = Vulkan.VK_QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = Vulkan.VK_QUEUE_FAMILY_IGNORED,
        image               = image,
        subresourceRange    = range,
    };
    Vulkan.vkCmdPipelineBarrier(cmd, .TRANSFER_BIT, .TRANSFER_BIT, 0, 0, null, 0, null, 1, *to_src);

    // THE copy: optimal image -> LINEAR rows in system memory, PITCH bytes apart.
    readout := Vulkan.VkBufferImageCopy.{
        bufferRowLength   = PITCH / 4,   // in texels
        bufferImageHeight = HEIGHT,
        imageSubresource  = layers,
        imageExtent       = .{ width = WIDTH, height = HEIGHT, depth = 1 },
    };
    Vulkan.vkCmdCopyImageToBuffer(cmd, image, .TRANSFER_SRC_OPTIMAL, out.buffer, 1, *readout);

    // Make the copy visible to this process's CPU check, then release the buffer to the
    // other GPU's driver, which acquires it implicitly.
    to_host := Vulkan.VkMemoryBarrier.{ srcAccessMask = .TRANSFER_WRITE_BIT, dstAccessMask = .HOST_READ_BIT };
    Vulkan.vkCmdPipelineBarrier(cmd, .TRANSFER_BIT, .HOST_BIT, 0, 1, *to_host, 0, null, 0, null);
    release := Vulkan.VkBufferMemoryBarrier.{
        srcAccessMask       = .TRANSFER_WRITE_BIT,
        srcQueueFamilyIndex = r.queue_family,
        dstQueueFamilyIndex = ifx r.has_foreign then QUEUE_FAMILY_FOREIGN else Vulkan.VK_QUEUE_FAMILY_EXTERNAL,
        buffer              = out.buffer,
        size                = Vulkan.VK_WHOLE_SIZE,
    };
    Vulkan.vkCmdPipelineBarrier(cmd, .TRANSFER_BIT, .BOTTOM_OF_PIPE_BIT, 0, 0, null, 1, *release, 0, null);

    submit_and_wait(r, cmd);
    return out;
}

destroy_exported :: (r: *Renderer, e: *Exported) {
    if e.fd >= 0  close(e.fd);
    if !r.device  return;
    if e.buffer  Vulkan.vkDestroyBuffer(r.device, e.buffer, null);
    if e.memory  Vulkan.vkFreeMemory(r.device, e.memory, null);
    e.* = .{};
}

// Wrong pixels in the exported memory as this process's CPU sees it.
cpu_check :: (r: *Renderer, e: Exported) -> int {
    mapped: *void;
    check(Vulkan.vkMapMemory(r.device, e.memory, 0, e.size, 0, *mapped), "vkMapMemory(exported)");
    defer Vulkan.vkUnmapMemory(r.device, e.memory);
    return count_mismatches(cast(*u8) mapped, PITCH, "CPU read");
}

// A memory type the buffer may use that lives in system memory. On a discrete GPU that
// is a type whose HEAP is not device-local; the type's own DEVICE_LOCAL bit is not
// enough on its own, because a resizable-BAR type is host-visible and device-local at
// once (NVIDIA's type 5 on the RTX 3050 Ti), and its pages are VRAM. An integrated GPU
// has no VRAM: it flags every heap device-local, and all of them are system memory, so
// for it any type qualifies. Host-visible coherent types come first, so the CPU check
// can run.
find_system_memory_type :: (physical: Vulkan.VkPhysicalDevice, type_bits: u32, integrated: bool) -> index: u32, host_visible: bool, ok: bool {
    props: Vulkan.VkPhysicalDeviceMemoryProperties;
    Vulkan.vkGetPhysicalDeviceMemoryProperties(physical, *props);

    fallback := -1;
    for i: 0..cast(s64) props.memoryTypeCount - 1 {
        if !(type_bits & (cast(u32) 1 << i))  continue;
        type := props.memoryTypes[i];
        heap := props.memoryHeaps[type.heapIndex];
        if !integrated && ((heap.flags & .DEVICE_LOCAL_BIT) || (type.propertyFlags & .DEVICE_LOCAL_BIT))  continue;
        if (type.propertyFlags & .HOST_VISIBLE_BIT) && (type.propertyFlags & .HOST_COHERENT_BIT) {
            print("Exported memory: type % (flags 0x%) in heap % (flags 0x%, % MiB): system memory%\n",
                i, formatInt(cast(u32) type.propertyFlags, base=16), type.heapIndex,
                formatInt(cast(u32) heap.flags, base=16), heap.size / (1024 * 1024),
                ifx integrated then " (an integrated GPU's)" else "");
            return cast(u32) i, true, true;
        }
        if fallback < 0  fallback = i;
    }
    if fallback >= 0 {
        print("Exported memory: type % in system memory; not host-visible\n", fallback);
        return cast(u32) fallback, false, true;
    }
    return 0, false, false;
}

find_memory_type :: (physical: Vulkan.VkPhysicalDevice, type_bits: u32, required: Vulkan.VkMemoryPropertyFlags) -> u32, bool {
    props: Vulkan.VkPhysicalDeviceMemoryProperties;
    Vulkan.vkGetPhysicalDeviceMemoryProperties(physical, *props);
    for i: 0..cast(s64) props.memoryTypeCount - 1 {
        if !(type_bits & (cast(u32) 1 << i))  continue;
        if (props.memoryTypes[i].propertyFlags & required) == required  return cast(u32) i, true;
    }
    return 0, false;
}

find_queue_family :: (physical: Vulkan.VkPhysicalDevice) -> u32, bool {
    count: u32;
    Vulkan.vkGetPhysicalDeviceQueueFamilyProperties(physical, *count, null);
    props: [64] Vulkan.VkQueueFamilyProperties;
    if count > props.count  count = props.count;
    Vulkan.vkGetPhysicalDeviceQueueFamilyProperties(physical, *count, props.data);
    for i: 0..cast(s64) count - 1 {
        // A graphics queue: the present path renders and copies on the same queue.
        if (props[i].queueFlags & .GRAPHICS_BIT) && props[i].queueCount > 0  return cast(u32) i, true;
    }
    return 0, false;
}

device_supports_extension :: (physical: Vulkan.VkPhysicalDevice, name: string) -> bool {
    count: u32;
    if Vulkan.vkEnumerateDeviceExtensionProperties(physical, null, *count, null) != .SUCCESS  return false;
    props: [512] Vulkan.VkExtensionProperties;
    if count > props.count  count = props.count;
    if Vulkan.vkEnumerateDeviceExtensionProperties(physical, null, *count, props.data) != .SUCCESS  return false;
    for 0..cast(s64) count - 1  if to_string(props[it].extensionName.data) == name  return true;
    return false;
}

begin_commands :: (r: *Renderer) -> Vulkan.VkCommandBuffer {
    alloc := Vulkan.VkCommandBufferAllocateInfo.{ commandPool = r.command_pool, level = .PRIMARY, commandBufferCount = 1 };
    cmd: Vulkan.VkCommandBuffer;
    check(Vulkan.vkAllocateCommandBuffers(r.device, *alloc, *cmd), "vkAllocateCommandBuffers");
    begin := Vulkan.VkCommandBufferBeginInfo.{ flags = .ONE_TIME_SUBMIT_BIT };
    check(Vulkan.vkBeginCommandBuffer(cmd, *begin), "vkBeginCommandBuffer");
    return cmd;
}

submit_and_wait :: (r: *Renderer, cmd: Vulkan.VkCommandBuffer) {
    check(Vulkan.vkEndCommandBuffer(cmd), "vkEndCommandBuffer");
    fence_info: Vulkan.VkFenceCreateInfo;
    fence: Vulkan.VkFence;
    check(Vulkan.vkCreateFence(r.device, *fence_info, null, *fence), "vkCreateFence");
    defer Vulkan.vkDestroyFence(r.device, fence, null);
    submit := Vulkan.VkSubmitInfo.{ commandBufferCount = 1, pCommandBuffers = *cmd };
    check(Vulkan.vkQueueSubmit(r.queue, 1, *submit, fence), "vkQueueSubmit");
    check(Vulkan.vkWaitForFences(r.device, 1, *fence, Vulkan.VK_TRUE, 5_000_000_000), "vkWaitForFences (5 s)");
    Vulkan.vkFreeCommandBuffers(r.device, r.command_pool, 1, *cmd);
}

check :: (result: Vulkan.VkResult, what: string) {
    if result != .SUCCESS  fail("% failed: %", what, result);
}

// ---------------------------------------------------------------------------------
// Importer side (EGL + GL on the other GPU's GBM device)

import_and_check :: (node: Gpu.Render_Node_Info, e: Exported) {
    drm_fd := open(temp_c_string(node.path), O_RDWR | O_CLOEXEC);
    if drm_fd < 0  fail("cannot open % (errno %)", node.path, errno());
    defer close(drm_fd);

    if !init_egl()  fail("EGL init failed (libEGL.so.1 not found?)");
    if !init_gbm()  fail("GBM init failed (libgbm.so.1 not found?)");
    gbm := gbm_create_device(drm_fd);
    if gbm == null  fail("gbm_create_device(%) failed", node.path);
    defer gbm_device_destroy(gbm);

    dpy := eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm, null);
    if dpy == EGL_NO_DISPLAY  fail("eglGetPlatformDisplay(GBM) failed");
    major, minor: EGLint;
    if eglInitialize(dpy, *major, *minor) != EGL_TRUE  fail("eglInitialize failed (0x%)", formatInt(eglGetError(), base=16));
    defer eglTerminate(dpy);
    if !init_egl_extensions(dpy)  fail("EGL extensions missing on %", node.path);
    if eglBindAPI(EGL_OPENGL_API) != EGL_TRUE  fail("eglBindAPI(OPENGL) failed");

    config_attrs := EGLint.[ EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE ];
    config: EGLConfig;
    num_configs: EGLint;
    if eglChooseConfig(dpy, config_attrs.data, *config, 1, *num_configs) != EGL_TRUE || num_configs == 0  fail("eglChooseConfig failed");
    ctx_attrs := EGLint.[ EGL_CONTEXT_MAJOR_VERSION_KHR, 3, EGL_CONTEXT_MINOR_VERSION_KHR, 3,
        EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT_KHR, EGL_NONE ];
    ctx := eglCreateContext(dpy, config, EGL_NO_CONTEXT, ctx_attrs.data);
    if ctx == EGL_NO_CONTEXT  fail("eglCreateContext failed (0x%)", formatInt(eglGetError(), base=16));
    defer eglDestroyContext(dpy, ctx);
    if eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx) != EGL_TRUE  fail("eglMakeCurrent failed");
    defer eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);

    if !GL.gl_load(eglGetProcAddress)  fail("GL entry points did not load");
    if !GL.gl_load_egl_image_extensions(eglGetProcAddress)  fail("GL_OES_EGL_image missing");
    print("Importer GL: %\n", to_string(GL.glGetString(GL.GL_RENDERER)));

    // The import: the exported fd, as LINEAR ABGR8888 (R, G, B, A bytes in memory,
    // which is what VK_FORMAT_R8G8B8A8_UNORM writes).
    attrs := EGLint.[
        EGL_WIDTH, WIDTH,
        EGL_HEIGHT, HEIGHT,
        EGL_LINUX_DRM_FOURCC_EXT, cast(EGLint) GBM_FORMAT_ABGR8888,
        EGL_DMA_BUF_PLANE0_FD_EXT, e.fd,
        EGL_DMA_BUF_PLANE0_OFFSET_EXT, 0,
        EGL_DMA_BUF_PLANE0_PITCH_EXT, PITCH,
        EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, cast,trunc(EGLint) DRM_FORMAT_MOD_LINEAR,
        EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, cast,trunc(EGLint) (DRM_FORMAT_MOD_LINEAR >> 32),
        EGL_NONE,
    ];
    image := eglCreateImageKHR(dpy, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, null, attrs.data);
    if image == null  fail("eglCreateImageKHR(EGL_LINUX_DMA_BUF_EXT, ABGR8888, LINEAR, pitch %) failed (0x%)", PITCH, formatInt(eglGetError(), base=16));
    defer eglDestroyImageKHR(dpy, image);
    print("Imported fd % on % as ABGR8888 LINEAR, pitch %\n", e.fd, node.path, PITCH);

    imported_tex, own_tex: u32;
    GL.glGenTextures(1, *imported_tex);
    defer GL.glDeleteTextures(1, *imported_tex);
    GL.glBindTexture(GL.GL_TEXTURE_2D, imported_tex);
    GL.glEGLImageTargetTexture2DOES(GL.GL_TEXTURE_2D, image);
    bind_error := GL.glGetError();
    if bind_error != 0 {
        class := linear_import_class(dpy);
        if class == "external-only" {
            // NVIDIA's EGL lists LINEAR this way: a compositor on NVIDIA samples such a
            // buffer as GL_TEXTURE_EXTERNAL_OES, which this desktop-GL sampler has no
            // way to declare. The export and the import itself succeeded; the read this
            // test exists to make is the one it cannot make here.
            print("headless_cross_gpu: SKIP: % lists LINEAR ABGR8888 as external-only (GL_TEXTURE_EXTERNAL_OES), so this test's GL_TEXTURE_2D sampler cannot read it (GL error 0x%); the export and the import succeeded\n",
                node.path, formatInt(bind_error, base=16));
            exit(0);
        }
        fail("binding the import to a GL_TEXTURE_2D raised GL error 0x%; the importer lists LINEAR ABGR8888 as %", formatInt(bind_error, base=16), class);
    }
    // One level and no mipmaps: with the default mipmapping MIN_FILTER the texture is
    // incomplete, and texelFetch on an incomplete texture returns zeros.
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MIN_FILTER, GL.GL_NEAREST);
    GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MAG_FILTER, GL.GL_NEAREST);

    GL.glGenTextures(1, *own_tex);
    defer GL.glDeleteTextures(1, *own_tex);
    GL.glBindTexture(GL.GL_TEXTURE_2D, own_tex);
    GL.glTexImage2D(GL.GL_TEXTURE_2D, 0, GL.GL_RGBA8, WIDTH, HEIGHT, 0, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, null);

    fbo: u32;
    GL.glGenFramebuffers(1, *fbo);
    defer GL.glDeleteFramebuffers(1, *fbo);
    GL.glBindFramebuffer(GL.GL_FRAMEBUFFER, fbo);
    GL.glFramebufferTexture2D(GL.GL_FRAMEBUFFER, GL.GL_COLOR_ATTACHMENT0, GL.GL_TEXTURE_2D, own_tex, 0);
    status := GL.glCheckFramebufferStatus(GL.GL_FRAMEBUFFER);
    if status != GL.GL_FRAMEBUFFER_COMPLETE  fail("the importer's own framebuffer is incomplete (0x%)", formatInt(status, base=16));

    // The importer's GPU reads the dma-buf's pages here, the way a compositor does: by
    // SAMPLING it in a draw. Attaching the import to a framebuffer (a blit's read side)
    // would also demand that the importer can render into LINEAR, which NVIDIA cannot
    // (GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT), and a compositor never needs to.
    program := build_sampling_program();
    defer GL.glDeleteProgram(program);
    vao: u32;
    GL.glGenVertexArrays(1, *vao);
    defer GL.glDeleteVertexArrays(1, *vao);

    GL.glViewport(0, 0, WIDTH, HEIGHT);
    GL.glUseProgram(program);
    GL.glActiveTexture(GL.GL_TEXTURE0);
    GL.glBindTexture(GL.GL_TEXTURE_2D, imported_tex);
    GL.glUniform1i(GL.glGetUniformLocation(program, "imported".data), 0);
    GL.glBindVertexArray(vao);
    GL.glDrawArrays(GL.GL_TRIANGLES, 0, 3);
    GL.glFinish();
    gl_error := GL.glGetError();
    if gl_error != 0  fail("sampling the imported texture raised GL error 0x%", formatInt(gl_error, base=16));

    report_attachments(e.fd);

    // Read back the importer's OWN texture: what its GPU copied out of the dma-buf.
    // Rows are WIDTH * 4 = 1000 bytes, a multiple of the default pack alignment (4).
    readback := NewArray(WIDTH * HEIGHT * 4, u8);
    defer array_free(readback);
    GL.glReadPixels(0, 0, WIDTH, HEIGHT, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, readback.data);
    wrong := count_mismatches(readback.data, WIDTH * 4, "importer GPU");
    if wrong > 0  fail("% of % pixels read back through % are wrong", wrong, WIDTH * HEIGHT, node.path);
    print("Importer GPU read: all % pixels match\n", WIDTH * HEIGHT);
}

// How the importer's EGL lists LINEAR for ABGR8888: absent, "external-only" (sampleable
// only as GL_TEXTURE_EXTERNAL_OES, never as a GL_TEXTURE_2D), or a plain 2D texture.
linear_import_class :: (dpy: EGLDisplay) -> string {
    Query :: #type (dpy: EGLDisplay, format: EGLint, max: EGLint, modifiers: *u64,
                    external_only: *EGLBoolean, count: *EGLint) -> EGLBoolean #c_call;
    query: Query = xx eglGetProcAddress("eglQueryDmaBufModifiersEXT");
    if query == null  return "unknown (no eglQueryDmaBufModifiersEXT)";
    modifiers: [256] u64;
    external: [256] EGLBoolean;
    count: EGLint;
    if query(dpy, cast(EGLint) GBM_FORMAT_ABGR8888, modifiers.count, modifiers.data, external.data, *count) != EGL_TRUE  return "unknown (query failed)";
    for 0..count - 1  if modifiers[it] == DRM_FORMAT_MOD_LINEAR {
        return ifx external[it] then "external-only" else "a plain 2D texture";
    }
    return tprint("absent (% other modifiers listed)", count);
}

// A full-viewport triangle whose fragments copy the imported texture texel for texel:
// texelFetch at the fragment's own integer coordinates, so no filtering or scaling can
// blur a wrong pixel into a right one.
SAMPLING_VERTEX :: #string GLSL
#version 330 core
void main() {
    vec2 p = vec2(float((gl_VertexID & 1) << 2) - 1.0, float((gl_VertexID & 2) << 1) - 1.0);
    gl_Position = vec4(p, 0.0, 1.0);
}
GLSL

SAMPLING_FRAGMENT :: #string GLSL
#version 330 core
uniform sampler2D imported;
out vec4 color;
void main() {
    color = texelFetch(imported, ivec2(gl_FragCoord.xy), 0);
}
GLSL

build_sampling_program :: () -> u32 {
    compile :: (kind: GL.GLenum, source: string, label: string) -> u32 {
        shader := GL.glCreateShader(kind);
        text := source.data;
        length := cast(GL.GLint) source.count;
        GL.glShaderSource(shader, 1, *text, *length);
        GL.glCompileShader(shader);
        ok: GL.GLint;
        GL.glGetShaderiv(shader, GL.GL_COMPILE_STATUS, *ok);
        if !ok {
            info: [1024] u8;
            info_length: GL.GLsizei;
            GL.glGetShaderInfoLog(shader, info.count, *info_length, info.data);
            fail("the % shader did not compile: %", label, to_string(info.data, info_length));
        }
        return shader;
    }
    vertex   := compile(GL.GL_VERTEX_SHADER,   SAMPLING_VERTEX,   "vertex");
    fragment := compile(GL.GL_FRAGMENT_SHADER, SAMPLING_FRAGMENT, "fragment");
    defer GL.glDeleteShader(vertex);
    defer GL.glDeleteShader(fragment);

    program := GL.glCreateProgram();
    GL.glAttachShader(program, vertex);
    GL.glAttachShader(program, fragment);
    GL.glLinkProgram(program);
    ok: GL.GLint;
    GL.glGetProgramiv(program, GL.GL_LINK_STATUS, *ok);
    if !ok  fail("the sampling program did not link");
    return program;
}

// GL row 0 is the first row in memory, for the import and for glReadPixels alike, so
// row y of either buffer is pattern row y.
count_mismatches :: (pixels: *u8, row_bytes: int, label: string) -> int {
    wrong := 0;
    for y: 0..HEIGHT - 1  for x: 0..WIDTH - 1 {
        want := pattern(x, y);
        got := pixels + y * row_bytes + x * 4;
        if got[0] == want[0] && got[1] == want[1] && got[2] == want[2] && got[3] == want[3]  continue;
        if wrong < 4 {
            print("  % mismatch at (%, %): got (%, %, %, %), want (%, %, %, %)\n", label, x, y,
                got[0], got[1], got[2], got[3], want[0], want[1], want[2], want[3]);
        }
        wrong += 1;
    }
    return wrong;
}

// The dma-buf's exporter, as the kernel names it (/proc/self/fdinfo).
print_fdinfo :: (fd: s32) {
    text, ok := read_pseudo_file(tprint("/proc/self/fdinfo/%", fd));
    if !ok  return;
    for line: split(text, "\n") {
        if begins_with(line, "exp_name") || begins_with(line, "size")  print("  fdinfo %\n", line);
    }
}

// Which devices the kernel has this dma-buf attached to. bufinfo is root-only, so an
// ordinary run just says so; run as root (or read it from a debugger stopped here) to
// see the importer's PCI address under the buffer.
report_attachments :: (fd: s32) {
    st: stat_t;
    if fstat(fd, *st) != 0  return;
    text, ok := read_pseudo_file("/sys/kernel/debug/dma_buf/bufinfo");
    if !ok {
        print("Kernel attachments: /sys/kernel/debug/dma_buf/bufinfo is not readable (needs root); dma-buf inode %\n", st.st_ino);
        return;
    }
    lines := split(text, "\n");
    for line, i: lines {
        fields := split(trim(line), "\t");
        if fields.count < 6  continue;
        ino, ino_ok := string_to_int(trim(fields[5]));
        if !ino_ok || cast(u64) ino != st.st_ino  continue;
        print("Kernel attachments for dma-buf inode %: exporter %\n", st.st_ino, trim(fields[4]));
        // The object's own lines are tab-indented: its fences, then "Attached Devices:"
        // and one PCI address per attached device.
        in_attached := false;
        for j: i + 1..lines.count - 1 {
            if !begins_with(lines[j], "\t")  break;   // the next object, or the "Total" line
            next := trim(lines[j]);
            if begins_with(next, "Attached") { in_attached = true; continue; }
            if in_attached  print("  attached: %\n", next);
            else            print("  %\n", next);
        }
        return;
    }
    print("Kernel attachments: inode % not found in bufinfo\n", st.st_ino);
}

// procfs and debugfs files report a size of 0, so read_entire_file, which reads
// st_size bytes, returns them empty. Read until end of file instead.
read_pseudo_file :: (path: string) -> string, bool {
    fd := open(temp_c_string(path), O_RDONLY | O_CLOEXEC);
    if fd < 0  return "", false;
    defer close(fd);
    builder: String_Builder;
    chunk: [4096] u8;
    while true {
        n := read(fd, chunk.data, chunk.count);
        if n < 0  return "", false;
        if n == 0  break;
        append(*builder, chunk.data, n);
    }
    return builder_to_string(*builder), true;
}
