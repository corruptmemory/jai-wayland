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

| Item | Disposition                | Note                                                                                                                                |
|------|----------------------------|-------------------------------------------------------------------------------------------------------------------------------------|
| 1    | landed in 5e79328          | The DRM modifier keeps its high word when decoded. The NVIDIA re-test is still owed (the CLAUDE.md caveat records it).              |
| 2    | landed in 69fb7fa          | Every `wl_output` / `wl_seat` global is bound by its compositor name, not the first interface match.                                |
| 3    | landed in e162d07, e54cbe9 | An app-turn exit is not starvation; a late callback heals it; the orphan take keeps order so the cap evicts the oldest.             |
| 4    | landed in ce5ce3f, e9a926a | One router; foreign messages are routed during roundtrip drains instead of dropped.                                                 |
| 5    | landed in f1499da          | `app_id` is set on toplevels.                                                                                                       |
| 6    | landed in f1499da, fc7190e | The keymap is parsed on arrival (plus the initial `repeat_info`); `NO_KEYMAP` is a warning, not an error.                           |
| 7    | landed in f1499da          | A release preserves `START`, so a press and release inside one frame still reads as pressed.                                        |
| 8    | landed in 82ea4ae, 46891e3 | Connection-layer checks; short sends complete or fail loudly; truncated control data is fatal.                                      |
| 9    | landed across the above    | New suites `dmabuf_test` (3), `registry_test` (2), `pacing_test` (2), `input_test` (3); `wire_test` 22 to 29. 131 tests, 11 suites. |
| 10   | deferred to V2             | Per-window output tracking belongs with the V2 registry design.                                                                     |
| 11   | deferred to V2             | Compositor `main_device` to render-node choice belongs with the V2 GPU selector.                                                    |
| 12   | deferred to V2             | Pointer capture needs the V2 input sink.                                                                                            |
| 13   | deferred to V2             | libxkbcommon via dlopen is a V2 addition.                                                                                           |
| 14   | deferred to V2             | The SRGB `VkFormat` choice in `hello_vulkan_dmabuf` is not touched.                                                                 |
| 15   | deferred to V2             | The X11-arm resize flash is not touched.                                                                                            |

## V2 invariants

Each line names the failure it prevents.

1. One drain, nothing dropped: every roundtrip goes through the one router with a stop predicate, and a drain body either handles a message or routes it. Prevents foreign messages (and their fds) vanishing during a roundtrip.
2. The router can pop fds for events on objects it no longer tracks (needs a per-object interface registry plus a generated per-opcode fd-count table). This is the one gap V1 still has: a message no record owns is dropped with its fds unpopped (for example a FORMAT_TABLE for a just-destroyed feedback object), which leaks the fds.
3. An app-turn exit from a vsync wait is not starvation. Prevents a window being flagged starved, and skipped, only because the app yielded.
4. A late `done` for any callback id we allocated heals starvation and recycles the id, with oldest-first eviction at the cap. Prevents a starved window staying starved forever and ids leaking.
5. A release preserves START, so a press and release inside one frame still reads as pressed this frame. Prevents dropped taps.
6. Globals bind by compositor name, never by first interface match. Prevents every `wl_output` / `wl_seat` aliasing the first one.
7. A poisoned batch is never sent; a short send completes or fails loudly without resetting; truncated control data is a dead connection. Prevents a half-written or fd-less message corrupting the stream.
8. A drain handles every event of its own object, not only the one it waits for (the lost `repeat_info` and the initial selection offer were both this). Prevents silently lost initial state.
9. Library code returns errors rather than dying: `sendmsg` with `MSG_NOSIGNAL`, so a closed peer is an error, not SIGPIPE.

## Deferred (noted during the backport)

- `session.jai`'s `wayland_send(batch, drain=true)` overload ignores the receive result and discards what it reads, fds included (only `hello_window` uses it).
- The pump's mid-session keymap re-parse logs a failure only when key logging is on; `wl_keyboards[0].keymap` goes stale after a mid-session KEYMAP (only `wl_keymap` is updated).
- `get_screens_info` never releases its `wl_output` proxies, so their later events reach the router and are dropped (no fds); `wl_output_cap` caches its first answer for the process life, so a larger hot-plugged monitor never raises the cap.
- The current-selection `data_offer` that arrives during `get_data_devices_info` is dropped (the "we don't support paste yet" comment there is stale).
- `wl_registry_bind` overload 4 has no interface-name mismatch guard; `wl_route_registered_window_control_event` duplicates the router's configure/close branches.
- The router's orphan-callback branch and the `MSG_CTRUNC` path have no headless test (a 29-fd `sendmsg` over a socketpair would pin the latter).
- `wayland_receive` reports `EINTR` and a full `in_buf` as a lost connection without logging; `sendmsg` lacks `MSG_NOSIGNAL`; the libwayland_shim's long-lived batch stays poisoned after one overflow.
