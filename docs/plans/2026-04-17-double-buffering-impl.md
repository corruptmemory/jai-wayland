# Double Buffering Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Eliminate client-compositor buffer races in `hello_window.jai` by rotating between two `wl_buffer` descriptors backed by the same shm pool, paced by `wl_buffer.release` events.

**Architecture:** Keep one `Wl_Shm_Pool`, double its size to `2 * screen_w * screen_h * BPP`. Carve it into two `Buffer_Slot` records at offsets `0` and `frame_max_bytes`. Each slot owns a persistent `Wl_Buffer` descriptor + a pre-cached pixel pointer + an `in_flight` bool. A dirty flag sitting *outside* the event loop drives repaints; the defer block picks the first non-in-flight slot, paints, attaches, commits. When both slots are in flight, the dirty flag stays set and the next `wl_buffer.release` event naturally re-fires the paint on the now-free slot.

**Tech Stack:** Jai, Wayland wire protocol, `wl_shm` shared memory, compile-time marshal/unmarshal macros.

**Build/test commands:**
- `./build.sh - hello_window` — live integration test, requires running Hyprland
- `./build.sh - compile_test` — verify modules still compile cleanly
- No unit-test coverage for this change; verification is visual and interactive

**Key facts from the generated module** (`modules/wayland/wayland/wl_buffer.jai`):
- `WL_BUFFER_RELEASE :: 0` — the only event opcode
- `Wl_Buffer_Release_Args :: struct {}` — zero-arg event; no unmarshal needed
- `wl_buffer_destroy` already exists as a destructor request

**Key invariant from CLAUDE.md:** `allocate_id()` must happen immediately before queuing the message that creates that object. Pre-allocating IDs and sending out of order triggers `wl_display.error`. Every `Wl_Buffer.{ id = allocate_id() }` in this plan is paired with an immediately-following `wl_shm_pool_create_buffer` in the same batch, in that order.

---

### Task 1: Pre-flight — commit pending housekeeping

Clear the working tree so the double-buffering commits arrive against a clean base. The session already has two pending changes unrelated to double buffering: the sublime-files expunge + the CLAUDE.md alignment with landed features.

**Files:**
- Modify: `.gitignore` (already has `*.sublime-*` patterns added)
- Modify: `CLAUDE.md` (already has pointer+XKB reconciliation)
- Staged deletions: `jai-wayland.sublime-project`, `jai-wayland.sublime-workspace`
- Untracked but intentionally not committed: `.claude/` (already tracked in HEAD; the untracked entry is from a cwd mismatch earlier — verify with `git status` before committing)

**Step 1: Verify working tree state**

Run: `git status --short`
Expected output:
```
 M .gitignore
 M CLAUDE.md
D  jai-wayland.sublime-project
D  jai-wayland.sublime-workspace
```
If `.claude/` shows as untracked (`??`), do NOT stage it — it was already committed in `3299fdb`.

**Step 2: Stage and commit**

```bash
git add -u .gitignore CLAUDE.md jai-wayland.sublime-project jai-wayland.sublime-workspace
git commit -m "$(cat <<'EOF'
docs: reconcile CLAUDE.md with landed features, untrack sublime files

Pointer input and XKB keymap parsing landed in 4edf695 but the doc
still listed them as Next Steps. Cross them off, update input.jai
client-API entry to describe the seat-based API (get_seats_info,
get_keyboards_info, get_pointers_info, event helpers), add xkb.jai,
add dump_keymap example.

Remove jai-wayland.sublime-* from the index and add matching
.gitignore patterns — those are per-machine editor state.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Step 3: Verify clean tree**

Run: `git status`
Expected: `nothing to commit, working tree clean` (modulo `.claude/` untracked if present).

---

### Task 2: Structural foundation — `Buffer_Slot` type + 2× pool + two-slot init

Establish the data structures and double the pool size, but keep behavior identical to today: slot 0 stays in flight continuously, slot 1 is allocated but never used. This is a refactor-only commit — the window should behave exactly as before.

**Files:**
- Modify: `examples/hello_window.jai` (top-of-file type addition + pool sizing + bootstrap)

**Step 1: Add `Buffer_Slot` type**

Insert after the `Color` enum declaration (around line 15, before `main`):

```jai
Buffer_Slot :: struct {
    buffer:    Wl_Buffer;
    offset:    u32;       // byte offset into the shm pool
    pixels:    *u8;       // cached = pixel_data + offset
    in_flight: bool;      // true = attached, awaiting wl_buffer.release
}
```

**Step 2: Double the pool size**

At `examples/hello_window.jai:32`, change:
```jai
pool_size := cast(s32)(screen_width * screen_height * BPP);
```
to:
```jai
frame_max_bytes := cast(u32)(screen_width * screen_height * BPP);
pool_size       := cast(s32)(2 * frame_max_bytes);
```
`frame_max_bytes` is reused as the offset of slot 1 below.

**Step 3: Replace single-buffer bootstrap with two-slot bootstrap**

Replace lines 102-115 (the `// --- Create initial buffer from pool and present ---` block through the first `wayland_send(*batch);`) with:

```jai
// --- Create two buffer slots; paint slot 0 for the initial frame ---
current_color := Color.BLUE;
stride := win_width * BPP;

slots: [2] Buffer_Slot;
slots[0].offset = 0;
slots[1].offset = frame_max_bytes;
for * slots {
    it.pixels = cast(*u8) pixel_data + it.offset;
}

// Paint the initial frame into slot 0's backing memory
paint(slots[0].pixels, win_width, win_height, stride, current_color);

// Acknowledge configure, create both buffer descriptors, attach slot 0.
// IDs must be allocated immediately before their create message (wire ordering).
xdg_surface_ack_configure(*batch, *xdg_surface, configure_serial);
for * slots {
    it.buffer = Wl_Buffer.{ id = allocate_id() };
    wl_shm_pool_create_buffer(*batch, *pool, it.buffer.id,
        offset = cast(s32) it.offset, width = win_width, height = win_height,
        stride = stride, format = cast(u32) Wl_Shm_Format.XRGB8888);
}
wl_surface_attach(*batch, *surface, *slots[0].buffer, 0, 0);
wl_surface_damage_buffer(*batch, *surface, 0, 0, win_width, win_height);
wl_surface_commit(*batch, *surface);
wayland_send(*batch);
slots[0].in_flight = true;
```

**Step 4: Remove the old `current_buffer` variable from resize scope**

This task keeps the resize path temporarily broken in the sense that it still references `current_buffer`. **Do not fix it yet** — Task 3 rewrites that block entirely. For this task, leave the resize code alone. If `current_buffer` is still referenced elsewhere, the compiler will complain; resolve by keeping a `current_buffer := slots[0].buffer;` temporary pointing at slot 0 so the resize logic from the old code still compiles. This is intentional scaffolding to keep Task 2 independently committable.

Concretely, right before the event loop (`for session()`), add:
```jai
// TEMPORARY (removed in Task 3): let the old single-buffer resize code still compile
current_buffer := slots[0].buffer;
```
The old resize block at lines 196-204 now operates on this proxy and will be rewritten in Task 3.

**Step 5: Build and run**

Run: `./build.sh - hello_window`
Expected:
- Compiles with no errors or warnings
- Window appears at 640×480 (or whatever the compositor suggests)
- Blue gradient is visible
- `r`, `g`, `b` keys cycle colors; `q` quits
- Resize works as before (still single-buffered — slot 1 is allocated but dormant)
- No visible regression vs. the single-buffer version

**Step 6: Commit**

```bash
git add examples/hello_window.jai
git commit -m "$(cat <<'EOF'
hello_window: add Buffer_Slot scaffolding, double pool size

Introduces the Buffer_Slot struct and allocates two slots carving
the pool at offsets 0 and frame_max_bytes. Behavior is unchanged:
slot 0 is used as the single buffer, slot 1 is dormant. The full
double-buffering logic lands in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Full double buffering — release handling, slot picker, persistent dirty, resize

This is the big one. Route `wl_buffer.release` events to their slots, add a `find_free_slot` picker, convert `needs_repaint` (per-iteration local) into `dirty` (persistent across iterations), and rewrite the resize path to recreate both slot descriptors.

**Files:**
- Modify: `examples/hello_window.jai`

**Step 1: Add `find_free_slot` helper**

Near the `paint` function at the bottom of the file, add:

```jai
find_free_slot :: (slots: [] Buffer_Slot) -> s32 {
    for slots  if !it.in_flight  return cast(s32) it_index;
    return -1;
}
```

**Step 2: Introduce persistent `dirty` flag and rewrite the defer block**

Before the `for session()` loop (around where `pending_width` / `pending_height` are declared, lines 120-123), add:
```jai
dirty := false;
```

Remove the old `current_buffer` scaffolding temporary introduced in Task 2 Step 4 — the resize rewrite below no longer needs it.

Replace the entire `needs_repaint` local + defer block at the top of the for-body (lines 126-133) with:

```jai
defer if dirty {
    slot_idx := find_free_slot(slots);
    if slot_idx >= 0 {
        slot := *slots[slot_idx];
        paint(slot.pixels, win_width, win_height, stride, current_color);
        wl_surface_attach(*batch, *surface, *slot.buffer, 0, 0);
        wl_surface_damage_buffer(*batch, *surface, 0, 0, win_width, win_height);
        wl_surface_commit(*batch, *surface);
        wayland_send(*batch);
        slot.in_flight = true;
        dirty = false;
    }
    // else: both slots in flight; dirty stays set, next release triggers repaint
};
```

Then, in the keyboard and pointer handlers (lines 137-170), replace every `needs_repaint = true;` with `dirty = true;`.

**Step 3: Route `wl_buffer.release` events at the top of the event loop**

At the very start of the `for session()` body (before the keyboard/pointer helper calls, around line 126 after the defer), add:

```jai
// Route wl_buffer.release — mark the slot available
if it.opcode == WL_BUFFER_RELEASE {
    obj_id := it.object_id;
    for * slots {
        if it.buffer.id == obj_id {
            it.in_flight = false;
            break;
        }
    }
    continue;
}
```

Note: capture `it.object_id` into `obj_id` BEFORE the inner `for * slots` — the inner loop rebinds `it` to `*Buffer_Slot`, shadowing the outer message-header `it`. The `continue` is safe because `for session()`'s `defer` handles message consumption (per CLAUDE.md).

**Step 4: Rewrite the resize path**

Replace the old resize block at lines 196-204 (the `// Destroy old buffer, create new from same pool` section) with:

