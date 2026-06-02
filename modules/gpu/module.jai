// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jim Powers

// GPU selection policy helpers.
//
// This module is intentionally outside the Wayland protocol generator. It owns
// host/device discovery and backend policy; generated Wayland bindings remain
// XML-driven under modules/wayland.

#load "device.jai";
#load "dmabuf_bo.jai";
