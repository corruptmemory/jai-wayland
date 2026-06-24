# libwayland-client proxy — implementation plan

> **For agentic workers:** execute task-by-task; each task ends with an independently testable
> deliverable. Steps use `- [ ]` checkboxes. This is a working roadmap for an exploratory systems
> proof — Tasks 1–5 are deterministic + unit-tested; Tasks 6–8 are integration/discovery against the
> real Mesa ICD + Hyprland (the ICD's exact bind/dispatch sequence is observed, not assumed).

**Goal:** A `libwayland_shim` module whose `#program_export`'d C-ABI `wl_*` symbols, backed by the
native `wayland` wire client, satisfy a real Vulkan ICD so `vkCreateWaylandSurfaceKHR` + swapchain
presents a frame — with real `libwayland` never used.

**Architecture:** Veneer over the existing `modules/wayland` wire engine. Exported core = a
runtime-signature-driven marshaller + a single-owner multi-queue event demux + listener vtables. One
~30-line C file provides the variadic `wl_proxy_marshal_flags` (Jai can't author C-varargs). Interface
tables are XML-generated data (hand-stubbed for the slice-1 set, generator ported later).

**Tech Stack:** Jai beta 0.2.029; native `modules/wayland`; vendored `modules/Vulkan` (runtime-loaded);
gcc (one C file); grim (visual verify under Hyprland).

## Global Constraints

- Substrate is `modules/wayland` (`Connection`, `MessageBuilder`, `ReceiveBuffer`, `wire.jai`
  writers, `allocate_id`) — reuse, do not rewrite the wire layer.
- Every shadowed symbol is `#program_export`. No linker-arg config needed (Jai links
  `-export-dynamic` by default — proven, `spikes/symbol-scope/`).
- Exactly ONE C file (`wl_marshal_varargs.c`); no external `#library`. Linkage thesis: `ldd` of the
  harness shows no `libwayland`/`libX11`/`libGL`/`libEGL`/`libgbm`/`libvulkan`.
- ABI structs (`wl_interface`, `wl_message`, `wl_argument`, `wl_array`, `wl_fixed_t`, `wl_list`,
  `wl_proxy`) must match libwayland byte-for-byte. Reference layouts: game-bootstrap
  `modules/Wayland_Client/core.generated.jai`.
- Modules `log`, don't `print`; examples `print`. Route incoming events by `(object_id, opcode)`.
- **Commits are made only when Jim asks.** Treat "checkpoint" notes as logical boundaries, not `git
  commit` invocations.
- Tests run via `./build.sh - <verb>`; unit tests follow the project's `assert` + `print("  PASS")`
  pattern (à la `tests/marshal_test.jai`).

---

## Status (2026-06-24, autonomous session)

- **Task 1 — module + ABI types: DONE.** `modules/libwayland_shim/{module,types}.jai`. ABI structs
  ported from game-bootstrap byte-for-byte; backing structs (`Wl_Display` IS-A `Wl_Proxy`, id 1).
  Decision: exported entry points are `#c_call` + `push_context shim_context` (context captured at
  bring-up). Gotcha banked: `interface` is a Jai reserved word → field/param `interface_`; the context
  type is `#Context` (with the `#`).
- **Task 2 — runtime marshaller: DONE + unit-proven.** `marshal_runtime.jai` +
  `tests/shim_marshal_test.jai` (3/3 PASS: `uf`, `new_id` alloc, `string` — exact wire bytes).
- **Task 3 — variadic C shim: DONE + unit-proven.** `wl_marshal_varargs.c` + `tests/shim_varargs_test.c`
  (PASS incl. the untyped-new_id `"usun"` bind shape; clean `-Wall -Wextra`).
- **Task 4 — trivial core + wl_list: DONE + unit-proven.** `core_trivial.jai` +
  `tests/shim_list_test.jai` (PASS).
- **RESUME HERE → Task 5 (queue engine):** the last big piece — `read_all_available` demux, per-queue
  routing, `dispatch_queue*`, `roundtrip_queue`, `add_listener` vtable dispatch, `create_queue`/
  `set_queue`/`create_wrapper`. Then Task 6 (tables + facade bring-up, registry-log discovery) and
  Task 7 (Vulkan swapchain harness + grim). Build standalone shim tests with
  `~/jai/jai/bin/jai-linux tests/shim_<x>_test.jai` (binaries gitignored).

Nothing committed (Jim gates commits). Marshalling path + easy core are done and tested; the engine's
event/dispatch half and the integration milestone remain.

---

### Task 1: Module scaffold + ABI types

**Files:** Create `modules/libwayland_shim/module.jai`, `modules/libwayland_shim/types.jai`.

**Produces:** `wl_fixed_t` (s32), `wl_array`, `wl_list`, `wl_message`, `wl_interface`, `wl_argument`
(union), `wl_proxy`, `wl_event_queue`, `Wl_Display`; constants `WL_MARSHAL_FLAG_DESTROY :: 1`.

- [ ] Port the ABI struct layouts from game-bootstrap `core.generated.jai` (`wl_message{name,signature,types}`,
  `wl_interface{name,version,method_count,methods,event_count,events}`, `wl_array{size,alloc,data}`,
  `wl_argument` union `{i:s32,u:u32,f:wl_fixed_t,s:*u8,o:*void,n:u32,a:*wl_array,h:s32}`).
- [ ] Define our real backing structs: `Wl_Proxy {id,interface,version,display,queue,listener:*void,user_data:*void}`,
  `Wl_Event_Queue {display,name,pending:[..]Queued_Event}`, `Wl_Display {conn,out,in,proxies,default_queue,queues}`.
- [ ] `module.jai` `#import,dir "../wayland"` + `#load` chain.
- [ ] **Test:** add a `compile_only` smoke that imports the module; `./build.sh - <verb>` compiles clean.

### Task 2: Runtime marshaller — `wl_proxy_marshal_array_flags` (pure Jai)

**Files:** Create `modules/libwayland_shim/marshal_runtime.jai`, `tests/shim_marshal_test.jai`.

**Interfaces — Produces:**
`wl_proxy_marshal_array_flags :: (proxy: *wl_proxy, opcode: u32, interface: *wl_interface, version: u32, flags: u32, args: *wl_argument) -> *wl_proxy #c_call`

- [ ] **Failing test first:** build a synthetic `wl_interface` with one request signature `"uf"` (uint,
  fixed) and one `"n"` (new_id); call the marshaller; assert the bytes appended to the display's
  `MessageBuilder.out_buf` equal the hand-computed wire image (header `[id][size<<16|op]` + payload),
  mirroring `tests/marshal_test.jai` cases. Run, see it fail (proc undefined).
- [ ] Implement: read `signature := interface.methods[opcode].signature`; walk chars
  (`i u f s o n a h`, `?` = nullable modifier, leading digits = since, skip); size-compute then pack via
  `wire.jai` writers into `display.out`; `s`→`write_string`, `a`→`write_array`, `h`→`message_queue_fd`,
  `o`→object id (arg.o→proxy.id or 0), `n`→`allocate_id` + create+register a `Wl_Proxy` of `interface`
  (the constructor target passed in) and write its id; untyped new_id (`sun`) writes name/version/id.
  `flags & WL_MARSHAL_FLAG_DESTROY` → unregister+free proxy after. Return new proxy or null.
- [ ] Run test → PASS. **Checkpoint.**

### Task 3: Variadic C shim + build wiring

**Files:** Create `modules/libwayland_shim/wl_marshal_varargs.c`; modify `first.jai` (gcc step + link
the `.o`); create `tests/shim_varargs_test.jai`.

**Produces (exported from C):** `wl_proxy_marshal_flags(proxy, opcode, interface, version, flags, ...)`.

- [ ] Write the C: `va_start`; walk `interface->methods[opcode].signature`; per char `va_arg` the right
  C type into a local `union wl_argument args[N]`; call the Jai-exported `wl_proxy_marshal_array_flags`;
  `va_end`. (Lift `wl_argument_from_va_list` from libwayland MIT `src/wayland-client.c`.)
- [ ] `first.jai`: compile the `.c`→`.o` with gcc, append the `.o` path to the workspace's
  `Build_Options.additional_linker_arguments`.
- [ ] **Test:** a Jai harness exporting a stub `wl_proxy_marshal_array_flags` that records its `args`;
  call the C `wl_proxy_marshal_flags` with a known signature/args; assert the recorded array matches
  (the spike's call-dispatch pattern). Run → PASS. **Checkpoint.**

### Task 4: Trivial core + `wl_list`

**Files:** Create `modules/libwayland_shim/core_trivial.jai`, `tests/shim_list_test.jai`.

**Produces:** `wl_proxy_get_version`, `wl_proxy_get_id`, `wl_proxy_destroy`, `wl_proxy_wrapper_destroy`,
`wl_display_flush`, `wl_event_queue_destroy`, `wl_list_init/insert/remove` (all `#program_export #c_call`).

- [ ] **Failing test first:** `wl_list` init/insert/remove maintains the intrusive doubly-linked
  invariants (next/prev) — table-driven over a small sequence. Run → fail.
- [ ] Implement `wl_list_*` (textbook intrusive list) + the accessors over `Wl_Proxy`/`Wl_Display`
  (`wl_display_flush` → `wayland_send(*display.conn, *display.out)`).
- [ ] Run test → PASS. **Checkpoint.**

### Task 5: Queue engine — demux, dispatch, roundtrip, listeners

**Files:** Create `modules/libwayland_shim/queues.jai`, `tests/shim_dispatch_test.jai`.

**Produces:** `wl_display_create_queue[_with_name]`, `wl_proxy_set_queue`, `wl_proxy_create_wrapper`,
`wl_proxy_add_listener`, `wl_display_dispatch_queue[_pending/_timeout]`, `wl_display_roundtrip_queue`,
`wl_display_dispatch_queue_pending_single` (`#program_export #c_call`); internal
`read_all_available(display)` and `decode_and_dispatch(queue)`.

- [ ] **Failing test first:** drive synthetic compositor bytes through `read_all_available` →
  events route to the correct proxy's queue; `dispatch_queue_pending` fires only that queue's listener
  vtable with decoded args; a `wl_display.sync`+`done` terminates `roundtrip_queue`. Run → fail.
- [ ] Implement: `read_all_available` drains the socket (poll(fd) for the blocking variants) into
  `ReceiveBuffer`, and for each complete message copies it (with its fds) into
  `proxies[object_id].queue.pending`. `decode_and_dispatch` pops each pending event, reads its args per
  `interface.events[opcode].signature`, and calls `listener_vtable[opcode](user_data, proxy, ..args)`
  `#c_call`. `roundtrip_queue` marshals `wl_display.sync` on the queue, flushes, dispatches until the
  callback fires. `create_wrapper`/`set_queue` reassign a proxy's queue; `add_listener` stores the
  vtable+`user_data`.
- [ ] Run test → PASS. **Checkpoint — the engine is complete and unit-proven.**

### Task 6: Interface tables (slice-1 set) + facade bring-up

**Files:** Create `modules/libwayland_shim/tables.jai` (`#program_export`'d `wl_*_interface`),
`modules/libwayland_shim/facade.jai` (connect + create `wl_display`/id-1 + registry helpers),
`examples/hello_shim_registry.jai`.

- [ ] Hand-author (or lift from game-bootstrap `Wayland_Client/protocol.generated.jai`) the
  `wl_interface`/`wl_message` tables for: `wl_display`, `wl_registry`, `wl_callback`, `wl_compositor`,
  `wl_surface`, `wl_shm`, `xdg_wm_base`, `xdg_surface`, `xdg_toplevel`, `zwp_linux_dmabuf_v1` (+
  `wp_presentation` if bound). `#program_export` each `<iface>_interface`; run the runtime
  back-pointer patch.
- [ ] `facade.jai`: `shim_connect() -> *Wl_Display` (wayland_connect + register display proxy id 1 +
  default queue). Expose `wl_display_handle()`/`wl_surface_handle()` accessors for the harness.
- [ ] **Smoke:** `hello_shim_registry` connects, the ICD-shaped path issues `get_registry` + roundtrip
  via our core, and we **log every `global`** Hyprland advertises. `./build.sh - hello_shim_registry`
  prints the real global list → proves marshaller+dispatch+tables work against the live compositor.
  **Checkpoint.** (Record the exact set the later WSI binds.)

### Task 7: Window setup + Vulkan swapchain harness (the milestone)

**Files:** Create `examples/hello_vkwl_swapchain.jai`; modify `first.jai` (`- hello_vkwl_swapchain`).

- [ ] Via facade calls, build the window: bind `wl_compositor`+`xdg_wm_base`, create `wl_surface`→
  `xdg_surface`→`xdg_toplevel`, commit, roundtrip for the first `configure`.
- [ ] Vulkan (vendored module): `VkInstance` (+`VK_KHR_surface`,`VK_KHR_wayland_surface`) →
  `vkCreateWaylandSurfaceKHR(wl_display_handle(), wl_surface_handle())` → physical device + queue →
  `VK_KHR_swapchain` → acquire / clear (or triangle) / present a frame; loop N frames
  (`JAI_WAYLAND_VKWL_FRAMES`).
- [ ] **Verify:** window appears under Hyprland; `grim` screenshot, Read it. Assert the interposition
  guard (no real-`libwayland` call). `ldd build/hello_vkwl_swapchain` clean of windowing/GPU libs.
  **Checkpoint — gate 2 (semantic WSI) result recorded.**

### Task 8: NVIDIA last-mile (laptop — checklist, not desktop-runnable)

- [ ] On the laptop: `nm -D --undefined` the NVIDIA Vulkan ICD; diff its `wl_*` import set vs Mesa's 26
  (note any older `wl_proxy_marshal_constructor*` variadics → same C-shim shape).
- [ ] Run `hello_vkwl_swapchain` on NVIDIA; record result + any symbol/table additions.

## Self-review notes

- Spec coverage: buckets 1/2/3, variadic C shim, queue model, milestone, NVIDIA last-mile, linkage
  thesis — each maps to a task (1,6 / 2-5 / 3 / 5 / 7 / 8 / global constraint).
- Discovery honesty: Tasks 6–7 depend on the ICD's real bind sequence; the registry log (Task 6) is the
  designed discovery hook so Task 7's interface set is empirical, not guessed.
