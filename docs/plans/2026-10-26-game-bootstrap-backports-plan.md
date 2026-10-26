# game-bootstrap backports — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land on master every fix game-bootstrap made to the windowing stack it vendored from here, with a test for each, before the V2 restructure begins.

**Architecture:** Wire-layer fixes first (`modules/wayland`), each with a headless regression test; then the two pump changes in `Wayland_Support` (a single message router that every roundtrip drain feeds foreign traffic through, and starvation recovery for abandoned frame callbacks); then the small input and window niceties; docs travel with each commit. One branch, `backport/game-bootstrap`, one commit per task, merged `--no-ff` into master by the controller.

**Tech Stack:** Jai beta 0.2.030 (`~/jai/jai`), `./build.sh` → `first.jai` metaprogram, socketpair + memfd for headless wire tests.

**Spec:** `docs/plans/2026-10-26-game-bootstrap-backport-audit.md` (item numbers below refer to its table). Reference diffs: `git -C ~/projects/game-bootstrap show <hash>` for the hashes each task names; that checkout is read-only.

## Global Constraints

- Before writing or modifying ANY Jai code, invoke the `jai-language` skill (Skill tool). Non-negotiable (project CLAUDE.md).
- Build and test only through `./build.sh - <target>` from the worktree root `/home/jim/projects/jai-wayland/.worktrees/backport-game-bootstrap`; never invoke `jai-linux` directly on project code.
- Linkage thesis: no new linked libraries. `ldd build/hello_gl` stays libc + vdso + ld-linux.
- Modules `log`/`log_error`; they never `print`. No silent failures: a failure is logged through the context logger or returned, never swallowed, and `assert` is not a surfacing mechanism.
- TDD per task: the test is written and run first; the report records the RED command and output, then the GREEN.
- Test files follow `tests/wire_test.jai`: `#import "Basic"; Wayland :: #import,dir "../modules/wayland";`, procs named `test_*` using `assert` and `print("  PASS: <name>\n")`, called from `main`. A new suite is registered in `first.jai` as `case "<name>_test"; build_and_run_test("<name>_tests", "<name>_tests", "tests/<name>_test.jai", "build_tests"); set_build_options_dc(.{do_output=false});` and added to the Unknown-argument message string.
- Every user-facing change updates `CLAUDE.md` in the same commit: the Build Commands list for a new target, the Tests list and its "Total: N tests across M test suites" line, and the Architecture or Key Patterns paragraph that describes the changed code.
- After every task, these must pass: `./build.sh - test`, `gen_test`, `wire_test`, `marshal_test`, `unmarshal_test`, `compile_test`, `xkb_test`, every suite added by an earlier task, and the compile gates `./build.sh - compile_only <t>` for `hello_window`, `hello_gl`, `hello_vulkan_dmabuf`, `hello_simp`, `hello_clipboard`, `simp_multiple_windows`, `getrect_example`.
- No live Wayland compositor exists on the build box (it runs i3/X11). Behaviour that only a compositor can exercise is stated as such in the report, never claimed.
- Commit subjects use the repo's prefixes (`fix(wayland): …`, `feat(wayland): …`, `test(wayland): …`, `docs: …`). Never push. Never touch `master`; the controller merges.

## Review Focus

1. A compositor whose `zwp_linux_dmabuf_v1` is below v4 reports modifiers only through `.MODIFIER` events; that path must carry the full 64-bit modifier too, not only the v4 format table. Pinned by `test_make_drm_modifier_keeps_high_word` in Task 1.
2. Two globals that share an interface name (two monitors, two seats) must bind to two different compositor names. Pinned by `test_bind_by_global_info_writes_each_name` in Task 2.
3. A batch that overflows must never be sent truncated; `wayland_send` refuses it and says why. Pinned by `test_wayland_send_refuses_overflowed_batch` in Task 3.
4. A foreign fd-bearing message interleaved into a feedback drain must have its fd popped in order and be routed, not dropped. Pinned by `test_feedback_collector_routes_foreign_fd_message` in Task 4.
5. A key or button pressed and released inside one frame must still read as pressed this frame, not as held, and must clear the next frame. Pinned by `test_release_preserves_start_bit` in Task 6.

