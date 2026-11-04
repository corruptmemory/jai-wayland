# game-bootstrap → jai-wayland backport audit

> 2026-10-26. Pre-V2 sweep: what did `~/projects/game-bootstrap` fix or add in the
> windowing stack it vendored from here on 2026-06-03 that this repo still lacks?
> Method: file-by-file diff of `modules/wayland`, the generator, `Input`, and
> `Wayland_Support`; a walk of game-bootstrap's 45 `Wayland_Support` commits since the
> vendoring; every candidate checked against this repo's source. One claim was
> compiled and run (item 1). Nothing was run against a live compositor (this desktop
> is on i3/X11 today), so the live checks are listed per item.

## Summary

| #   | Item                                                            | Kind     | Here?               | Severity here | Effort |
|-----|-----------------------------------------------------------------|----------|---------------------|---------------|--------|
| 1   | DRM modifier high word dropped by cast-before-shift             | bug      | yes, proven         | high          | tiny   |
| 2   | N `wl_output` proxies all bind the FIRST output global          | bug      | yes, by code read   | medium        | small  |
| 3   | Pacing: app-turn bail flagged as starvation + latch never heals | bug      | yes, milder trigger | low-medium    | small  |
| 4   | Roundtrip drains byte-consume foreign messages (fd FIFO desync) | bug      | yes, structural     | medium        | medium |
| 5   | `xdg_toplevel.set_app_id` never sent                            | gap      | yes                 | low           | tiny   |
| 6   | Keymap parsed from a stored fd three roundtrips later           | hygiene  | yes                 | low           | small  |
| 7   | Release erases the START bit (sub-frame taps lose their edge)   | behavior | yes (and upstream)  | low-medium    | tiny   |
| 8   | Errors surfaced by `assert` / `print` in wire + generator       | hygiene  | partly              | low           | small  |
| 9   | Regression tests worth porting                                  | tests    | missing             | -             | small  |
| 10  | Per-window output tracking (`wl_surface.enter`/`leave`)         | addition | missing             | -             | medium |
| 11  | Compositor `main_device` → render-node choice                   | addition | missing             | -             | small  |
| 12  | Pointer capture (relative pointer + constraints)                | addition | missing (gap #1)    | -             | medium |
| 13  | dlopen'd libxkbcommon instead of `xkb.jai`                      | V2 call  | -                   | -             | medium |
| 14  | SRGB `VkFormat` in `hello_vulkan_dmabuf`                        | polish   | UNORM today         | low           | tiny   |
| 15  | X11 arm: NorthWest bit gravity on resize                        | polish   | not set             | low           | tiny   |

Items 1 to 4 are real defects present in this tree. Items 5 to 9 are cheap. Items
10 to 15 are additions that mostly belong in the V2 design rather than a patch.

## Tier 1 — defects present here

### 1. DRM modifier high word dropped (`dmabuf.jai:78`, `dmabuf.jai:205`)

Both decode sites spell the 64-bit modifier as

```jai
(cast(u64) modifier_hi << 32) | cast(u64) modifier_lo
```

which the project's own precedence note (CLAUDE.md, "cast binds looser than `<<`")
says parses as `cast(u64)(modifier_hi << 32)`: a `u32` shifted by 32. Compiled and
run on beta 0.2.030:

```
bad  = 0x0000000000e08014      // current spelling
good = 0x0300000000e08014      // ((cast(u64) hi) << 32) | lo
```

Every modifier the compositor advertises with a nonzero vendor byte comes back
with the vendor byte gone. That is every tiled modifier on every vendor: AMD
`0x02…`, Intel `0x01…`, NVIDIA `0x03…`. Only `LINEAR` (0) survives, and
`DRM_FORMAT_MOD_INVALID` (`0x00ffffffffffffff`) is mangled to `0x00000000ffffffff`,
so `pick_format`'s INVALID preference never fires from a parsed table either.

Both consumers are affected: `get_dmabuf_info` (the `.MODIFIER` event path, the
global list) and `append_feedback_format_table` (the v4 feedback tranches). The
examples and `Wayland_Support` *encode* correctly (`modifier >> 32`), so the
request side is fine; it is the parse of what the compositor said that is wrong.

**Why this matters beyond correctness.** This repo's documented NVIDIA caveat says
the per-surface feedback tranches "advertise no GBM-usable ABGR/XBGR format", and
`hello_vulkan_dmabuf`'s driver-first probing exists because the compositor's
advertised list "under-reports and comes up empty" on NVIDIA. game-bootstrap's own
notes, written the day before they found this bug, describe NVIDIA's advertised
modifiers as "vendor-zeroed". A vendor-stripped modifier is exactly what
`supports_bo_format_modifier` and `gbm_bo_create_with_modifiers` would reject. The
caveat may be an artifact of this parse. The driver-first path stays valid on its
own merits (it never reads the table), but its rationale should be re-tested.

Backport: parenthesize both sites. Then, on a Wayland session, run `hello_dmabuf`
and confirm the printed modifiers carry vendor prefixes; on the NVIDIA laptop, see
whether the feedback path now yields a usable tiled format and retire the caveat if
it does. Add the format-table unit test from item 9, which asserts a modifier with
a nonzero high word.

game-bootstrap: `9acc257` (2026-06-25), found by the regression test in item 9.

### 2. Every `wl_output` binds the first output global (`output.jai:46-53`)

`get_screens_info` counts the `wl_output` globals and binds one proxy per count
through `wl_registry_bind` overload 1. That resolves to overload 3
(`registry.jai:140-146`), which looks the interface up with `get_global(name)`,
and `get_global` returns the first match. All N proxies are bound to the same
compositor-assigned global name, so on a two-monitor session `get_screens_info`
returns monitor 1 twice. `get_seats_info` has the same shape for multi-seat.

Consequences here: `hello_screens` is wrong on multi-monitor; `wl_output_cap`
(`Wayland_Support.jai:105-111`) takes the max over the returned screens, so the
bucketed-slot cap is monitor 1's resolution whatever monitor the window is on.

Backport: game-bootstrap's overload 4, `wl_registry_bind(batch, registry, gi:
Global_Info, id, ti)`, which binds a *specific* `Global_Info` by its `name`; then
iterate the globals in `get_screens_info` and `get_seats_info` instead of counting
them. Verify with `hello_screens` on a two-monitor Hyprland session.

game-bootstrap: `28c23b2` (2026-06-27), which states the cause in its message.

### 3. Pacing: an app-turn bail is misread as starvation, and starvation never heals (`Wayland_Support.jai:862-905`, `:1878`)

The vsync wait in `wl_present_and_pace` breaks on `wl_any_window_needs_app_turn()`
(a configure or close arrived), and the code after the loop only distinguishes
`wl_frame_done` from everything else, so that bail sets `wl_pacing_starved = true`
exactly as a genuine timeout does. The pump then matches `wl_callback.done` only
against the *current* `wl_pending_frame_callback`, so a done for an id that was
abandoned never clears the flag, and the abandoned id is never returned to
`wl_frame_cache`.

The trigger is milder here than in game-bootstrap. A single-window app keeps the
50 ms timeout when every window is starved (`wl_all_windows_starved`), so the next
present waits on a fresh callback and heals. The multi-window case does not: resize
window A while B is visible, A is flagged starved, A's presents now poll with
timeout 0, each frame abandons its id before its done arrives, and A stays starved
until B is closed or occluded. Item 4 supplies a second trigger (a swallowed done).
Either way the id cache leaks one entry per abandonment.

Backport (`19cc46f`, 54 lines): classify the wait's exit, so an app-turn bail
leaves starvation unchanged and only a real timeout sets it; keep abandoned ids in
a small orphan list (capped, evict oldest); when a done arrives for any orphaned id,
clear starvation and recycle the id. The orphan match is (object, opcode)
qualified, so it cannot collide with `wl_buffer.release` at opcode 0.

### 4. Roundtrip drains byte-consume foreign messages (`session.jai:71-74`)

The `for session()` expansion consumes each message's bytes in a `defer` and never
touches the fd FIFO. Any message the loop body does not recognise is therefore
dropped, and if it carried an fd (`wl_keyboard.keymap` on a layout switch or
hotplug; `zwp_linux_dmabuf_feedback_v1.format_table`) that fd stays at the head of
`in_fds`, and the next unmarshal of an fd-bearing event pops the wrong one. The
collector then mmaps a keymap as a format table, or vice versa, and the FIFO is
off by one for the rest of the session.

This repo already knows about the dropped-event half: `wl_acquire_input` is
documented as "MUST be called before the render loop's first pump" for exactly this
reason, and `create_window_wayland` routes other windows' configure/close while
waiting for its first configure. The remaining mid-session drains are:

- `wl_window_init_gl` → `get_surface_dmabuf_feedback` for a window created after
  presenting began;
- the first `wl_target_capacity` → `wl_output_cap` → `get_screens_info`;
- `create_window_wayland`'s configure wait, which routes configure/close only.

A concrete chain: creating a second window can swallow window 1's pending frame
`done`, which times out its next wait, flags it starved, and item 3 keeps it
there while window 2 is visible.

Backport: game-bootstrap's shape is sound and small. Extract the pump's per-message
routing into a `wl_route_message(header)` that reads the payload and pops fds but
never consumes bytes; add a `Foreign_Message_Handler` parameter to the wire-layer
collectors (`collect_dmabuf_feedback`, and here also the output/seat/keyboard/
pointer/data-device discovery loops); pass the router from `Wayland_Support`. The
collector calls the handler *before* its own byte-consume, so fds pop in order.
Port the socketpair + memfd regression test (item 9). For V2 the stronger rule is:
one router, and every roundtrip goes through it with a stop predicate.

game-bootstrap: `9acc257`; design note
`docs/plans/2026-06-25-dmabuf-feedback-foreign-message-routing-design.md` there.

## Tier 2 — cheap hygiene

### 5. `xdg_toplevel.set_app_id` (`Window_Creation/linux.jai:279`; the examples)

Only `set_title` is sent. Without an app_id the window has an empty class, so no
compositor rule can target it (Hyprland `class` matches app_id). One call in the
creation batch; game-bootstrap uses the title. `acaf977`.

### 6. Parse the keymap when it arrives (`Wayland_Support.jai:1262-1272`)

`get_keyboards_info` stores `keymap_fd`/`keymap_size`, and `wl_acquire_input`
parses them after three further roundtrips. Nothing here closes that fd behind the
caller's back, so game-bootstrap's recycled-fd race does not reproduce as such, but
a second keymap event landing in those roundtrips is byte-consumed by item 4 and
strands its fd. Parsing at arrival and dropping the two fields removes the window
and the undocumented fd lifetime. `b146ede`.

### 7. A release should preserve the START bit (`Input/wayland.jai:131`, `:252`; `x11.jai:625`, `:677`)

Press and release inside one pump window fold to `.END`, so edge readers
(`& .START`) never see the tap. game-bootstrap changed release to
`.END | (state & .START)` on both backends and proved it with `wtype -k f1` (first
try, versus about fifteen attempts before) plus a regression test. This is a
deliberate deviation from the distribution's semantics, so it is a judgment call,
but it is the honest "pressed and released this frame" state and GetRect's click
detection benefits. Apply to both arms or neither, for parity. `1168777`.

### 8. `assert` and `print` as failure surfacing

`connection.jai` guards outgoing-buffer overflow, fd-queue overflow, and
"no incoming fds" with `assert` alone (lines 145, 152, 177); a build that imports
Basic with `ENABLE_ASSERT=false` turns those into silent memory corruption. The
generator CLI reports errors with `print("ERROR: …")`. game-bootstrap standardised
a `fatal_error` (`log_error` + `exit(1)`) for the CLI and converted the seven
sites (`57e00f5`), and made the runtime checks real (`5a2e174`). Matches the
global "no silent failures" rule.

### 9. Tests worth porting

- `modules/wayland/tests.jai` in game-bootstrap: a headless wire test that builds a
  socketpair, marshals a foreign fd-bearing message ahead of a `FORMAT_TABLE`
  backed by a memfd, runs the collector, and asserts the table read the right fd,
  the modifier round-tripped with its high word, and the FIFO drained. It catches
  items 1 and 4 deterministically. Fits `tests/` here as a `dmabuf_test.jai`.
- `modules/Input/tests.jai` there: fifteen headless translation tests (text vs
  non-text keys, modifier tracking, Ctrl suppresses text, autorepeat synthesis,
  wheel, button-state decay, same-frame tap) under an error-recording logger. This
  repo has no Input tests; the harness shape transfers to `Input/wayland.jai` by
  synthesising `Wl_Input_Event`s into `provisional_input_events`.
- `test_wl_select_monitor`, if item 10 lands.

## Tier 3 — additions, mostly V2 material

### 10. Per-window output tracking

Bind every `wl_output` (needs item 2's overload), cache each output's CURRENT mode
from `wl_output.mode` in the pump, and track which outputs a surface is on from
`wl_surface.enter`/`leave` (`wl_entered_output_ids`, first-entered wins). Then the
bucketed-slot cap can be the window's own monitor instead of the global max, and
`get_dimensions`/HUD scaling have a real per-window resolution. `28c23b2`,
`bf10c98`; about 150 lines in game-bootstrap.

### 11. Compositor `main_device` → render-node choice

**Done 2026-10-31** (step 4 of the laptop's copy-path work). `choose_render_node` takes a
`Device_Preference` built from the decoded `main_device` and ranks it after the two
`JAI_WAYLAND_*` overrides, matching by major:minor and then by the PCI device behind
`/sys/dev/char/M:m/device` (for a compositor that reports its card node).
`Wayland_Support` reads the surface feedback before the shared EGL context exists, and
`hello_vulkan_dmabuf` prefers the Vulkan device whose primary or render node matches.
`tests/gpu_test.jai` covers the policy on a made-up laptop with the dGPU numbered first,
and a mutation that disables the rung fails it. On `nomad-artix` both still land on the
Intel iGPU by default; `JAI_WAYLAND_GPU_VENDOR=nvidia` still selects the dGPU, which then
presents through the shm readback.

`Dmabuf_Feedback_Info.main_device` is already collected here and unused.
`modules/gpu/device.jai` picks env override → vendor override → first node.
game-bootstrap decodes the 8 little-endian bytes as a `dev_t`, splits major/minor
with the glibc `sysmacros` formula (43-line `Drm_Support`), and matches against a
device's primary *or* render node, because compositors report either. On a hybrid
box this picks the GPU the compositor actually scans out from, before any import
can fail. A natural first rung above the env overrides. `34ad9e2`, `09e4442`.
The persistent-feedback device-change detection (`6b485a2`) is more than this repo
needs.

### 12. Pointer capture

This repo's known gap #1. game-bootstrap's recipe, pure wire: on begin, bind
`zwp_pointer_constraints_v1` + `zwp_relative_pointer_manager_v1` lazily, lock the
pointer with `PERSISTENT` lifetime and a null region, create a relative pointer per
`wl_pointer` (per capture, not per process, since a relative pointer reports
whenever its pointer has focus), hide the cursor with `set_cursor(null)` using the
tracked `wl_pointer.enter` serial; on end, destroy both and restore the cursor via a
transient `wp_cursor_shape_device_v1` (`DEFAULT`). Relative motion becomes a
`POINTER_MOTION_RELATIVE` event. All three protocols are already generated here.
Two caveats: game-bootstrap's Wayland arm was **not live-verified** (their desktop
is XLibre), and upstream `Input` has no capture API, so this is a V2 surface
question, not a drop-in. `9f5c9b8`.

### 13. libxkbcommon via dlopen

game-bootstrap replaced the hand-rolled `xkb.jai` with eight dlopen'd symbols
(`xkb_context_new`, `xkb_keymap_new_from_string`, `xkb_state_update_mask`,
`xkb_state_key_get_one_sym`, and their unrefs). That closes AltGr/level-3 and
compose for free and tracks layout groups. It is permitted by the corrected linkage
thesis (dlopen'd, present wherever a display server is), at the cost of retiring
a deliberate zero-dependency parser with its own test suite. A V2 decision.

### 14. SRGB `VkFormat` in `hello_vulkan_dmabuf` (`:654-657`)

The candidate table uses `B8G8R8A8_UNORM`/`R8G8B8A8_UNORM`. game-bootstrap moved
its dmabuf images to the `_SRGB` twins for gamma-correct output that matches the
X11 swapchain (`c8b1c8a`). The fourcc carries no transfer function, so the
`VkFormat` is the whole decision. Example polish.

### 15. X11 arm: resize flash

Upstream `Window_Creation/linux.jai` already sets WM_CLASS and a background pixel,
but not `bit_gravity`. game-bootstrap's `ac5cc1a` set `NorthWestGravity` plus a
clear-colour background to stop the flash on resize. Two lines in an already
patched vendored file; optional.

## Not backportable, and the V2 inputs

Skipped on purpose: the libwayland-era commits (generated listener defaults, the
null-dispatch crash, `VK_KHR_wayland_surface`), all moot on the pure wire; the
`wl_next_event` immediate-consume fix (`ee1e535`), which repaired game-bootstrap's
own deferred-consume drain. Its lesson does apply here: this repo's expansion also
defers the consume to the end of each iteration, so a second drain or
`wayland_receive` inside a `for session()` body would corrupt the cursor the same
way. Nothing does that today; V2 should make it impossible by construction.

What game-bootstrap's shape says about V2, since it is the same author solving the
same problems a second time: `modules/wayland` became stateless (no context
session, no `for session()`, `WaylandMessageHeader` moved to `wire.jai`, explicit
`conn`/`recv`/`globals` everywhere); one `wl_route_message` router owns dispatch
and every drain, including init roundtrips, feeds foreign traffic through it; the
drain contract is consume-immediately; GPU choice is a CLI `--gpu` selector
(`integrated`/`discrete`/name substring, honour-or-fail-loud) instead of the
`JAI_WAYLAND_*` environment knobs. That is the "register objects of interest, pump,
own the sink" end state this repo has been aiming at.

## Verification record

- Item 1: `shiftproof.jai` compiled and run on beta 0.2.030 (session scratchpad).
  Repo-wide grep for the unparenthesised pattern found only the two `dmabuf.jai`
  sites; the `cast(u32)(cast(u32) _offset << 16)` forms in `marshal.jai`,
  `registry.jai`, and the generator shift a `u32` by 16 and are intended.
- Items 2 to 8: code reads of the cited lines, cross-checked against the
  game-bootstrap commit messages and diffs.
- Generated bindings: 231 of the generated files differ, all only in the
  "Regenerate with …" header comment; zero substantive drift. `xml.jai`,
  `protocol.jai`, `connection.jai`, `marshal.jai`, `unmarshal.jai`, `xkb.jai` are
  byte-identical.

## Status (2026-10-26)

| Item | Disposition                         | Note                                                                                                                                                                                                                                                                                                                                                                 |
|------|-------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1    | landed in 5e79328                   | The DRM modifier keeps its high word when decoded. The corrected parse let the feedback picker reach radeonsi's multi-plane DCC modifiers, so 896b1c0 (fix wave) makes the GL pickers require a single-plane modifier. Live on AMD (below): `hello_simp` picks `0x0200000028a01f04`. The NVIDIA re-test is still owed (the CLAUDE.md caveat records it).             |
| 2    | landed in 69fb7fa                   | Every `wl_output` / `wl_seat` global is bound by its compositor name, not the first interface match.                                                                                                                                                                                                                                                                 |
| 3    | landed in e162d07, e54cbe9          | An app-turn exit is not starvation; a late callback heals it; the orphan take keeps order so the cap evicts the oldest.                                                                                                                                                                                                                                              |
| 4    | landed in ce5ce3f, e9a926a          | One router; foreign messages are routed during roundtrip drains instead of dropped.                                                                                                                                                                                                                                                                                  |
| 5    | landed in f1499da                   | `app_id` is set on toplevels.                                                                                                                                                                                                                                                                                                                                        |
| 6    | landed in f1499da, fc7190e          | The keymap is parsed on arrival (plus the initial `repeat_info`); `NO_KEYMAP` is a warning, not an error.                                                                                                                                                                                                                                                            |
| 7    | landed in f1499da                   | A release preserves `START`, so a press and release inside one frame still reads as pressed.                                                                                                                                                                                                                                                                         |
| 8    | landed in 82ea4ae, 46891e3, d18d004 | Connection-layer checks; short sends complete or fail loudly; truncated control data is fatal. The generator CLI's errors (`fatal_error`) and the generated marshal size check (a logged, batch-poisoning check in place of the assert) landed in the fix wave, with receive-side logging, the `EINTR` retry, `MSG_NOSIGNAL` and a fatal incoming fd-queue overflow. |
| 9    | partly landed                       | New suites `dmabuf_test` (3), `registry_test` (2), `pacing_test` (2), `input_test` (5), `gl_picker_test` (1); `wire_test` 22 to 33, `marshal_test` 9 to 10. 139 tests, 12 suites. The sibling project's 15 Input translation tests were not ported: they belong with V2, where the Input module is restructured.                                                     |
| 10   | deferred to V2                      | Per-window output tracking belongs with the V2 registry design.                                                                                                                                                                                                                                                                                                      |
| 11   | deferred to V2                      | Compositor `main_device` to render-node choice belongs with the V2 GPU selector.                                                                                                                                                                                                                                                                                     |
| 12   | deferred to V2                      | Pointer capture needs the V2 input sink.                                                                                                                                                                                                                                                                                                                             |
| 13   | deferred to V2                      | libxkbcommon via dlopen is a V2 addition.                                                                                                                                                                                                                                                                                                                            |
| 14   | deferred to V2                      | The SRGB `VkFormat` choice in `hello_vulkan_dmabuf` is not touched.                                                                                                                                                                                                                                                                                                  |
| 15   | deferred to V2                      | The X11-arm resize flash is not touched.                                                                                                                                                                                                                                                                                                                             |

## Live checks (2026-10-26, Hyprland 0.56.2, AMD RX 7900 GRE, two monitors)

Run the same day as the merge, from the `build/` binaries of master 319e803. Nothing in
the library failed; every window was closed through `xdg_toplevel.close` and every
process exited 0.

| Check                                               | Item | Result  | Evidence                                                                                                                                                                                                                                                                                                                             |
|-----------------------------------------------------|------|---------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `hello_simp` modifier pick                          | 1    | pass    | `using format=0x34324241 modifier=0x200000028a01f04` (AMD tiled, single-plane); three `Initialized BO-backed slot` lines with it; 400 frames clean; the quad renders centred, no band. The same modifier is the one Vulkan's probe gets accepted                                                                                     |
| `hello_dmabuf` feedback decode                      | 1    | pass    | Default and per-surface tranches list `0x0200000028a6bf04`, `0x0200000028a01f04`, … with the high word intact (387 table entries, 335 in the tranche)                                                                                                                                                                                |
| `hello_dmabuf` global list                          | 1    | finding | 0 pairs. The compositor advertises v5 and v4+ sends no `format`/`modifier` events, so the global-list fallback is empty on every current compositor; see the NVIDIA note below                                                                                                                                                       |
| `hello_screens` on two monitors                     | 2    | pass    | DP-2 2560x1440 at 0,240 and HDMI-A-1 1920x1200 at 2560,0, distinct (before: monitor 1 twice)                                                                                                                                                                                                                                         |
| `simp_multiple_windows` resize A while B is visible | 3    | pass    | Three resizes through the compositor; both windows keep animating (500 ms capture pairs differ) and fill edge to edge. Closing A quits the whole app: upstream `multiple_windows.jai` quits on any `.QUIT`, as on X11                                                                                                                |
| `app_id` on every toplevel                          | 5    | pass    | 15 windows, `class` equals the window name on each (`hello_simp`, `Invaders`, `Skeletal Animation`, `A Window` ×6, …). The `jai-application` fallback went unexercised: no example passes an empty name                                                                                                                              |
| autorepeat at the compositor's rate                 | 6    | pass    | With the compositor set to 50/s after 300 ms, holding `a` for 1.5 s in `hello_clipboard` produced 60 `repeat=true` events (the old built-in 25/600 would give about 22); settings restored                                                                                                                                           |
| sub-frame tap                                       | 7    | partial | `wtype -k q` quits `hello_simp` through the event path. The START-bit property has no polling example to observe live; `input_test` covers it                                                                                                                                                                                        |
| sweep                                               | 4, 8 | pass    | `hello_window`, `hello_gl`, `hello_vulkan_dmabuf` (triangle, `0x0200000028a01f04` accepted first), `invaders`, `skeletal_animation`, both GetRect showcases, `treemap`, `codex_view`, `simp_example`, `simp_render_to_texture`, `hello_globals`, `dump_keymap`: all render or print correctly, exit 0, and no module logged an error |

Not exercised: clipboard paste (the clipboard was empty, so the save-and-restore check
was skipped) and the NVIDIA laptop. Example-level nits the run turned up, none of them
regressions: `hello_window` and `hello_gl` parse the keymap once and ignore a mid-session
`keymap` event (so `wtype`'s virtual keyboard, which installs its own keymap, cannot quit
them, while `ydotool` through uinput does; `Wayland_Support` handles the swap); the shared `build/data` symlink is re-pointed by each build, so `invaders`,
`skeletal_animation` and the GetRect examples only run straight from `build/` when they
were built last (`./build.sh - <target>` is unaffected); `hello_dmabuf` prints eight
entries per tranche, all `AB4H`, so the ABGR8888 entries the GL path uses are never shown;
`simp_example` logs `Wanted MSAA: 8` / `Chosen MSAA: 0` on this backend, which is the
single-sample BO-backed FBO by design and a V2 item if MSAA matters.

**Still owed: the NVIDIA laptop.** Capture `hello_globals`'s `zwp_linux_dmabuf_v1` version
and the `Using dmabuf …` line `hello_simp` logs. If the compositor advertises v4 or later,
the global list is empty by protocol, so the June finding "the global-format-list
fallback carries NVIDIA" can only have held on a compositor advertising v3 or lower, or
the tranches worked all along once parsed correctly. Either the corrected tranches now
carry NVIDIA, or the GL path stops at `no GBM-usable ABGR/XBGR 8888 dmabuf format
advertised` and needs a last-resort `ABGR8888` + `DRM_FORMAT_MOD_INVALID` attempt that
requires no advertisement. V2 should drop the global-list fallback in favour of that
last resort, since it is dead code on v4+.

## Live checks (2026-10-31, laptop: X11 and Hyprland 0.57.0, Iris Xe + RTX 3050 Ti)

`nomad-artix`, hybrid graphics: the Intel iGPU drives the panel, the RTX 3050 Ti
(driver 615.78.08) renders on request. Jai beta 0.2.030.

### X11 (i3; NVIDIA through PRIME render offload)

| Check                                 | Item | Result | Evidence                                                                                                                                                                                                                                                                               |
|---------------------------------------|------|--------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 12 test suites                        | 9    | pass   | 139 tests on Jai beta 0.2.030; `gl_picker_test` passes on Intel (an i915 CCS modifier is rejected) and SKIPs on NVIDIA (all 13 `ABGR8888` modifiers single-plane)                                                                                                                      |
| `headless_gl`, both GPUs              | 1    | pass   | NVIDIA rejects native-pixmap import (`0x300c`) and imports by DMA-BUF with modifier `0x300000000e08014`, high word intact                                                                                                                                                              |
| `headless_vulkan(_dmabuf)`, both GPUs | -    | pass   | NVIDIA exports `0x0300000000606015`, Intel `LINEAR`                                                                                                                                                                                                                                    |
| `hello_x11_gl`, both GPUs             | -    | pass   | NVIDIA run maps `libGLX_nvidia`; triangle renders; exit 0 on `WM_DELETE_WINDOW`                                                                                                                                                                                                        |
| Simp stack on X11 (10 examples)       | -    | fixed  | All render on Intel. On NVIDIA every one segfaulted in `create_window`: PRIME offload's 12 GLX visuals include no multisampled one, so `glXChooseVisual` returned NULL for the default 4x MSAA. Upstream bug, also in the pre-backport build; fixed by the 8-4-2-0 step-down (3c1e5dd) |
| sub-frame tap, X11                    | 7    | pass   | A press+release in one XTEST flush opens a GetRect dropdown 4/4 on the current build and 0/4 with both release sites reverted; a slow click opens on both                                                                                                                              |

### Hyprland 0.57.0 (compositing on the Intel iGPU)

| Check                           | Item | Result           | Evidence                                                                                                                                                                                                                                                                                                 |
|---------------------------------|------|------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `hello_globals`, `hello_dmabuf` | 1    | finding          | `zwp_linux_dmabuf_v1` v5, so no global list; one tranche, on Intel's `renderD128` (226:128), offering `LINEAR`, Intel tiled and `INVALID`, no NVIDIA layout                                                                                                                                              |
| Intel sweep (13 programs)       | 4, 8 | pass             | All render and exit 0 on xdg close; the GL slots use `ABGR8888` `LINEAR`, first in Hyprland's tranche; `hello_vulkan_dmabuf` gets Intel tiled `0x0100000000000001` accepted first                                                                                                                        |
| `app_id`                        | 5    | pass             | Every window carries its name as `class`; the pre-backport build's windows have an empty one                                                                                                                                                                                                             |
| `simp_multiple_windows`         | -    | fixed            | Only clear colours showed, in the pre-backport build too. The viewport crop's source rect is post-transform, so it must start at `cap_h - log_h`, not 0; a floated `hello_simp` shrunk to 500x350 lost its quad the same way. Fixed in `wl_update_viewport_crop`                                         |
| NVIDIA client, GL               | 1    | cannot present   | The picker lands on `ABGR8888` `LINEAR`, the only shared layout. NVIDIA's GBM refuses `LINEAR` with `GBM_BO_USE_RENDERING`; allocated without it, the BO imports but its FBO is `GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT` (`0x8cd6`)                                                                        |
| NVIDIA client, Vulkan           | 1    | crashed Hyprland | Hyprland accepted NVIDIA tiled `0x0300000000606015` and, later, advertised `LINEAR`, then aborted (SIGABRT in Mesa iris `dri_create_fence_fd`, from `CEGLSync::create`) on its next frame, three times. `hello_vulkan_dmabuf` now refuses before its first probe when its device is not the compositor's |

**The owed NVIDIA re-test, answered.** Hyprland advertises `zwp_linux_dmabuf_v1` v5, so the
global list is empty by protocol, as predicted. The GL path logs `Using dmabuf surface
feedback for format selection` and picks `ABGR8888` `LINEAR`: the corrected tranches do
offer a format GBM reports as usable, but NVIDIA cannot render into it, so the stop is the
BO allocation, now logged as `BO-backed slot failed: GBM could not allocate ...`, not `no
GBM-usable ABGR/XBGR 8888 dmabuf format advertised`. This is hybrid mode; the June result
was pure-dGPU mode, which this run did not repeat. **The proposed last-resort `ABGR8888` +
`DRM_FORMAT_MOD_INVALID` attempt is dangerous in hybrid mode:** NVIDIA would pick its own
block-linear layout, and handing that to a compositor on another GPU is exactly what
crashed Hyprland. It may only run when the client renders on the compositor's own GPU.

**Hybrid mode needs a copy path, and NVIDIA's own drivers show what it must do.** Our
NVIDIA buffers crashed the Intel-composited Hyprland, but games and `vkcube` presenting
from the same GPU to the same compositor work. With root, the cause separates cleanly. The
kernel logged **no GPU hang** at any of the three crashes; Mesa iris aborted in userspace
(`dri_create_fence_fd`, from Hyprland's `CEGLSync::create`). Crash 1 (NVIDIA tiled
`0x0300000000606015`): Hyprland's log tail shows `eglCreateImageKHR` failing with
`EGL_BAD_MATCH` three times, since Intel's EGL cannot import NVIDIA's layout, yet Hyprland
had answered `created` and carried on into the abort; a client should not be able to do
that to a compositor, so that half is a Hyprland bug. Crashes 2 and 3 (advertised
`LINEAR`): the import succeeded and the same abort followed, consistent with i915 accepting
the layout but being unable to use pages in NVIDIA video memory, where our buffers lived.

What NVIDIA's own window-system code does instead, observed on this laptop:

| Behaviour                              | Evidence                                                                                                                                                                                           |
|----------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Reads the compositor's dmabuf feedback | `vkcube --wsi wayland` on NVIDIA under `WAYLAND_DEBUG=1`: `main_device` and tranche target on every swapchain (re)creation, 12 rounds in one run                                                   |
| Presents `LINEAR` buffers              | Every `zwp_linux_buffer_params_v1.add(fd, 0, 0, 8192, 0, 0)`: modifier 0:0, stride = width x bytes per pixel aligned to 256 (`vkcube` chose `XB4H`)                                                |
| In memory the iGPU can map             | `/sys/kernel/debug/dma_buf/bufinfo` (sudo): each NVIDIA-exported buffer (`exp_name drm`) lists the Intel GPU `0000:00:02.0` as attached; these GPUs have no peer-to-peer, so that is system memory |
| Copies to get there                    | NVIDIA's Vulkan lists no renderable `LINEAR` modifier (0 of 24) and its GL cannot render to `LINEAR`, so the `LINEAR` buffers it presents are a copy of what it rendered                           |
| Uses explicit sync                     | `wp_linux_drm_syncobj_surface_v1.set_acquire_point` / `set_release_point` on every one of 1500 frames                                                                                              |
| Same on its X11 path                   | Order of the Sinking Star (D3D12, vkd3d-proton, NVIDIA Vulkan, via XWayland): 3 NVIDIA-exported 2560x1600x4 buffers, Intel attached twice (XWayland and Hyprland), no `prime-run` needed           |

**The recipe for this library** (`hello_vulkan_dmabuf` first, where it replaces today's
refusal, then the GL path): when the client GPU is not the compositor's main device, keep
rendering into the fast device-local images, then each frame copy into a `LINEAR` image
bound to host-visible, non-device-local memory, export that as the dma-buf with modifier 0,
and pace it with `wp_linux_drm_syncobj` (or at least a fence wait). Verify with
`sudo cat /sys/kernel/debug/dma_buf/bufinfo`: the compositor GPU's PCI address must appear
under the buffer's attached devices. Proton note: Valve's official builds ship no Wine
Wayland driver (`winewayland.drv`; checked in Proton Experimental 11.0-20261027b, and
third-party docs say the same of the others), so `PROTON_ENABLE_WAYLAND=1` only works in
GE-Proton and Proton-CachyOS, and every Proton game here goes through XWayland.

**Step 1 of the recipe, the headless proof, passes** (2026-10-31, `./build.sh -
headless_cross_gpu`, `examples/headless_cross_gpu.jai`; no compositor involved). The
RTX 3050 Ti uploads a pattern that differs at every pixel into a device-local optimal image,
copies it with `vkCmdCopyImageToBuffer` into a `VkBuffer` (linear by construction, so no
`LINEAR` image modifier is needed) whose memory is NVIDIA's type 3 (`HOST_VISIBLE |
HOST_COHERENT`) in heap 1, the non-device-local heap, and exports it with
`vkGetMemoryFdKHR`. The image is 250x130 with rows padded to a 1024-byte pitch, so the
copy's `bufferRowLength` and the importer's pitch are both exercised. Intel's EGL imports
the fd as `ABGR8888` with modifier `LINEAR`, the iGPU samples it in a draw (as a compositor
does, so its GPU reads the pages, not a CPU mapping), and all 32500 pixels read back
right, as does a CPU read of the exported memory. `fdinfo` names the exporter `drm`
(nvidia-drm), and `bufinfo` (root, read from a debugger stopped after the draw) lists
`0000:00:02.0`, the iGPU, as attached, with a signalled read fence from its draw: the same
picture as `vkcube`'s frames above. Three details the proof turned up:

- **System memory is a heap property on a dGPU, and the opposite on an iGPU.** A memory
  type's own `DEVICE_LOCAL` bit does not exclude VRAM: NVIDIA's type 5 is resizable-BAR,
  host-visible and device-local at once. So the test requires a heap without
  `DEVICE_LOCAL`. An integrated GPU flags every heap device-local although all of its
  memory is system memory, so for it any type qualifies.
- **The read must be a sample, not a framebuffer attachment.** A blit's read side
  attaches the import to a framebuffer, which NVIDIA refuses for `LINEAR`
  (`GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT`). A compositor only samples client buffers.
- **The reverse direction (Intel renders, NVIDIA imports) stops at the sampler.** Intel
  exports from its own memory (`exp_name i915`) and NVIDIA's EGL imports the fd, but lists
  `LINEAR ABGR8888` as external-only: it can be sampled only as
  `GL_TEXTURE_EXTERNAL_OES`, which a desktop-GL `GL_TEXTURE_2D` sampler cannot declare
  (`GL_INVALID_OPERATION` at `glEGLImageTargetTexture2DOES`). The test SKIPs there, naming
  the reason. A compositor on NVIDIA has to sample such buffers as external textures.

**Step 2, the Vulkan path, presents across GPUs** (2026-10-31, `hello_vulkan_dmabuf`).
Its refusal is gone: when the Vulkan device is not the compositor's main device, or that
cannot be established, it presents through the copy path and never probes. It picks a
format the compositor advertises with `LINEAR` and gives each slot a device-local optimal
render target plus a system-memory `VkBuffer`, rows padded to 256 bytes, exported as the
dma-buf. Every frame renders into the target, copies it into the buffer, releases the
buffer to the foreign queue family and waits for the queue. Before reusing a slot it polls
the dma-buf fd for `POLLOUT`, which waits out the read fences i915 attaches, because a
`wl_buffer.release` does not mean the compositor's GPU has finished reading.
`--copy-path` forces the path on the compositor's own GPU. It was validated in three
stages, each riskier than the last:

| Stage                                      | Result                                                                                                                                                    |
|--------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------|
| Intel, `--copy-path`, live Hyprland        | Same GPU, so almost no risk; animating, correct, resize rebuilt the slots, clean close                                                                    |
| RTX 3050 Ti, nested Hyprland (on the iGPU) | Same binary and Mesa iris path that crashed three times; 600 bounded frames plus an interactive run, correct triangle, nested compositor alive throughout |
| RTX 3050 Ti, live Hyprland                 | Correct and animating; a float and five resizes (16 slot allocations), no warnings, no read-fence timeouts, Hyprland alive                                |

In both NVIDIA stages `bufinfo` showed each buffer exported by `drm` with `0000:00:02.0`
attached and read fences from the Hyprland process on it, the same picture as NVIDIA's own
WSI. With nothing else changed, Intel without the flag still takes the driver-first path
(Intel tiled `0x0100000000000001` accepted).

**Step 3, the GL path, presents across GPUs** (2026-10-31, `Wayland_Support`). This also
closes the gap noted above, where the GL path was only safe because NVIDIA's BO allocation
happened to fail. Before allocating any slot, `wl_window_init_gl` checks that the GL
render node is the compositor's main device: major:minor first, then the PCI device behind
`/sys/dev/char/M:m/device`. If it is not, the window presents through a `wl_shm` readback.
Each slot is a texture FBO plus memfd shm (`ARGB8888`), and every present `glReadPixels`es
the logical region into it, rows in GL order, so the flip and the crop are unchanged. A
compositor without `zwp_linux_dmabuf_v1` gets the same path, and `JAI_WAYLAND_COPY_PATH=1`
forces it. GL has no portable way to write into a system-memory dma-buf (NVIDIA cannot
render into, or attach to a framebuffer, a `LINEAR` import), so the readback is the
portable choice. It costs one GPU -> CPU copy per frame; zero-copy would need GL/Vulkan
memory interop. Live on Hyprland 0.57, forced onto the RTX 3050 Ti
(`JAI_WAYLAND_GPU_VENDOR=nvidia`):

| Example                  | Result                                                                |
|--------------------------|-----------------------------------------------------------------------|
| `hello_simp`             | Animating; quad centred after floating shrinks to 500x350 and 900x700 |
| `invaders`               | Animating                                                             |
| `skeletal_animation`     | Depth-tested mesh and UI correct, animating                           |
| `getrect_example`        | Widgets, text and colour picker upright and correct                   |
| `getrect_lh_example`     | Renders                                                               |
| `treemap`                | Renders                                                               |
| `codex_view`             | Renders                                                               |
| `simp_example`           | Animating                                                             |
| `simp_multiple_windows`  | Both windows (6 readback slots), animating                            |
| `simp_render_to_texture` | Animating                                                             |

Every run exited 0 through the compositor's close, with no errors logged, and Hyprland
stayed up throughout. Intel by default still takes the BO-backed dma-buf path
(`ABGR8888`, `LINEAR`), and all 140 tests pass.

**Fixed along the way:** slot initialisation logs why it failed, and a failed GL bring-up
exits with an error instead of drawing into no framebuffer while `hello_simp` claimed a
clean run; `hello_simp` counts logged errors and exits 1 if there were any, and it quits on
`Event.QUIT`, so an X11 window-manager close works.

**Explicit sync, both paths** (2026-10-31, `docs/plans/2026-10-31-explicit-sync-design.md`).
The recipe's last item, "pace it with `wp_linux_drm_syncobj`", is done. Each dma-buf commit
now carries an acquire point and a release point on a per-slot DRM timeline: one timeline
per slot, commit n at points 2n-1 and 2n. The GL path's acquire fence is an EGL native
fence, and `hello_vulkan_dmabuf`'s is a `SYNC_FD` export of the submit's semaphore. A slot
is reused only when its release point signals, since the protocol makes `wl_buffer.release`
undefined, and that also replaces the copy path's `POLLOUT` read-fence wait. Measured with
a throwaway timing patch, then reverted: Simp's end-of-frame CPU wait on the Iris Xe fell
from 3.2-4.1 ms (`glFinish`) to 0.13-0.17 ms, with no release-point wait in 1440 frames.
Live on Hyprland 0.57:

| Run                                                  | Result                                                                                              |
|------------------------------------------------------|-----------------------------------------------------------------------------------------------------|
| Nine Simp examples, Intel                            | All rc 0, frames correct, explicit sync on in every log                                             |
| `hello_simp`, six floated resizes, 5 s hidden        | Two slot reallocations (retire and reap by release point); alive while hidden; animating after      |
| `simp_multiple_windows`, Intel                       | Both windows on explicit sync, B cycling colours, clean close                                       |
| `hello_vulkan_dmabuf`, Intel driver-first (tiled)    | Resizes, hidden workspace, 600 bounded frames: rc 0, no warnings                                    |
| `hello_vulkan_dmabuf --copy-path`, Intel             | Same                                                                                                |
| `hello_vulkan_dmabuf`, RTX 3050 Ti (copy path)       | Same; `bufinfo` shows both NVIDIA-exported buffers attached to `0000:00:02.0`, Hyprland read fences |
| `JAI_WAYLAND_EXPLICIT_SYNC=0` / `--no-explicit-sync` | The previous `glFinish` / queue-wait paths, rc 0                                                    |

The nested-Hyprland sandbox could not be used for this. A nested Hyprland runs on the
Wayland backend and does not advertise `wp_linux_drm_syncobj_manager_v1`, so every
explicit-sync run went straight to the live instance; the nested one exercised the
fallback instead. Every buffer commit there is the one NVIDIA's own driver already makes
on this laptop.

**dGPU-only boot, same day.** The MUX takes the iGPU off the PCI bus, so the RTX 3050 Ti
is the only GPU (`renderD128`, `nvidia-drm` 615.78.08) and Hyprland 0.57 composites on it.
The compositor advertises `zwp_linux_dmabuf_v1` v5, so the global format list is empty, and
its one feedback tranche, on its own device, offers `AB24` with NVIDIA's block-linear
modifiers `0x0300000000606010`-`…15` plus `INVALID`. The June note that NVIDIA's tranches
offer no GBM-usable ABGR/XBGR format was the modifier parse dropping each modifier's high
word: with it fixed, the GL path picks `ABGR8888` `0x0300000000606010` from the surface
feedback (`Using dmabuf surface feedback for format selection`), and on a v5 compositor the
global-list fallback has nothing to offer. The full suite passes on this box (155 PASS;
`gl_picker_test` SKIPs because NVIDIA's 13 ABGR8888 modifiers are all single-plane).
The same timing patch, reverted after: 3.0-3.6 ms in `glFinish` became 0.14-0.16 ms, and
the vsync wait absorbs the difference (`hello_simp` is vsync-capped at ~16.5 ms a frame
either way).

| Run (dGPU-only)                                      | Result                                                                                       |
|------------------------------------------------------|----------------------------------------------------------------------------------------------|
| `hello_simp`, `skeletal_animation`, NVIDIA GL BO     | rc 0, frames correct, explicit sync on, three BO slots on `0x0300000000606010`               |
| Eight more Simp examples and `hello_clipboard`       | All rc 0 on a compositor close, frames correct, explicit sync on (both windows of the multi) |
| `hello_simp`, six floated resizes, 5 s hidden        | Three slot reallocations, new timelines each; alive while hidden; animating after            |
| `hello_vulkan_dmabuf`, driver-first                  | First candidate `0x0300000000606015` accepted, explicit sync on, 600 frames, rc 0            |
| `JAI_WAYLAND_EXPLICIT_SYNC=0` / `--no-explicit-sync` | The `glFinish` / queue-wait paths, rc 0, frames correct                                      |
| `JAI_WAYLAND_COPY_PATH=1`                            | The `wl_shm` readback on the compositor's own GPU, rc 0, frames correct                      |

**`simp_multiple_windows` froze on the panel, same day.** The user saw it flicker and
stutter (B's colour jumping, A's quad not turning) while every recording looked perfect.
Read straight from the scanout with `kmsgrab`, the panel cycled three frozen images, one
per Hyprland output buffer, for the whole run. Cause: Hyprland 0.57's
`CWLSurface::computeDamage` intersects a surface's damage with its viewport source rect
without subtracting the rect's origin. Our crop started at `y = cap_h - log_h` (the
bucketed height under `FLIPPED_180`), so once that offset reached the window's height the
damage was empty and Hyprland stopped repainting it, while still sending frame callbacks.
Opening B shrinks A from full height to 618 with a 1280-row capacity, so the example froze
from startup; a floated `hello_simp` froze after a shrink. A screencopy session renders
fresh and forced a full repaint, which is why `grim`, `wf-recorder` and the user's capture
never showed it. Fixed by bucketing only the width: the capacity height is now the logical
height, so the source starts at row 0 (`wl_target_capacity`, `wl_capacity_needs_realloc`,
with `pacing_test`'s new capacity test).

| Real scanout (~226 frames)          | Distinct images |
|-------------------------------------|-----------------|
| two windows, before                 | 3               |
| two windows, explicit sync off      | 3               |
| two windows, viewport crop disabled | 209             |
| `hello_simp`, never resized         | 210             |
| `hello_simp` shrunk, before         | 31              |
| two windows, after                  | 212             |
| `hello_simp` shrunk / grown, after  | 212 / 211       |
| two windows, shm readback, after    | 213             |
| two windows under XWayland          | 212             |

After the fix the quad's rotation on the scanout matches XWayland's (median step 0.96 vs
0.98 degrees a frame); both show a few backward steps only in the first half second.

**X11 in dGPU-only mode, same day** (i3 on XLibre, NVIDIA's own X driver, no PRIME).
`glxinfo` lists 132 GLX visuals, 96 of them multisampled (24 each at 2, 4, 8 and 16
samples), where PRIME offload listed 12 with none, so the MSAA step-down (`3c1e5dd`) never
fires: each Simp window's visual has the sample count it asked for (`DEFAULT_MSAA` is 4;
`simp_example` asks for 8 and gets 8), and no `no GLX visual` warning is logged.

| Run (X11, dGPU-only)                          | Result                                                                                                                                                                                               |
|-----------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `x11_smoke`, `hello_x11_gl`                   | rc 0, triangle renders, `ldd` lists only libc                                                                                                                                                        |
| Ten Simp examples, `hello_clipboard` included | All render and map `libGLX_nvidia`; visual `0x39` (4 samples) for nine, `0x43` (8) for `simp_example`; rc 0 on an i3 close (`WM_DELETE_WINDOW`), both windows of the multi, except `hello_clipboard` |
| `hello_clipboard`, fixed                      | Ignored the close: it read only `Simp.window_should_close`, which answers for Wayland windows only. Now quits on `.QUIT` as `hello_simp` does; `c` read back by `xclip`, `xclip`'s text pasted, rc 0 |
| `skeletal_animation`, mouse camera            | After ESC, horizontal pointer motion yaws the camera and vertical motion pitches it; rc 0                                                                                                            |
| `hello_simp`, floated resizes through i3      | 900x700, 1600x1100, 500x350 all applied, quad centred at each, no warnings, rc 0                                                                                                                     |

`hello_clipboard`'s miss dates from the example's first commit (`b019369`), which was only
ever closed through a Wayland compositor; it is not a regression from the backport.

**Tooling notes for X11:** these windows set no `_NET_WM_PID`, so `xdotool getwindowpid`
finds nothing; find the program as the descendant of `./build.sh` whose `/proc/<pid>/exe`
is under `build/`. It is a grandchild (`build.sh` -> `jai-linux` -> the program, through
`Autorun`), so killing `build.sh`'s direct child on a hang orphans it with its window up;
kill the whole tree. ImageMagick, `scrot` and `maim` are absent on the laptop:
`ffmpeg -f x11grab -video_size WxH -i :0.0+X,Y -frames:v 1` grabs a window from its
`xwininfo` geometry.

**Tooling notes for this compositor:** Hyprland 0.57's Lua `hyprctl dispatch` runs
dispatchers (`hl.dsp.window.close({ window = "address:..." })`, `hl.dsp.window.float`,
`hl.dsp.window.resize({ x = ..., y = ..., window = ... })`); a bare `hyprctl eval` of one
returns `ok` and does nothing. A shell that outlives a compositor restart (herdr) keeps a
stale `HYPRLAND_INSTANCE_SIGNATURE`.

## Live checks (2026-11-01, desktop: i3/X11 and a nested Weston, AMD RX 7900 GRE)

`godlike-artix`, one GPU (render node 226:128, primary `card1`), i3 on XLibre, Jai beta
0.2.030, master `7614149`: the laptop's 22 commits since `aaf1b8a`, run on AMD for the
first time. Nothing in them failed here, and no code changed. With no Wayland session up,
a nested Weston 15.0.1 (X11 backend) stood in for the compositor. It advertises
`zwp_linux_dmabuf_v1` v5 with feedback (main device 226:128, one tranche of 406 formats)
and `wp_viewporter`, but not `wp_linux_drm_syncobj_manager_v1`.

| Check                                                                           | Result        | Evidence                                                                                                                                                                                                                     |
|---------------------------------------------------------------------------------|---------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 14 test suites                                                                  | pass          | 157 tests. `syncobj_test` runs all 11 on radeonsi, the GL native fence included (the laptop covered Intel and NVIDIA); `gl_picker_test` runs instead of skipping and rejects radeonsi's multi-plane DCC `ABGR8888` modifiers |
| `headless_gl`, `headless_vulkan(_dmabuf)`                                       | pass          | The BO-backed FBO reads back `(51, 153, 204, 255)`; RADV exports `0x0200000028a6bf04`                                                                                                                                        |
| `headless_cross_gpu`                                                            | skip          | By design on one GPU: `Vulkan device 0 … is the importer's GPU; skipped`                                                                                                                                                     |
| `x11_smoke`, `hello_x11_gl`                                                     | pass          | `ldd` lists only libc; the triangle animates (60 distinct images in a 2 s capture at 30 fps); rc 0 on an i3 close                                                                                                            |
| Simp stack on X11 (10 examples and `hello_clipboard`)                           | pass          | All render; animated ones give 60 distinct images in 2 s, static UIs 1; rc 0 on `i3-msg kill` (`WM_DELETE_WINDOW`), both windows of the multi, `hello_clipboard` included (`9241696`)                                        |
| MSAA step-down on X11 (`3c1e5dd`)                                               | not triggered | Mesa's GLX has multisampled visuals: `simp_example` logs `Wanted MSAA: 8` / `Chosen MSAA: 8` and no `no GLX visual` warning                                                                                                  |
| `hello_simp` on Weston, 600 frames                                              | pass          | `Using dmabuf surface feedback`; `ABGR8888` with `DRM_FORMAT_MOD_INVALID` from Weston's tranche (Hyprland 0.56.2's gave the tiled `0x0200000028a01f04`); three BO-backed slots; 600 frames in 10.6 s; rc 0                   |
| `hello_simp`, `JAI_WAYLAND_COPY_PATH=1`                                         | pass          | The `wl_shm` readback (`3dffebb`) on AMD: three slots at 1024x600 (width bucketed, height exact); 60/60 distinct images; rc 0                                                                                                |
| `hello_vulkan_dmabuf`, 600 frames                                               | pass          | `Compositor main device 226:128; Vulkan device primary 226:1 render 226:128 -> same GPU`; the driver-first probe has `0x0200000028a01f04` accepted first; rc 0                                                               |
| `hello_vulkan_dmabuf --copy-path`                                               | pass          | `memory type 2 (system memory) modifier=LINEAR`, stride 2560, so the rule that skips `DEVICE_LOCAL` heaps holds on a resizable-BAR card; 60/60; rc 0                                                                         |
| Explicit sync                                                                   | not exercised | Nested Weston does not advertise the global; both paths log the reason and fall back (`glFinish`, waiting for the GPU)                                                                                                       |
| `hello_gl`, `hello_window`, nine upstream examples, `hello_clipboard` on Weston | pass          | All present and render; animated ones 60/60; no module logged an error. Stopped with SIGTERM after the capture: Weston has no close binding, and the examples do not handle Alt+F4 themselves                                |
| `hello_globals`, `hello_dmabuf`, `hello_screens`, `dump_keymap` on Weston       | pass          | rc 0; evdev 16 decodes to `q` / `Q`                                                                                                                                                                                          |
| Linkage                                                                         | pass          | None of the 29 binaries in `build/` links `libX11`, `libxcb`, `libGL`, `libGLX`, `libEGL`, `libgbm`, `libvulkan` or `libwayland-client`                                                                                      |