```jai
// Destroy both old buffer descriptors, create two new ones at same offsets.
// The pool and mmap stay the same; only the buffer descriptors change.
for * slots  wl_buffer_destroy(*batch, *it.buffer);
for * slots {
    it.buffer = Wl_Buffer.{ id = allocate_id() };
    wl_shm_pool_create_buffer(*batch, *pool, it.buffer.id,
        offset = cast(s32) it.offset, width = win_width, height = win_height,
        stride = stride, format = cast(u32) Wl_Shm_Format.XRGB8888);
    it.in_flight = false;
}
dirty = true;  // trigger a repaint at the new dimensions
```

Resetting `in_flight = false` on both slots is deliberate: when we destroy a buffer the compositor was displaying, we won't get its `release` event — but the client-side descriptor is gone, and the new descriptor at the same offset has never been attached, so it starts available. This is safe because we destroy and recreate in the same batch before sending.

Also remove the old `if !needs_repaint` branch at lines 208-211 — the dirty flag + defer handle it now:
```jai
// (old code to remove)
xdg_surface_ack_configure(*batch, *xdg_surface, serial);
if !needs_repaint {
    wl_surface_commit(*batch, *surface);
    wayland_send(*batch);
}
```
becomes:
```jai
xdg_surface_ack_configure(*batch, *xdg_surface, serial);
// Defer block will commit+send if dirty is set (which it is, after a resize)
```

The `ack_configure` still needs to be flushed. If `dirty` is true, the defer handles it. If not (e.g. configure with no size change), we need to flush the ack alone. Add right after the ack:
```jai
xdg_surface_ack_configure(*batch, *xdg_surface, serial);
if !dirty {
    wayland_send(*batch);  // flush the ack; no repaint needed
}
```

**Step 5: Build**

Run: `./build.sh - hello_window`
Expected: compiles with zero errors, zero warnings.

**Step 6: Visual smoke test**

Run: `./build.sh - hello_window`
Expected:
- Window appears, blue gradient
- `r`/`g`/`b` cycles colors responsively
- Click cycles color, prints coordinates
- Dragging the window border resizes smoothly with visibly less tearing than before
- Rapid resize (aggressive corner drag for 5-10 seconds) doesn't crash or stall
- `q` quits cleanly

**Step 7: Run compile smoke test**

Run: `./build.sh - compile_test`
Expected: 8 tests pass, 0 failures. This verifies the generated module still compiles cleanly against the example's imports.

**Step 8: Commit**

```bash
git add examples/hello_window.jai
git commit -m "$(cat <<'EOF'
hello_window: implement double buffering with wl_buffer.release

Route wl_buffer.release events to mark the originating slot
available. find_free_slot picks an available slot for each paint;
when both are in flight, the persistent dirty flag keeps the
repaint queued until the next release. Resize destroys both old
descriptors and creates two new ones at the same pool offsets.

Eliminates the client-compositor buffer race that caused visible
tearing during rapid resize and rapid input in the single-buffered
version.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: CLAUDE.md update

Cross double buffering off the Next Steps list and make a brief note in the hello_window example description.

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Update the hello_window.jai example description**

Find the `hello_window.jai` bullet in the Examples section and update the description to mention double buffering. Current text includes "pooled shared memory buffers" — extend to "double-buffered shared memory (wl_buffer.release-paced swap)".

**Step 2: Remove "Double buffering" from Next Steps and renumber**

Current Next Steps:
1. Rendering integration (Phase 5)
2. Server-allocated objects
3. Double buffering
4. Fractional scaling

New Next Steps:
1. Rendering integration (Phase 5)
2. Server-allocated objects
3. Fractional scaling

**Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
docs: cross off double buffering from Next Steps

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Post-execution checklist

- [ ] `git log --oneline -5` shows the 4 commits in order (housekeeping → Buffer_Slot scaffolding → full double buffering → CLAUDE.md)
- [ ] Working tree clean (`git status` shows nothing)
- [ ] `./build.sh - hello_window` runs and shows visibly smoother resize
- [ ] `./build.sh - compile_test` passes

## Rollback plan

If Task 3 fails visual verification (flickering, stuck frames, crashes):
- `git reset --hard HEAD~1` reverts Task 3's commit
- The Task 2 scaffolding remains in place (the Buffer_Slot struct and 2× pool are harmless refactors)
- Debug: check whether `wl_buffer.release` events are arriving (add a `print("release slot %\n", it_index);` in the release handler). If they never arrive, the compositor may not be sending them for some reason; investigate by comparing against `zig-wayland` or `wayland-rs` reference implementations in `vendor/reference/`.