---

### Task 1: DRM modifier high word (audit item 1)

**Files:**
- Modify: `modules/wayland/dmabuf.jai:78` (the `.MODIFIER` event path) and `:205` (`append_feedback_format_table`)
- Create: `tests/dmabuf_test.jai`
- Modify: `first.jai` (register `dmabuf_test`), `CLAUDE.md`

**Interfaces:**
- Produces: `make_drm_modifier :: inline (hi: u32, lo: u32) -> u64` in `dmabuf.jai`, used by both decode sites. Task 4 extends `tests/dmabuf_test.jai`.

- [ ] **Step 1: Write the failing tests** in `tests/dmabuf_test.jai`:
  - `test_make_drm_modifier_keeps_high_word`: `make_drm_modifier(0x03000000, 0x00e08014) == 0x0300000000e08014` and `make_drm_modifier(0x00ffffff, 0xffffffff) == Wayland.DRM_FORMAT_MOD_INVALID`.
  - `test_format_table_parse_keeps_high_word`: a memfd (`Wayland.memfd_create`, then POSIX `write`) holding one 16-byte entry with format `0xAABBCCDD` at offset 0, modifier_lo `0x55667788` at 8, modifier_hi `0x11223344` at 12; `out: [..] Wayland.Format_Modifier; Wayland.append_feedback_format_table(*out, cast(Wayland.Fd) fd, 16);` then `out.count == 1`, `out[0].format == 0xAABBCCDD`, `out[0].modifier == 0x1122334455667788`.
- [ ] **Step 2: Register the suite** in `first.jai` and run `./build.sh - dmabuf_test`. Expected: the first test fails to compile (`make_drm_modifier` undeclared); temporarily comment its call out and confirm the second FAILS with the modifier read as `0x55667788`. Record both in the report.
- [ ] **Step 3: Implement** `make_drm_modifier` as `((cast(u64) hi) << 32) | cast(u64) lo` with a comment naming the precedence trap (cast binds looser than `<<`), and use it at both sites.
- [ ] **Step 4: Run** `./build.sh - dmabuf_test`. Expected: both PASS, output pristine.
- [ ] **Step 5: Docs.** `CLAUDE.md`: add the `dmabuf_test` line to Build Commands and the Tests list, bump the total, mention `make_drm_modifier` in the `dmabuf.jai` paragraph, and append this dated sentence to the NVIDIA caveat in the Project Overview: "(2026-10-26: the 'tranches advertise no usable format' finding predates a fix to the modifier parse, which dropped every modifier's high word; re-verify on NVIDIA before relying on it.)"
- [ ] **Step 6: Full gate** (Global Constraints), then commit: `fix(wayland): keep the DRM modifier's high word when decoding (cast binds looser than <<)`.

### Task 2: bind a specific global by name (audit item 2)

**Files:**
- Modify: `modules/wayland/registry.jai` (new overload; overload 3 delegates to it), `modules/wayland/output.jai:36-53` (`get_screens_info`), `modules/wayland/input.jai` (`get_seats_info`)
- Create: `tests/registry_test.jai`
- Modify: `first.jai` (register `registry_test`), `CLAUDE.md`

**Interfaces:**
- Produces: `wl_registry_bind :: (batch: *MessageBuilder, self: *Wl_Registry, gi: Global_Info, id: u32, ti: *Type_Info) -> bool` (overload 4). Wire layout it writes: header, `gi.name` u32, interface string, `min(gi.version, descriptor version)` u32, `id` u32.

- [ ] **Step 1: Write the failing tests** in `tests/registry_test.jai` (import the module as in `wire_test.jai`; the registry proxy is `Wayland.Wl_Registry.{ id = 2 }`):
  - `test_bind_by_global_info_writes_each_name`: globals `.{ name = 10, interface_name = "wl_output", version = 4 }` and `.{ name = 11, interface_name = "wl_output", version = 4 }`; bind ids 3 and 4 into one `MessageBuilder` with `type_info(Wayland.Wl_Output)`; walk `batch.out_buf` with `Wayland.unpack_header` / `read_u32` / `read_string`: first message name field `== 10`, new_id `== 3`; second `== 11`, `== 4`; both object ids `== 2`, opcode `== Wayland.WL_REGISTRY_BIND`.
  - `test_bind_by_global_info_negotiates_min_version`: `gi.version = 1` → version field `== 1`; `gi.version = 99` → version field `== Wayland.Wl_Output.{}.version` (the descriptor default).