Not exercised: explicit sync, Wayland resizes, and the Hyprland 0.57 freeze workaround
(exact slot height). They need a DRM-backed Hyprland and `tools/kmscheck.sh`, and ran on
2026-11-03 (next section).

Found, none of it from the pull:

- An upstream example killed by a signal the Jai runtime does not catch made `./build.sh`
  exit 255 with no message. `build_and_run_upstream_example` did `exit(result.exit_code)` on
  `run_command`'s result, whose exit code is -1 for a signal; our own targets go through
  `Autorun`, which names the signal. Reproduced on `invaders`: SIGTERM and SIGABRT (the
  signal of a C library's `abort()`, a Mesa assert for one) each gave rc 255 and nothing
  in the log. A segfault was never silent: the runtime catches SIGSEGV, prints
  `Segmentation fault` with a stack trace and exits 1. **Fixed the same night:** any end
  other than exit 0 is now logged, as Autorun does. A signal logs
  `[first.jai] invaders quit due to signal N.` and exits 128 + N (SIGTERM 143, SIGABRT
  134), a non-zero exit logs `exited with code N` and keeps the code, and an i3 close still
  exits 0 with no message. 157 tests pass and the nine upstream targets still build under
  `compile_only` without running.
- CLAUDE.md, AGENTS.md, README.md and `build.sh` still named beta 0.2.029, though both
  machines ran this round on 0.2.030; the stamp moved with this record.
- `simp_example` gets no MSAA on Wayland (`Chosen MSAA: 0`, the single-sample slot FBOs).
  The 2026-10-26 section above records it; CLAUDE.md's known gaps now list it too.

**Tooling notes for this desktop:** `weston --backend=x11 --width=1600 --height=1000
--socket=wayland-jw --idle-time=0` (Artix `world` repo, installed 2026-11-01), its window
floated in i3, clients run with `WAYLAND_DISPLAY=wayland-jw`, which is all
`running_wayland()` checks. i3 runs no X compositor, so an `x11grab` of Weston's window
reads the pixels Weston presented and would show a client it had stopped repainting, as
`kmsgrab` does on Hyprland; count distinct images with `ffmpeg … -t 2 -f framemd5 -`.
`xwininfo` is absent here too; `xdotool getwindowgeometry --shell` gives the geometry. With
`./build.sh`'s output redirected to a file, `[Autorun] Running:` arrives only when the
compiler exits, after the program's own output, so wait for the program's process (the
descendant whose `/proc/<pid>/exe` is under `build/`), not for that line.

## Live checks (2026-11-03, desktop: Hyprland 0.57.0, AMD RX 7900 GRE, two monitors)

`godlike-artix`, one GPU (render node 226:128, primary `card1`), kernel 7.2.14, Jai beta
0.2.030, master `e3d8caa`. DP-2 is 2560x1440 at 75 Hz; HDMI-A-1 is 1920x1200 at 75 Hz, rotated
(`transform=3`). This is the check the 2026-11-01 section could not do: Hyprland advertises
`wp_linux_drm_syncobj_manager_v1`, so explicit sync ran on AMD for the first time, and 0.57 is
the version with the viewport-damage bug. No library code changed; the only bug found was in
`tools/kmscheck.sh` (below). Scanout results are read with `kmsgrab` through VAAPI at 60 Hz.

| Check                     | Result | Evidence                                                                                                                                                                                                                                                                                                                                          |
|---------------------------|--------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 14 test suites            | pass   | 157 tests; `gl_picker_test` runs rather than skipping                                                                                                                                                                                                                                                                                             |
| Compositor                | pass   | `zwp_linux_dmabuf_v1` v5, main device 226:128, one tranche of 96 formats; `hello_globals`, `hello_dmabuf`, `hello_screens` (two distinct outputs), `dump_keymap` rc 0                                                                                                                                                                             |
| Explicit sync, GL         | pass   | `explicit sync on (wp_linux_drm_syncobj_v1): GL fences instead of glFinish`; `ABGR8888` `0x200000028a01f04`; no warnings                                                                                                                                                                                                                          |
| Explicit sync, Vulkan     | pass   | `Explicit sync: on (… SYNC_FD semaphores, timelines on the render node)`; `same GPU`; driver-first has `0x0200000028a01f04` accepted first; rc 0, also with `--no-explicit-sync`                                                                                                                                                                  |
| 14 windowed examples      | pass   | `hello_gl`, `hello_vulkan_dmabuf`, `hello_simp`, `invaders`, `skeletal_animation`, `simp_example`, `simp_render_to_texture`, `simp_multiple_windows` LIVE; `hello_window`, `hello_clipboard`, both GetRect showcases, `treemap`, `codex_view` steady; each rendered correctly and exited 0 on a compositor close, or `q` for the two raw examples |
| Forced copy paths         | pass   | `JAI_WAYLAND_COPY_PATH=1`: readback slots, LIVE, also both windows of the multi. `hello_vulkan_dmabuf --copy-path`: `memory type 2 (system memory) modifier=LINEAR`, explicit sync on, LIVE                                                                                                                                                       |
| Resizes                   | pass   | `hello_simp` floated and shrunk to 500x350, grown to 1600x1100; five more Simp programs floated at 900x700: frames correct. Three resizes each on both Vulkan paths, `--no-explicit-sync`, `hello_gl`, `hello_window` and the readback path: rc 0, no warnings                                                                                    |
| Reallocation              | pass   | Slot inits across just the last resize: width 1000 to 800, 800 to 1000, and 1000 to 1100 at the same height, 12 -> 12 (capacity already 1280 from the tiled size, grow-only); height 700 to 500, 12 -> 15                                                                                                                                         |
| Hidden window             | pass   | `hello_simp` 5 s on a hidden workspace and back: LIVE, no warnings. Two windows with B hidden: A stays LIVE (221 of 235). B hidden 6 s and back: both LIVE, top 221 and bottom 162 distinct                                                                                                                                                       |
| Keyboard                  | pass   | Sub-frame tap registers; Shift gives `A`; Ctrl gives no text; a key held 2 s gives 36 repeats (25/s after 600 ms predicts about 35)                                                                                                                                                                                                               |
| Clipboard                 | pass   | `c` read back by `wl-paste`; `wl-copy` text pasted with `p`; `c` then `p` reads its own selection without deadlock                                                                                                                                                                                                                                |
| Pointer                   | pass   | A click at surface (300, 500) on `hello_window` logs `(300, 500)`; in `getrect_example` a click toggles a checkbox and typed keys land at the click position in a text field; `invaders`' ship follows the arrow key                                                                                                                              |
| X11 path through XWayland | pass   | 11 Simp-stack programs, `hello_x11_gl` and `x11_smoke`: render, animated ones LIVE, rc 0 on a compositor close; `simp_example` `Wanted MSAA: 8` / `Chosen MSAA: 8`; no Wayland path in any log                                                                                                                                                    |
| Leaks                     | pass   | 30 s soaks of `hello_simp` (explicit sync on and off) and `hello_vulkan_dmabuf`, plus 30 resizes on the explicit and copy paths of both (`hello_simp`: 99 slot inits): file descriptors flat (10-12), RSS stable, rc 0, no warnings                                                                                                               |

**The freeze fix, with a control** (`5ad9525` reverted in a throwaway worktree). The bug
reproduces on AMD, the fix cures it, explicit sync is unrelated, and `kmscheck` tells them apart:

| Real scanout (about 235 frames)   | Distinct images                | Verdict |
|-----------------------------------|--------------------------------|---------|
| two windows, current              | 221 (top half 221, bottom 166) | LIVE    |
| two windows, explicit sync off    | 221 (top half 221, bottom 159) | LIVE    |
| two windows, shm readback         | 220 (top half 220, bottom 154) | LIVE    |
| `hello_simp` shrunk to 500x350    | 220                            | LIVE    |
| two windows, fix reverted         | 3 (top half 3, bottom 3)       | FROZEN  |
| two windows, reverted, sync off   | 3                              | FROZEN  |
| `hello_simp` shrunk, fix reverted | 26                             | PARTIAL |

A fairly fixed number of each capture's frames repeat an earlier image however long it runs (21
of 180, 14 of 235, 23 of 360), and consecutive frames almost always differ, so that looks like
the capture starting up, not missed frames. The bottom window's lower count is probably its
slow colour change; its count under the reverted fix is what matters.

