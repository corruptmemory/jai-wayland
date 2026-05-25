/*

Vulkan API bindings.

Current version of headers is Vulkan v1.1.85.

This vendored copy keeps the generated type/constant/PFN surface from Jai's
distribution module, but removes hard-linked Vulkan libraries. All callable
Vulkan commands are function-pointer variables populated at runtime by
loader.jai through vkGetInstanceProcAddr/vkGetDeviceProcAddr.

WARNING: These Vulkan bindings are somewhat tested on Windows, and on Android when using OpenXR, but for other
platforms, or if you wantto use later versions of vulkan, you can expect to do a significant amount of work to
get things going well.

Other Vulkan modules are available, eg https://github.com/osor-io/osor_vulkan/.

*/


#module_parameters();

// Helpers

VkVersion :: u32;

VK_Version :: struct {
    major, minor, patch: VkVersion;
}

vk_unmake_version :: (vk_version: VkVersion) -> VK_Version {
    major := VK_VERSION_MAJOR(vk_version);
    minor := VK_VERSION_MINOR(vk_version);
    patch := VK_VERSION_PATCH(vk_version);
    return .{major, minor, patch};
}

// Macros from vulkan headers

VK_NULL_HANDLE                    :: null;

VK_TRUE:                   VkBool32: 1;
VK_FALSE:                  VkBool32: 0;

VK_WHOLE_SIZE:             u64: xx ~0;
VK_ATTACHMENT_UNUSED:      u32: 0xffff_ffff;
VK_QUEUE_FAMILY_IGNORED:   u32: 0xffff_ffff;
VK_REMAINING_ARRAY_LAYERS: u32: 0xffff_ffff;
VK_REMAINING_MIP_LEVELS:   u32: 0xffff_ffff;
VK_SUBPASS_EXTERNAL:       u32: 0xffff_ffff;

VK_MAX_PHYSICAL_DEVICE_NAME_SIZE: u32: 256;
VK_UUID_SIZE:                     u32: 16;
VK_MAX_MEMORY_TYPES:              u32: 32;
VK_MAX_MEMORY_HEAPS:              u32: 16;
VK_MAX_EXTENSION_NAME_SIZE:       u32: 256;
VK_MAX_DESCRIPTION_SIZE:          u32: 256;

// These defines are deprecated by vulkan 1.2:
VK_MAKE_VERSION :: (major: u32, minor: u32, patch: u32) -> u32 {
    return (major << 22) | (minor << 12) | patch;
}
VK_VERSION_MAJOR :: (version: u32) -> u32 { return version >> 22; }
VK_VERSION_MINOR :: (version: u32) -> u32 { return (version >> 12) & 0x3ff; }
VK_VERSION_PATCH :: (version: u32) -> u32 { return version & 0xfff; }

VK_API_VERSION_1_0 :: #run VK_MAKE_VERSION(1, 0, 0);
VK_API_VERSION_1_1 :: #run VK_MAKE_VERSION(1, 1, 0);
VK_API_VERSION_1_2 :: #run VK_MAKE_VERSION(1, 2, 0);

// These are the new versions:
VK_MAKE_API_VERSION :: (variant:u32, major: u32, minor: u32, patch: u32) -> u32 {
    return (variant << 29) | (major << 22) | (minor << 12) | patch;
}

VK_API_VERSION_VARIANT :: (version: u32) -> u32 { return (version >> 29); }
VK_API_VERSION_MAJOR   :: (version: u32) -> u32 { return (version >> 22) & 0x3ff; }
VK_API_VERSION_MINOR   :: (version: u32) -> u32 { return (version >> 12) & 0x3ff; }
VK_API_VERSION_PATCH   :: (version: u32) -> u32 { return version & 0xfff; }

#if OS == .WINDOWS {
    #load "generated_windows.jai";
    #load "windows_extras.jai";

    vkCreateWin32SurfaceKHR: PFN_vkCreateWin32SurfaceKHR;
    vkGetPhysicalDeviceWin32PresentationSupportKHR: PFN_vkGetPhysicalDeviceWin32PresentationSupportKHR;
} else #if OS == .LINUX || OS == .ANDROID {
    #load "generated_linux.jai";
    #load "linux_drm_format_modifier.jai";

    vkGetMemoryFdKHR: PFN_vkGetMemoryFdKHR;
    vkGetMemoryFdPropertiesKHR: PFN_vkGetMemoryFdPropertiesKHR;
} else {
    #assert false  "Unsupported OS";
}

#load "loader.jai";