- [ ] **Step 2: Register and run** `./build.sh - registry_test`. Expected: FAIL to compile, no overload takes a `Global_Info`.
- [ ] **Step 3: Implement** overload 4; make overload 3 look up `get_global(md.interface_name)` and call overload 4. In `get_screens_info` and `get_seats_info`, replace the count-then-bind loops with a loop over `globals()` that binds each matching `Global_Info` through overload 4 (ids still allocated immediately before each bind).
- [ ] **Step 4: Run** `./build.sh - registry_test`. Expected: PASS.
- [ ] **Step 5: Docs.** `CLAUDE.md`: Build Commands + Tests + total; in the `registry.jai` paragraph say that same-interface globals bind by `Global_Info` and that `get_screens_info`/`get_seats_info` do so.
- [ ] **Step 6: Full gate**, commit: `fix(wayland): bind every wl_output / wl_seat global by name, not the first match`.

### Task 3: no silent failures in the connection layer (audit item 8)

**Files:**
- Modify: `modules/wayland/connection.jai:97-120` (`cache_free`), `:132-134` (`allocate_id`), `:144-154` (`message_queue`, `message_queue_fd`), `:176-180` (`receive_pop_fd`), `:187` (`wayland_send`)
- Modify: `tests/wire_test.jai`, `CLAUDE.md`

**Interfaces:**
- Produces: `MessageBuilder.overflowed: bool`. On overflow `message_queue`/`message_queue_fd` `log_error`, set `overflowed = true`, and write nothing. `wayland_send` returns `false` after a `log_error` when `batch.overflowed`, sending nothing. `receive_pop_fd` on an empty FIFO logs and returns `-1`. `cache_free` on a double free or unknown id logs and returns. `allocate_id` logs and returns `0` when uninitialised or exhausted.

- [ ] **Step 1: Write the failing tests** in `tests/wire_test.jai`, each under the error-recording logger from the global CLAUDE.md (an `Error_Recorder` collecting `.ERROR` messages via `push_context`):
  - `test_message_queue_overflow_poisons_batch`: queue `batch.out_buf.count + 1` bytes → `batch.overflowed`, `batch.out_used == 0`, exactly one error recorded.
  - `test_message_queue_fd_overflow_poisons_batch`: queue `batch.out_fds.count + 1` fds → `overflowed`, one error.
  - `test_wayland_send_refuses_overflowed_batch`: a `socketpair` (via `syscall(SYS_socketpair, 1, 1, 0, sv)` as POSIX has no binding) pair of `Connection`s; a non-empty batch with `overflowed = true` → `wayland_send` returns `false`, one error recorded, and a non-blocking `recv` on the peer yields no bytes.
  - `test_receive_pop_fd_empty_logs_and_returns_minus_one`.
  - `test_cache_free_unknown_id_logs_and_continues`: `cache_free` on an empty cache with id 42 records one error and returns.
- [ ] **Step 2: Run** `./build.sh - wire_test`. Expected: `overflowed` is undeclared (compile error) and, once stubbed, the current asserts abort the process. Record it.
- [ ] **Step 3: Implement** per Interfaces. Keep `assert` only where an `assert` already guards a compile-time constant.
- [ ] **Step 4: Run** `./build.sh - wire_test`. Expected: all PASS including the pre-existing 22.
- [ ] **Step 5: Docs.** `CLAUDE.md` Key Patterns: a bullet "A `MessageBuilder` that overflows is poisoned (`overflowed`), logged, and refused by `wayland_send`; `receive_pop_fd` returns -1 on an empty fd FIFO. Nothing in the connection layer fails silently."
- [ ] **Step 6: Full gate**, commit: `fix(wayland): overflow and fd-queue failures are logged and refused, not asserted`.

### Task 4: one router, no dropped messages (audit item 4)

