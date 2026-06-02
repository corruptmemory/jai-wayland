// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers

// headless_vulkan — smoke test for the runtime-loaded Vulkan binding.
//
// This intentionally does not create a window or Wayland surface. It proves the
// vendored Vulkan module can dlopen the platform loader, create an instance,
// enumerate physical devices, and stay out of the executable's link graph.

Vulkan :: #import,dir "../modules/Vulkan";
#import "Basic";
#import "POSIX";

main :: () {
    if !Vulkan.init_vulkan() {
        print("Could not load Vulkan runtime.\n");
        return;
    }

    api_version := Vulkan.VK_API_VERSION_1_0;
    if Vulkan.vkEnumerateInstanceVersion != null {
        result := Vulkan.vkEnumerateInstanceVersion(*api_version);
        if result != .SUCCESS {
            print("vkEnumerateInstanceVersion failed: %\n", result);
            api_version = Vulkan.VK_API_VERSION_1_0;
        }
    }

    version := Vulkan.vk_unmake_version(api_version);
    print("Vulkan loader API %.%.%\n", version.major, version.minor, version.patch);

    app_info: Vulkan.VkApplicationInfo;
    app_info.pApplicationName = "jai-wayland headless_vulkan".data;
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

    device_count: u32;
    result = Vulkan.vkEnumeratePhysicalDevices(instance, *device_count, null);
    if result != .SUCCESS {
        print("vkEnumeratePhysicalDevices(count) failed: %\n", result);
        return;
    }

    print("Physical devices: %\n", device_count);
    if device_count == 0  return;

    devices: [32] Vulkan.VkPhysicalDevice;
    if device_count > devices.count {
        print("Too many Vulkan physical devices for smoke buffer: %\n", device_count);
        return;
    }

    result = Vulkan.vkEnumeratePhysicalDevices(instance, *device_count, devices.data);
    if result != .SUCCESS {
        print("vkEnumeratePhysicalDevices(list) failed: %\n", result);
        return;
    }

    for 0..device_count - 1 {
        physical := devices[it];
        props: Vulkan.VkPhysicalDeviceProperties;
        Vulkan.vkGetPhysicalDeviceProperties(physical, *props);

        ext_count: u32;
        ext_result := Vulkan.vkEnumerateDeviceExtensionProperties(physical, null, *ext_count, null);
        if ext_result != .SUCCESS  ext_count = 0;

        dev_version := Vulkan.vk_unmake_version(props.apiVersion);
        print("  [%] % vendor=0x% device=0x% api=%.%.% extensions=%\n",
            it,
            to_string(props.deviceName.data),
            formatInt(props.vendorID, base=16, minimum_digits=4),
            formatInt(props.deviceID, base=16, minimum_digits=4),
            dev_version.major, dev_version.minor, dev_version.patch,
            ext_count);
    }
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