**End-of-frame CPU wait** (throwaway timing patch around `wl_finish_frame`, 240-frame averages,
window 1192x1884). About 3-4 times shorter and less sensitive to the frame's work, but small in
absolute terms: `glFinish` was already cheap on this card, where the Iris Xe's was 3-4 ms.

| Program              | Explicit sync on | `glFinish`   |
|----------------------|------------------|--------------|
| `hello_simp`         | 0.05-0.07 ms     | 0.17-0.18 ms |
| `skeletal_animation` | 0.10 ms          | 0.29-0.30 ms |
| `getrect_example`    | 0.12-0.14 ms     | 0.50-0.51 ms |

**`kmscheck` blanked the screen.** Its first runs here made Jim's terminal flash, content to
black to content, about ten times per run, soon after each window appeared. Its capture went
through `hwmap=derive_device=vulkan`, which on this card reads solid black and blanks the live
buffer. A second reader on VAAPI watched the side monitor's plane while the Vulkan path read
the same plane:

| Side monitor's plane, watched through VAAPI | Watcher saw                                                        |
|---------------------------------------------|--------------------------------------------------------------------|
| idle wallpaper, no Vulkan capture           | 0 black frames of 180                                              |
| idle wallpaper, Vulkan capture from 1.5 s   | black from frame 114 to the end of the capture (246 of 360 frames) |
| `hello_simp`, no Vulkan capture             | 0 black frames of 180                                              |
| `hello_simp`, Vulkan capture from 1.5 s     | 3 black frames as it started                                       |