**Files:**
- Modify: `modules/wayland/session.jai` (hook), `modules/wayland/output.jai`, `modules/wayland/input.jai` (`get_seats_info`, `get_keyboards_info`, `get_pointers_info`, `get_touch_info`, `get_data_devices_info`), `modules/wayland/dmabuf.jai` (`get_dmabuf_info`, `collect_dmabuf_feedback`), `modules/Window_Creation/linux.jai` (the configure wait in `create_window_wayland`), `modules/Wayland_Support.jai` (`wl_pump`, new `wl_route_message`)
- Modify: `tests/dmabuf_test.jai`, `CLAUDE.md`
- Reference: game-bootstrap `9acc257` and its design note `docs/plans/2026-06-25-dmabuf-feedback-foreign-message-routing-design.md`.

**Interfaces:**
- Consumes: Task 1's `tests/dmabuf_test.jai`.
- Produces, in `session.jai`: `Foreign_Message_Handler :: #type (header: *WaylandMessageHeader);`, field `WaylandSession.foreign_handler: Foreign_Message_Handler;`, and `route_foreign :: (header: *WaylandMessageHeader)` which calls the context session's handler when set. In `Wayland_Support.jai`: `wl_route_message :: (header: *Wl.WaylandMessageHeader) -> routed: bool, done: bool` (the per-message block lifted verbatim from `wl_pump`, which now calls it), `wl_route_foreign :: (header: *Wl.WaylandMessageHeader)` (calls `wl_route_message`, discards the results), and `wl_install_foreign_router :: ()` (idempotent; sets the session hook; called at the top of `create_window_wayland`, `wl_acquire_input`, and `wl_window_init_gl`).
- Rule: every roundtrip loop body calls `route_foreign(*it)` for a message that is neither its sync nor one of its own objects. `wl_route_message` never starts a roundtrip and never consumes bytes; the hook runs before the loop's deferred consume.

- [ ] **Step 1: Write the failing test** `test_feedback_collector_routes_foreign_fd_message` in `tests/dmabuf_test.jai`, ported from game-bootstrap's `modules/wayland/tests.jai` to the session API: a `WaylandSession` on a socketpair installed as `context.wayland_session` with `foreign_handler` set to a file-scope mock that pops one fd from `context.wayland_session.recv` and counts; the server marshals, in order, a foreign message on object 99 carrying fd A (a memfd holding `0xDEADBEEF`), `FORMAT_TABLE` on object 50 carrying fd B (one entry: format `0xAABBCCDD`, modifier `0x1122334455667788`, size 16), `DONE` on 50, then `wl_callback.done` on 51; call `Wayland.collect_dmabuf_feedback(.{ id = 50 }, 51)`; assert complete, mock pops `== 1`, `format_table[0].format == 0xAABBCCDD`, `.modifier == 0x1122334455667788`, and `recv.in_fds_read == recv.in_fds_count`.
- [ ] **Step 2: Run** `./build.sh - dmabuf_test`. Expected: FAIL at the format assertion (the table was read from fd A) or at the pops count.
- [ ] **Step 3: Implement** per Interfaces: hook + `route_foreign` in `session.jai`; the `route_foreign(*it)` fall-through in every listed roundtrip body (the configure wait in `create_window_wayland` keeps its own window routing and sends the rest to `route_foreign`); the `wl_route_message` lift in `Wayland_Support.jai`, behaviour-preserving (same branch order, the opcode-0 object-id-qualified branches still precede the buffer-release scan); `wl_install_foreign_router` and its three call sites.
- [ ] **Step 4: Run** `./build.sh - dmabuf_test`. Expected: PASS.
- [ ] **Step 5: Docs.** `CLAUDE.md`: in "Design: no inversion of control" add that roundtrip drains hand unrecognised messages to the session's `foreign_handler` so no message is dropped and no fd is stranded; in the `Wayland_Support` paragraph name `wl_route_message` as the single router the pump and every drain share; in Key Patterns, under the `defer` note, add that a drain body must either handle a message or pass it to `route_foreign`.
- [ ] **Step 6: Full gate**, commit: `fix(wayland): route foreign messages through one router during roundtrip drains (fd FIFO stays in step)`.

