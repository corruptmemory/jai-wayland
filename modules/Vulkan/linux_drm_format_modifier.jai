// Minimal Linux supplement for VK_EXT_image_drm_format_modifier and
// VK_EXT_physical_device_drm.
//
// The vendored Jai Vulkan headers are v1.1.85 and predate both extensions, but
// modern Vulkan DMA-BUF export on Linux needs DRM-format-modifier image tiling,
// and a client on a hybrid machine needs to know which DRM node it renders on.

VK_EXT_image_drm_format_modifier :: 1;
VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_SPEC_VERSION :: 2;
VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME :: "VK_EXT_image_drm_format_modifier";

VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT:             VkStructureType: 1000158000;
VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_DRM_FORMAT_MODIFIER_INFO_EXT:  VkStructureType: 1000158002;
VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT:      VkStructureType: 1000158003;
VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT:  VkStructureType: 1000158004;
VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_PROPERTIES_EXT:            VkStructureType: 1000158005;

VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT: VkImageTiling: 1000158000;
VK_IMAGE_ASPECT_MEMORY_PLANE_0_BIT_EXT: VkImageAspectFlagBits: 0x00000080;
VK_IMAGE_ASPECT_MEMORY_PLANE_1_BIT_EXT: VkImageAspectFlagBits: 0x00000100;
VK_IMAGE_ASPECT_MEMORY_PLANE_2_BIT_EXT: VkImageAspectFlagBits: 0x00000200;
VK_IMAGE_ASPECT_MEMORY_PLANE_3_BIT_EXT: VkImageAspectFlagBits: 0x00000400;

VkDrmFormatModifierPropertiesEXT :: struct {
    drmFormatModifier:               u64;
    drmFormatModifierPlaneCount:     u32;
    drmFormatModifierTilingFeatures: VkFormatFeatureFlags;
}

VkDrmFormatModifierPropertiesListEXT :: struct {
    sType:                         VkStructureType = VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT;
    pNext:                         *void;
    drmFormatModifierCount:        u32;
    pDrmFormatModifierProperties:  *VkDrmFormatModifierPropertiesEXT;
}

VkPhysicalDeviceImageDrmFormatModifierInfoEXT :: struct {
    sType:                 VkStructureType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_DRM_FORMAT_MODIFIER_INFO_EXT;
    pNext:                 *void;
    drmFormatModifier:     u64;
    sharingMode:           VkSharingMode;
    queueFamilyIndexCount: u32;
    pQueueFamilyIndices:   *u32;
}

VkImageDrmFormatModifierListCreateInfoEXT :: struct {
    sType:                  VkStructureType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT;
    pNext:                  *void;
    drmFormatModifierCount: u32;
    pDrmFormatModifiers:    *u64;
}

VkImageDrmFormatModifierExplicitCreateInfoEXT :: struct {
    sType:                       VkStructureType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT;
    pNext:                       *void;
    drmFormatModifier:           u64;
    drmFormatModifierPlaneCount: u32;
    pPlaneLayouts:               *VkSubresourceLayout;
}

VkImageDrmFormatModifierPropertiesEXT :: struct {
    sType:             VkStructureType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_PROPERTIES_EXT;
    pNext:             *void;
    drmFormatModifier: u64;
}

PFN_vkGetImageDrmFormatModifierPropertiesEXT :: #type (
    device: VkDevice,
    image: VkImage,
    pProperties: *VkImageDrmFormatModifierPropertiesEXT
) -> VkResult #c_call;

vkGetImageDrmFormatModifierPropertiesEXT: PFN_vkGetImageDrmFormatModifierPropertiesEXT;

// VK_EXT_physical_device_drm: the DRM primary and render nodes (major:minor) a
// physical device is, so a client can tell whether it renders on the
// compositor's main device. Chained into vkGetPhysicalDeviceProperties2.
VK_EXT_physical_device_drm :: 1;
VK_EXT_PHYSICAL_DEVICE_DRM_SPEC_VERSION :: 1;
VK_EXT_PHYSICAL_DEVICE_DRM_EXTENSION_NAME :: "VK_EXT_physical_device_drm";

VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT: VkStructureType: 1000353000;

VkPhysicalDeviceDrmPropertiesEXT :: struct {
    sType:        VkStructureType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT;
    pNext:        *void;
    hasPrimary:   VkBool32;
    hasRender:    VkBool32;
    primaryMajor: s64;
    primaryMinor: s64;
    renderMajor:  s64;
    renderMinor:  s64;
}