The Vulkan reader itself got 180 black frames of 180 both times. The scanout modifier is
`0x200000028a67f04`. Why it happens is unproven; resetting compression metadata on import is a
guess. Windows on workspace 7, read through VAAPI, gave no flashing, and neither did the
two-window test beside the terminal with no capture running, so resizing the terminal was not
the cause. `kmscheck` now reads through VAAPI except on NVIDIA.

Other `kmscheck` fixes from the same runs: it read the first plane with a framebuffer, which
here was the other monitor (a box that fit read `STATIC` from the wrong screen); it now follows
the windows' monitor, takes `--plane`, and refuses `--region` without `--plane` on two monitors.
A rotated monitor's plane is not in layout coordinates, so it captures all of that plane. It
closed any new window, so it now only touches windows whose process runs from the repo's
`build/`. And an unchanging picture can read as two images cycling: the three output buffers
differed in 3082 of 576,000 pixels, by at most 4 levels of 255, identically under different
programs and not in every run. That looks like compositor noise, though its source was not
pinned down. Images differing in under 1% of their bytes now count as one, and the reverted
fix still reads FROZEN with that rule in place.

Not exercised: drag-and-drop (Jim can test it with PCManFM: `./build.sh - getrect_example`, then
drop a file on it), `skeletal_animation`'s mouse camera on Wayland, touch (no device), the
Vulkan path's wait time, and `kmscheck`'s new code on NVIDIA and Intel. The plane and rotation
logic is new there, and Intel's Vulkan path has never been run.