### Task 5: starvation recovery for abandoned frame callbacks (audit item 3)

**Files:**
- Modify: `modules/Wayland_Support.jai` (`Wayland_Window`, `wl_present_and_pace:862-905`, the frame-callback branch of `wl_route_message`)
- Create: `tests/pacing_test.jai` (imports `Wayland_Support` by file with the upstream import path, as `hello_simp` is built)
- Modify: `first.jai` (register `pacing_test`, passing `upstream_import_path()`), `CLAUDE.md`
- Reference: game-bootstrap `19cc46f`.

**Interfaces:**
- Produces: `Wayland_Window.wl_orphaned_frame_callbacks: [..] u32`; `WL_ORPHANED_CALLBACK_CAP :: 256`; `wl_orphan_frame_callback :: (ww: *Wayland_Window, id: u32)` (at the cap, drop the oldest without recycling); `wl_take_orphaned_frame_callback :: (ww: *Wayland_Window, id: u32) -> bool`.
- Behaviour: the pacing wait records whether it exited for an app turn; `frame_done` → recycle id, clear starvation (unchanged); app-turn exit → orphan the id, starvation unchanged; genuine timeout → orphan the id, set starvation. In the router, a `WL_CALLBACK_DONE` whose object id `wl_take_orphaned_frame_callback` accepts recycles the id into `ww.wl_frame_cache`, clears `wl_pacing_starved`, and is `routed`; this branch sits with the other object-id-qualified opcode-0 branches, before the buffer-release scan.

- [ ] **Step 1: Write the failing tests** in `tests/pacing_test.jai` on a stack `Wayland_Window`:
  - `test_orphan_take_returns_true_once`: orphan 7; take 7 → true; take 7 → false; take 8 → false.
  - `test_orphan_cap_evicts_oldest`: orphan 1 through 257; take 1 → false; take 2 → true; take 257 → true.
- [ ] **Step 2: Register and run** `./build.sh - pacing_test`. Expected: compile error, the procs do not exist.
- [ ] **Step 3: Implement** per Interfaces.
- [ ] **Step 4: Run** `./build.sh - pacing_test`. Expected: PASS.
- [ ] **Step 5: Docs.** `CLAUDE.md`: in the `Wayland_Support` paragraph's pacing description, replace "The pump clears `wl_pacing_starved` the instant a callback returns" wording with the orphan-list recovery (an app-turn exit is not starvation; a late `done` for any id the window allocated clears it and recycles the id); note in the report that the exit classification can only be exercised live and name the scenario (resize window A while B is visible).
- [ ] **Step 6: Full gate**, commit: `fix(Wayland_Support): an app-turn exit is not starvation; late frame callbacks heal it`.

### Task 6: app_id, keymap at arrival, tap-preserving release (audit items 5, 6, 7)

**Files:**
- Modify: `modules/Window_Creation/linux.jai:279`, `examples/hello_window.jai`, `examples/hello_gl.jai`, `examples/hello_vulkan_dmabuf.jai` (each toplevel gets `xdg_toplevel_set_app_id` right after `set_title`, same string)
- Modify: `modules/wayland/input.jai` (`Keyboard_Info`, `get_keyboards_info`), `modules/Wayland_Support.jai:1262-1272` (`wl_acquire_input`)
- Modify: `modules/Input/wayland.jai:131`, `:252`, `modules/Input/x11.jai:625`, `:677`
- Create: `tests/input_test.jai`, `tests/fixtures/xkb_sample_keymap.jai`; Modify: `tests/xkb_test.jai` (`#load` the fixture), `first.jai` (register `input_test` with `upstream_import_path()`), `CLAUDE.md`
- Reference: game-bootstrap `acaf977`, `b146ede`, `1168777`.

**Interfaces:**
- Produces: `Keyboard_Info { seat_index: int; keyboard: Wl_Keyboard; keymap: Keymap; keymap_valid: bool; }` (the `keymap_fd`/`keymap_size` fields are removed); `get_keyboards_info` parses with `parse_keymap_fd` as the `KEYMAP` event arrives and closes the fd itself. In `modules/Input/wayland.jai`: `button_state_after_release :: (current: Key_Current_State) -> Key_Current_State` returning `.END | (current & .START)`, used by both arms at all four release sites.

