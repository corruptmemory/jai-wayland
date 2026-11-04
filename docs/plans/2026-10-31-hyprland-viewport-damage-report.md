# Draft upstream report: Hyprland drops the viewport source origin when computing surface damage

**Status: DRAFT, not filed.** Written 2026-10-31 for Jim to decide whether to post to
<https://github.com/hyprwm/Hyprland/issues>. The jai-wayland side is already worked around
(the slot capacity height is the logical height, so our viewport source always starts at
row 0; see CLAUDE.md Next Steps #2). Everything below "Report" is the text to post.

---

## Report

### Title

Surface damage ignores the `wp_viewport` source origin: windows with an offset source stop repainting while frame callbacks continue

### Summary

`CWLSurface::computeDamage` (`src/desktop/view/WLSurface.cpp`) intersects a surface's
damage with the `wp_viewport` source rectangle but never translates by the rectangle's
origin. The damage therefore lands at `source.pos` in surface coordinates instead of at
`(0, 0)`, and is then clipped to the surface box. For a source rectangle whose y (or x)
offset is at least the surface height (width), the computed damage is empty: Hyprland stops
repainting the window. `damageSurface` still schedules frame events before computing
damage ("hack: schedule frame events"), so the client keeps receiving `wl_surface.frame`
callbacks at the refresh rate and has no way to notice. On the panel, the window's region
keeps whatever each output buffer last held, so it cycles a few stale frames (one per
swapchain buffer), which looks like flicker plus a frozen or jumping animation.

The bug is invisible to screenshots and screen recorders: screencopy renders a fresh frame
of the current client buffers, and an active screencopy session also leads to full repaints,
which clears the stale content until the next time the condition is hit. It shows on the
real scanout (a phone camera, or `kmsgrab`; on AMD read it through VAAPI, since
`hwmap=derive_device=vulkan` blanked the live buffer on an RX 7900 GRE).

### Version

- Hyprland 0.57.0 (commit `0aa6745f705f2c4b0a5004eb019ef76e5bbdb426`). `computeDamage` is
  unchanged on `main` as of 2026-10-31.
- Observed on an NVIDIA RTX 3050 Ti laptop, driver 615.78.08, Hyprland compositing on that
  GPU, output 2560x1600 at scale 1.25. Also reproduced on an AMD RX 7900 GRE desktop (same
  Hyprland commit, Mesa, 2560x1440 at scale 1). Nothing in the code path is GPU-specific.

### The code

```cpp
CRegion damage = m_resource->m_current.accumulateBufferDamage();
damage.transform(Math::wlTransformToHyprutils(m_resource->m_current.transform), BUFSIZE.x, BUFSIZE.y);

if (m_resource->m_current.viewport.hasSource)
    damage.intersect(m_resource->m_current.viewport.source);
// missing: move the source rectangle's origin to (0, 0)

damage.scale({BUFSIZE.x / SCALEDSRCSIZE.x, BUFSIZE.y / SCALEDSRCSIZE.y});
damage.translate(CORRECTVEC);
damage.scale(SURFSIZE / BUFSIZE);

if (boxSize)
    damage.intersect(CBox{{}, boxSize.value()});
```

With the buffer fully damaged, a buffer of `B` rows, a source of `(0, s, w, h)` and a
destination of `w x h`, the two scales cancel and the damage comes out as rows `[s, s + h]`
of a surface that is `h` rows tall. After the final intersect, only rows `[s, h]` remain,
and none at all once `s >= h`.

### Steps to reproduce

1. A client attaches an `ARGB8888` (or dma-buf) buffer of 1024x1280 and sets
   `wp_viewport.set_source(0, 662, 1016, 618)` and `set_destination(1016, 618)`. The source
   lies inside the buffer, so the request is valid.
2. Every frame it redraws the visible region, damages the whole buffer
   (`wl_surface.damage_buffer(0, 0, 1024, 1280)`), requests a frame callback and commits.
3. Watch the panel itself (phone camera or `kmsgrab`; through VAAPI on AMD), not a screenshot.

Expected: the window animates. Actual: the window's region stops updating while the client
keeps getting frame callbacks; with several output buffers it alternates between stale
frames. A source offset smaller than the surface height gives partial damage instead: only
rows `[s, h]` repaint.

We hit it with `set_buffer_transform(FLIPPED_180)`, where a client that renders into the
first rows of a taller buffer needs the source at `y = buffer_height - visible_height`
because the source is in post-transform coordinates (viewporter.xml). From the code, the
origin is dropped regardless of the transform. We did not test without one.

### Measurements

Distinct images in the window region over about 226 consecutive scanout frames (`kmsgrab`,
60 Hz), from a client that animates every frame:

| Configuration                                  | Distinct images |
|------------------------------------------------|-----------------|
| two windows, source y offset 662, height 618   | 3               |
| one window, source y offset 830, height 450    | 31              |
| same client, viewport crop disabled (offset 0) | 209             |
| same client, source kept at (0, 0) (our fix)   | 212             |
| the same program under XWayland                | 212             |

On the AMD desktop, over about 235 frames, the same client gave 3 distinct images in the two-window
configuration, against 221 with the source at (0, 0).

A screen recording (`wf-recorder`) of the broken configuration shows every frame correctly.

### Suggested fix (untested: not compiled)

Translate by the source origin after the intersect. `viewport.source` is in surface units
(after buffer scale) while the damage is in buffer pixels at that point, so it probably
needs the buffer scale applied too. We only exercised buffer scale 1:

```cpp
if (m_resource->m_current.viewport.hasSource) {
    CBox src = m_resource->m_current.viewport.source;
    src.scale(m_resource->m_current.scale);
    damage.intersect(src);
    damage.translate(-src.pos());
}
```

### Workaround for clients

Keep the viewport source at `(0, 0)`: size the buffer so the visible content starts at the
source origin after the buffer transform. jai-wayland now does this by making its buffer
height equal the visible height and keeping spare capacity in width only, since the x
origin of its source is always 0.