**Reported by Jim, not investigated:** the laptop's trackpad registers no input events, while
its touchpoint works like a mouse. Not established: whether that is only in these examples, and
on which backend. A touchpad normally reaches a Wayland client as `wl_pointer` through the
compositor, not `wl_touch`, so the untested touch path does not explain it.

**Tooling notes for this desktop:** a session here may run inside `herdr` with another Claude
beside it. Workspace 7 (HDMI-A-1) is visible and usually empty, and
`hyprctl dispatch 'hl.dsp.exec_cmd("/path/launch.sh", { workspace = "7 silent" })'` opens there
without moving focus or resizing the terminal, but only the first window a launch opens follows
the rule. Workspaces 1-6 are on DP-2 and 7-10 on HDMI-A-1, so moving a window to 8 takes it to
the other monitor. `hl.dsp.cursor.move({ x = ..., y = ... })` takes global coordinates.
`wl-copy` keeps the caller's stderr, so `script 2>&1 | cut` never finishes: give it
`>/dev/null 2>&1`. Save the clipboard before a copy test; it may hold Jim's data.

## V2 invariants

Each line names the failure it prevents.

1. One drain, nothing dropped: every roundtrip goes through the one router with a stop predicate, and a drain body either handles a message or routes it. Prevents foreign messages (and their fds) vanishing during a roundtrip.
2. The router can pop fds for events on objects it no longer tracks (needs a per-object interface registry plus a generated per-opcode fd-count table). This is the gap V1 leaves in the router: a message no record owns is dropped with its fds unpopped (for example a FORMAT_TABLE for a just-destroyed feedback object), which leaks the fds.
3. An app-turn exit from a vsync wait is not starvation. Prevents a window being flagged starved, and skipped, only because the app yielded.
4. A late `done` for any callback id we allocated heals starvation and recycles the id, with oldest-first eviction at the cap. Prevents a starved window staying starved forever and ids leaking.
5. A release preserves START, so a press and release inside one frame still reads as pressed this frame. Prevents dropped taps.
6. Globals bind by compositor name, never by first interface match. Prevents every `wl_output` / `wl_seat` aliasing the first one.
7. A poisoned batch is never sent; a short send completes or fails loudly without resetting; truncated control data is a dead connection. Prevents a half-written or fd-less message corrupting the stream.
8. A drain handles every event of its own object, not only the one it waits for (the lost `repeat_info` and the initial selection offer were both this). Prevents silently lost initial state.
9. Library code returns errors rather than dying: `sendmsg` with `MSG_NOSIGNAL`, so a closed peer is an error, not SIGPIPE (V1 does this since d18d004).