- [ ] **Step 1: Write the failing tests** in `tests/input_test.jai`:
  - `test_release_preserves_start_bit` (imports `Input` with the upstream import path): `button_state_after_release(.START | .DOWN) == .START | .END`; `button_state_after_release(.DOWN) == .END`; `button_state_after_release(.NONE) == .END`.
  - `test_keyboards_info_parses_keymap_on_arrival` (wire level, session on a socketpair as in Task 4's test): seats `.[ .{ seat = .{ id = 5 }, capabilities = cast(u32) Wayland.Wl_Seat_Capability.KEYBOARD } ]`; set `sess.conn.next_id = 7` so the keyboard binds as id 7 and the sync as 8; the server marshals `wl_keyboard.keymap` on 7 (`format = XKB_V1`, fd = a memfd holding the `SAMPLE_KEYMAP` text, `size` = its length; move that constant out of `tests/xkb_test.jai` into `tests/fixtures/xkb_sample_keymap.jai` and `#load` it from both tests) then `wl_callback.done` on 8; `kbs := Wayland.get_keyboards_info(seats)`; assert `kbs.count == 1`, `kbs[0].keymap_valid`, and `Wayland.keymap_get_keysym(*kbs[0].keymap, <the evdev code xkb_test uses for 'q'>, 0)` equals the keysym xkb_test asserts for it.
- [ ] **Step 2: Register and run** `./build.sh - input_test`. Expected: compile errors (`button_state_after_release`, `keymap_valid` undeclared).
- [ ] **Step 3: Implement** per Interfaces; `wl_acquire_input` copies `kb.keymap`/`kb.keymap_valid` into `wl_keymap`/`wl_keymap_valid` and no longer parses or closes anything; add the four `set_app_id` calls.
- [ ] **Step 4: Run** `./build.sh - input_test`, then `./build.sh - xkb_test`. Expected: PASS.
- [ ] **Step 5: Docs.** `CLAUDE.md`: the `input.jai` paragraph (`Keyboard_Info` now carries the parsed keymap); the Input "Full Wayland input surface" sentence gains "a release preserves `START`, so a press and release inside one frame still reads as pressed this frame (deliberate deviation from the distribution, applied to both arms)"; the vendored-modules patch-sites sentence gains `modules/Input/x11.jai`'s two release sites; `Window_Creation/linux.jai` description notes `app_id` is set to the window name (Wayland's WM_CLASS); Build Commands + Tests + total.
- [ ] **Step 6: Full gate**, commit: `feat(input): app_id on toplevels, keymap parsed on arrival, tap-preserving release`.

### Task 7: close the audit (docs only)

**Files:**
- Modify: `docs/plans/2026-10-26-game-bootstrap-backport-audit.md`, `CLAUDE.md`

- [ ] **Step 1:** Append a "Status (2026-10-26)" table to the audit: item number, disposition (landed in commit `<short sha>` / deferred to V2 / not applicable), one-line note. Items 1, 2, 3, 4, 5, 6, 7, 8, 9 landed; 10 to 15 deferred to V2.
- [ ] **Step 2:** Append a "V2 invariants" section listing, one line each with the failure it prevents: one drain, nothing dropped, fds popped for every message; an app-turn exit is not starvation; a late done for any callback id we allocated heals starvation and recycles the id; a release preserves START; bind globals by name, never by first interface match; a poisoned batch is never sent.
- [ ] **Step 3:** `CLAUDE.md` Next Steps: item 5's "Niceties left" sentence drops nothing (pointer capture and AltGr remain), and the Known gaps paragraph gains "see the 2026-10-26 backport audit for the V2 invariants".
- [ ] **Step 4:** Run the table aligner `python3 -I ~/lighthouse/connecting-accounts/tools/align-md-tables.py --check <file>` on both files (Jim reads raw Markdown in Emacs; misaligned pipe tables are broken tables). Commit: `docs: close the game-bootstrap backport audit with status and V2 invariants`.
