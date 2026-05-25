// headless_vulkan_dmabuf — smoke test for Vulkan external-memory export.
//
// This is the first Vulkan path that fits jai-wayland's architecture: create a
// Vulkan image with DMA-BUF external memory enabled and export the backing
// VkDeviceMemory as an fd. Wayland presentation will build on this rather than
// VK_KHR_wayland_surface, which requires libwayland-client wl_* proxy objects.

Vulkan :: #import,dir "../modules/Vulkan";
#import "Basic";
#import "POSIX";

IMAGE_WIDTH  :: 64;
IMAGE_HEIGHT :: 64;

Image_Config :: struct {
    format:              Vulkan.VkFormat;
    tiling:              Vulkan.VkImageTiling;
    usage:               Vulkan.VkImageUsageFlags;
    label:               string;
    use_drm_modifier:    bool;
    drm_format_modifier: u64;
}

main :: () {
    if !Vulkan.init_vulkan() {
        print("Could not load Vulkan runtime.\n");
        return;
    }

    api_version := get_loader_api_version();
    version := Vulkan.vk_unmake_version(api_version);
    print("Vulkan loader API %.%.%\n", version.major, version.minor, version.patch);

    app_info: Vulkan.VkApplicationInfo;
    app_info.pApplicationName = "jai-wayland headless_vulkan_dmabuf".data;
    app_info.applicationVersion = Vulkan.VK_MAKE_VERSION(0, 1, 0);
    app_info.pEngineName = "jai-wayland".data;
    app_info.engineVersion = Vulkan.VK_MAKE_VERSION(0, 1, 0);
    app_info.apiVersion = ifx api_version >= Vulkan.VK_API_VERSION_1_1 then Vulkan.VK_API_VERSION_1_1 else Vulkan.VK_API_VERSION_1_0;

    create_info: Vulkan.VkInstanceCreateInfo;
    create_info.pApplicationInfo = *app_info;

    instance: Vulkan.VkInstance;
    result := Vulkan.vkCreateInstance(*create_info, null, *instance);
    if result != .SUCCESS {
        print("vkCreateInstance failed: %\n", result);
        if result == .ERROR_INCOMPATIBLE_DRIVER  print_vulkan_loader_overrides();
        return;
    }
    defer Vulkan.vkDestroyInstance(instance, null);

    if !Vulkan.load_vulkan_instance_functions(instance) {
        print("Could not load required Vulkan instance functions.\n");
        return;
    }

    physical, ok := choose_physical_device(instance);
    if !ok  return;

    props: Vulkan.VkPhysicalDeviceProperties;
    Vulkan.vkGetPhysicalDeviceProperties(physical, *props);
    device_version := Vulkan.vk_unmake_version(props.apiVersion);
    print("Physical device: % vendor=0x% device=0x% api=%.%.%\n",
        to_string(props.deviceName.data),
        formatInt(props.vendorID, base=16, minimum_digits=4),
        formatInt(props.deviceID, base=16, minimum_digits=4),
        device_version.major, device_version.minor, device_version.patch);

    if !device_supports_extension(physical, Vulkan.VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME) {
        print("Device does not support %.\n", Vulkan.VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME);
        return;
    }
    if !device_supports_extension(physical, Vulkan.VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME) {
        print("Device does not support %.\n", Vulkan.VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME);
        return;
    }
    if !device_supports_extension(physical, Vulkan.VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME) {
        print("Device does not support %.\n", Vulkan.VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME);
        return;
    }

    queue_family, queue_ok := find_graphics_queue_family(physical);
    if !queue_ok {
        print("No graphics queue family found.\n");
        return;
    }
    print("Graphics queue family: %\n", queue_family);

    if Vulkan.vkGetPhysicalDeviceImageFormatProperties2 == null {
        print("vkGetPhysicalDeviceImageFormatProperties2 unavailable; need Vulkan 1.1 or VK_KHR_get_physical_device_properties2.\n");
        return;
    }

    handle_type := Vulkan.VkExternalMemoryHandleTypeFlagBits.DMA_BUF_BIT_EXT;
    config: Image_Config;
    external_props: Vulkan.VkExternalImageFormatProperties;
    format_ok: bool;

    config, external_props, format_ok = try_drm_modifier_config(physical,
        .B8G8R8A8_UNORM,
        Vulkan.VkImageUsageFlagBits.COLOR_ATTACHMENT_BIT | Vulkan.VkImageUsageFlagBits.TRANSFER_SRC_BIT,
        "B8G8R8A8 DRM-modifier color-attachment", handle_type);
    if !format_ok {
        config, external_props, format_ok = try_drm_modifier_config(physical,
            .R8G8B8A8_UNORM,
            Vulkan.VkImageUsageFlagBits.COLOR_ATTACHMENT_BIT | Vulkan.VkImageUsageFlagBits.TRANSFER_SRC_BIT,
            "R8G8B8A8 DRM-modifier color-attachment", handle_type);
    }
    if !format_ok {
        config, external_props, format_ok = try_image_config(physical,
            .B8G8R8A8_UNORM, .OPTIMAL,
            Vulkan.VkImageUsageFlagBits.COLOR_ATTACHMENT_BIT | Vulkan.VkImageUsageFlagBits.TRANSFER_SRC_BIT,
            "B8G8R8A8 optimal color-attachment", handle_type);
    }
    if !format_ok {
        config, external_props, format_ok = try_image_config(physical,
            .R8G8B8A8_UNORM, .OPTIMAL,
            Vulkan.VkImageUsageFlagBits.COLOR_ATTACHMENT_BIT | Vulkan.VkImageUsageFlagBits.TRANSFER_SRC_BIT,
            "R8G8B8A8 optimal color-attachment", handle_type);
    }
    if !format_ok {
        config, external_props, format_ok = try_image_config(physical,
            .B8G8R8A8_UNORM, .LINEAR,
            Vulkan.VkImageUsageFlagBits.TRANSFER_SRC_BIT | Vulkan.VkImageUsageFlagBits.TRANSFER_DST_BIT,
            "B8G8R8A8 linear transfer", handle_type);
    }
    if !format_ok {
        config, external_props, format_ok = try_image_config(physical,
            .R8G8B8A8_UNORM, .LINEAR,
            Vulkan.VkImageUsageFlagBits.TRANSFER_SRC_BIT | Vulkan.VkImageUsageFlagBits.TRANSFER_DST_BIT,
            "R8G8B8A8 linear transfer", handle_type);
    }

    if !format_ok {
        print("No exportable DMA-BUF image configuration found with the current Vulkan bindings.\n");
        return;
    }
    print("Using image config: %\n", config.label);
    if config.use_drm_modifier {
        print("  DRM modifier: 0x%\n", formatInt(config.drm_format_modifier, base=16, minimum_digits=16));
    }

    features := external_props.externalMemoryProperties.externalMemoryFeatures;
    feature_bits := cast(u32) features;
    if (feature_bits & cast(u32) Vulkan.VkExternalMemoryFeatureFlagBits.EXPORTABLE_BIT) == 0 {
        print("External DMA-BUF image memory is not exportable for this format.\n");
        return;
    }

    print("External memory features: 0x% compatible_handles=0x%\n",
        formatInt(feature_bits, base=16),
        formatInt(cast(u32) external_props.externalMemoryProperties.compatibleHandleTypes, base=16));

    device, device_ok := create_device(physical, queue_family);
    if !device_ok  return;
    defer Vulkan.vkDestroyDevice(device, null);

    if !Vulkan.load_vulkan_device_functions(device) || Vulkan.vkGetMemoryFdKHR == null {
        print("Could not load required Vulkan device functions.\n");
        return;
    }

    image, image_ok := create_exportable_image(device, config, handle_type);
    if !image_ok  return;
    defer Vulkan.vkDestroyImage(device, image, null);

    if config.use_drm_modifier && Vulkan.vkGetImageDrmFormatModifierPropertiesEXT != null {
        image_mod: Vulkan.VkImageDrmFormatModifierPropertiesEXT;
        result = Vulkan.vkGetImageDrmFormatModifierPropertiesEXT(device, image, *image_mod);
        if result == .SUCCESS {
            print("Image DRM modifier: 0x%\n", formatInt(image_mod.drmFormatModifier, base=16, minimum_digits=16));
        }
    }

    req: Vulkan.VkMemoryRequirements;
    Vulkan.vkGetImageMemoryRequirements(device, image, *req);
    print("Image memory: size=% alignment=% type_bits=0x%\n",
        req.size, req.alignment, formatInt(req.memoryTypeBits, base=16));

    memory_type, memory_ok := find_memory_type(physical, req.memoryTypeBits, Vulkan.VkMemoryPropertyFlagBits.DEVICE_LOCAL_BIT);
    if !memory_ok {
        memory_type, memory_ok = find_memory_type(physical, req.memoryTypeBits, cast(Vulkan.VkMemoryPropertyFlags) 0);
    }
    if !memory_ok {
        print("No compatible memory type for exportable image.\n");
        return;
    }

    memory, memory_alloc_ok := allocate_exportable_memory(device, image, req.size, memory_type, handle_type);
    if !memory_alloc_ok  return;
    defer Vulkan.vkFreeMemory(device, memory, null);

    result = Vulkan.vkBindImageMemory(device, image, memory, 0);
    if result != .SUCCESS {
        print("vkBindImageMemory failed: %\n", result);
        return;
    }

    fd: s32 = -1;
    get_fd: Vulkan.VkMemoryGetFdInfoKHR;
    get_fd.memory = memory;
    get_fd.handleType = handle_type;
    result = Vulkan.vkGetMemoryFdKHR(device, *get_fd, *fd);
    if result != .SUCCESS {
        print("vkGetMemoryFdKHR(DMA_BUF) failed: %\n", result);
        return;
    }
    defer if fd >= 0  close(fd);

    print("Exported Vulkan image memory as DMA-BUF fd=%\n", fd);
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
    if result != .SUCCESS {
        print("vkEnumeratePhysicalDevices(count) failed: %\n", result);
        return null, false;
    }
    if count == 0 {
        print("No Vulkan physical devices.\n");
        return null, false;
    }

    devices: [32] Vulkan.VkPhysicalDevice;
    if count > devices.count {
        print("Too many Vulkan physical devices for smoke buffer: %\n", count);
        return null, false;
    }

    result = Vulkan.vkEnumeratePhysicalDevices(instance, *count, devices.data);
    if result != .SUCCESS {
        print("vkEnumeratePhysicalDevices(list) failed: %\n", result);
        return null, false;
    }

    for 0..count - 1 {
        if device_supports_extension(devices[it], Vulkan.VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME) &&
           device_supports_extension(devices[it], Vulkan.VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME)
        {
            return devices[it], true;
        }
    }

    return devices[0], true;
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

query_external_image_support :: (
    physical: Vulkan.VkPhysicalDevice,
    config: Image_Config,
    handle_type: Vulkan.VkExternalMemoryHandleTypeFlagBits
) -> Vulkan.VkExternalImageFormatProperties, bool {
    external_info: Vulkan.VkPhysicalDeviceExternalImageFormatInfo;
    external_info.handleType = handle_type;

    format_info: Vulkan.VkPhysicalDeviceImageFormatInfo2;
    if config.use_drm_modifier {
        drm_info: Vulkan.VkPhysicalDeviceImageDrmFormatModifierInfoEXT;
        drm_info.pNext = *external_info;
        drm_info.drmFormatModifier = config.drm_format_modifier;
        drm_info.sharingMode = .EXCLUSIVE;
        format_info.pNext = *drm_info;
        format_info.tiling = Vulkan.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT;
    } else {
        format_info.pNext = *external_info;
        format_info.tiling = config.tiling;
    }
    format_info.format = config.format;
    format_info.type = ._2D;
    format_info.usage = config.usage;

    external_props: Vulkan.VkExternalImageFormatProperties;
    image_props: Vulkan.VkImageFormatProperties2;
    image_props.pNext = *external_props;

    result := Vulkan.vkGetPhysicalDeviceImageFormatProperties2(physical, *format_info, *image_props);
    if result != .SUCCESS  return .{}, false;

    return external_props, true;
}

try_drm_modifier_config :: (
    physical: Vulkan.VkPhysicalDevice,
    format: Vulkan.VkFormat,
    usage: Vulkan.VkImageUsageFlags,
    label: string,
    handle_type: Vulkan.VkExternalMemoryHandleTypeFlagBits
) -> Image_Config, Vulkan.VkExternalImageFormatProperties, bool {
    modifier_list: Vulkan.VkDrmFormatModifierPropertiesListEXT;
    format_props: Vulkan.VkFormatProperties2;
    format_props.pNext = *modifier_list;

    Vulkan.vkGetPhysicalDeviceFormatProperties2(physical, format, *format_props);
    if modifier_list.drmFormatModifierCount == 0  return .{}, .{}, false;

    modifiers: [128] Vulkan.VkDrmFormatModifierPropertiesEXT;
    if modifier_list.drmFormatModifierCount > modifiers.count {
        modifier_list.drmFormatModifierCount = cast(u32) modifiers.count;
    }

    modifier_list.pDrmFormatModifierProperties = modifiers.data;
    format_props.pNext = *modifier_list;
    Vulkan.vkGetPhysicalDeviceFormatProperties2(physical, format, *format_props);

    for 0..modifier_list.drmFormatModifierCount - 1 {
        config := Image_Config.{
            format = format,
            tiling = Vulkan.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
            usage = usage,
            label = label,
            use_drm_modifier = true,
            drm_format_modifier = modifiers[it].drmFormatModifier,
        };

        props, ok := query_external_image_support(physical, config, handle_type);
        if !ok  continue;

        feature_bits := cast(u32) props.externalMemoryProperties.externalMemoryFeatures;
        if (feature_bits & cast(u32) Vulkan.VkExternalMemoryFeatureFlagBits.EXPORTABLE_BIT) != 0 {
            return config, props, true;
        }
    }

    return .{}, .{}, false;
}

try_image_config :: (
    physical: Vulkan.VkPhysicalDevice,
    format: Vulkan.VkFormat,
    tiling: Vulkan.VkImageTiling,
    usage: Vulkan.VkImageUsageFlags,
    label: string,
    handle_type: Vulkan.VkExternalMemoryHandleTypeFlagBits
) -> Image_Config, Vulkan.VkExternalImageFormatProperties, bool {
    config := Image_Config.{ format = format, tiling = tiling, usage = usage, label = label };
    props, ok := query_external_image_support(physical, config, handle_type);
    if !ok  return config, props, false;

    feature_bits := cast(u32) props.externalMemoryProperties.externalMemoryFeatures;
    if (feature_bits & cast(u32) Vulkan.VkExternalMemoryFeatureFlagBits.EXPORTABLE_BIT) == 0 {
        return config, props, false;
    }

    return config, props, true;
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

create_exportable_image :: (
    device: Vulkan.VkDevice,
    config: Image_Config,
    handle_type: Vulkan.VkExternalMemoryHandleTypeFlagBits
) -> Vulkan.VkImage, bool {
    external_info: Vulkan.VkExternalMemoryImageCreateInfo;
    external_info.handleTypes = handle_type;

    image_info: Vulkan.VkImageCreateInfo;
    modifier: u64;
    modifier_info: Vulkan.VkImageDrmFormatModifierListCreateInfoEXT;
    if config.use_drm_modifier {
        modifier = config.drm_format_modifier;
        modifier_info.pNext = *external_info;
        modifier_info.drmFormatModifierCount = 1;
        modifier_info.pDrmFormatModifiers = *modifier;
        image_info.pNext = *modifier_info;
        image_info.tiling = Vulkan.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT;
    } else {
        image_info.pNext = *external_info;
        image_info.tiling = config.tiling;
    }
    image_info.imageType = ._2D;
    image_info.format = config.format;
    image_info.extent = .{ width = IMAGE_WIDTH, height = IMAGE_HEIGHT, depth = 1 };
    image_info.mipLevels = 1;
    image_info.arrayLayers = 1;
    image_info.samples = ._1_BIT;
    image_info.usage = config.usage;
    image_info.sharingMode = .EXCLUSIVE;
    image_info.initialLayout = .UNDEFINED;

    image: Vulkan.VkImage;
    result := Vulkan.vkCreateImage(device, *image_info, null, *image);
    if result != .SUCCESS {
        print("vkCreateImage(exportable DMA-BUF) failed: %\n", result);
        return null, false;
    }

    return image, true;
}

allocate_exportable_memory :: (
    device: Vulkan.VkDevice,
    image: Vulkan.VkImage,
    size: Vulkan.VkDeviceSize,
    memory_type: u32,
    handle_type: Vulkan.VkExternalMemoryHandleTypeFlagBits
) -> Vulkan.VkDeviceMemory, bool {
    dedicated_info: Vulkan.VkMemoryDedicatedAllocateInfo;
    dedicated_info.image = image;

    export_info: Vulkan.VkExportMemoryAllocateInfo;
    export_info.pNext = *dedicated_info;
    export_info.handleTypes = handle_type;

    alloc_info: Vulkan.VkMemoryAllocateInfo;
    alloc_info.pNext = *export_info;
    alloc_info.allocationSize = size;
    alloc_info.memoryTypeIndex = memory_type;

    memory: Vulkan.VkDeviceMemory;
    result := Vulkan.vkAllocateMemory(device, *alloc_info, null, *memory);
    if result != .SUCCESS {
        print("vkAllocateMemory(exportable) failed: %\n", result);
        return null, false;
    }

    return memory, true;
}

find_memory_type :: (
    physical: Vulkan.VkPhysicalDevice,
    type_bits: u32,
    required: Vulkan.VkMemoryPropertyFlags
) -> u32, bool {
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