Design note: the capped orphan list (invariant 4) duplicates what `wl_frame_cache` already knows. A `WL_CALLBACK_DONE` for any id that is live in that window's frame cache and is not the pending one is an abandoned callback, so V2 can match on the cache directly, with no cap and no evicted ids.

## Deferred (noted during the backport)

- `session.jai`'s `wayland_send(batch, drain=true)` overload ignores the receive result and discards what it reads, fds included (only `hello_window` uses it).
- `wl_keyboards[0].keymap` goes stale after a mid-session KEYMAP (only `wl_keymap` is updated). (The re-parse's failure logging, once gated on key logging, landed in d18d004.)
- `get_screens_info` never releases its `wl_output` proxies, so their later events reach the router and are dropped (no fds); `wl_output_cap` caches its first answer for the process life, so a larger hot-plugged monitor never raises the cap.
- The current-selection `data_offer` that arrives during `get_data_devices_info` is dropped (the "we don't support paste yet" comment there is stale).
- `wl_registry_bind` overload 4 has no interface-name mismatch guard; `wl_route_registered_window_control_event` duplicates the router's configure/close branches.
- The router's orphan-callback branch has no headless test. One is feasible: put a stack window in `wayland_global_windows`, `cache_alloc` an id, orphan it, route a fake opcode-0 header on that id, and assert it was routed, starvation cleared, and the cache entry no longer live. The `MSG_CTRUNC` path has none either (a 29-fd `sendmsg` over a socketpair would pin it).
- The libwayland_shim's long-lived batch stays poisoned after one overflow. (`wayland_receive`'s `EINTR` retry and logging of every lost-connection cause, and `MSG_NOSIGNAL` on `sendmsg`, landed in d18d004.)
- The sibling project's 15 Input translation tests were not ported (audit item 9): they belong with V2's restructured Input module.
- `get_dmabuf_info` binds `zwp_linux_dmabuf_v1` at the descriptor version, 5, and from version 4 the compositor must not send the `format` / `modifier` events, so on a v4+ compositor the "global list" (`Dmabuf_Info.supported`) is empty. This bears on the NVIDIA story in CLAUDE.md, which says the global-list fallback carries NVIDIA; re-read it alongside the NVIDIA re-test.
- The keyboard `enter` / `modifiers` and pointer `enter` events in the acquisition burst are dropped, so focus reads false until the window is refocused. V2 invariant 8 covers it.
- `append_feedback_format_table` returns silently when its mmap fails.
- Frame-callback ids evicted from the orphan list at the cap stay live in `Id_Cache`, so they are never recycled.
- The receive `cmsg_buf` is sized for `MAX_FDS_OUT` while the buffers' `MFDS` is polymorphic. A `ReceiveBuffer` with a larger `MFDS` still gets at most `MAX_FDS_OUT` fds per read (more is `MSG_CTRUNC`), and the send side has the sharper form: `wayland_send` copies `out_fds_count` fds into its `MAX_FDS_OUT`-sized `cmsg_buf`, so a `MessageBuilder` with `MFDS > MAX_FDS_OUT` would overrun it. Library code uses the defaults (only `wire_test` instantiates a smaller `ReceiveBuffer`).
