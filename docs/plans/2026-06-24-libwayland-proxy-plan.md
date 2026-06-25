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
- **Task 5 — event/dispatch engine: DONE + unit-proven (pure-logic half).** `queues.jai` +
  `tests/shim_dispatch_test.jai` (PASS: demux routing + decode + the **wide-signature invoke** delivering
  data/proxy/uint/string). Decision banked: the listener-invoke needs **no C** — a fixed 12-`u64`
  `#c_call` signature is ABI-safe on x86-64 SysV for Wayland's all-integer/pointer args. `create_queue`/
  `set_queue`/`create_wrapper`/`add_listener`, `dispatch_queue[_pending/_timeout]`, `roundtrip_queue`
  implemented; the live-socket parts (blocking read, roundtrip) await a real compositor.
- **Task 6 — real interface tables + facade + live registry: DONE + proven against live Hyprland.**
  `tables.jai` carries game-bootstrap's byte-exact `wl_*`/`xdg_*` interface graph (28 interfaces) +
  the `wl_protocol_tables_init` back-pointer patch + opcodes (lifted verbatim — ABI-identical structs;
  Jai string literals convert to the `*u8` name/signature fields). `facade.jai` = `shim_connect` /
  `shim_get_registry` / `shim_roundtrip`. `examples/hello_shim_registry.jai` drives `get_registry` +
  `wl_display.sync` round-trip entirely through OUR engine and logs every global — output is
  **byte-identical to the native `hello_globals` path (68 globals)** and `ldd` is libc-only. (commit
  d62af44.) This exercised `roundtrip_queue`, the live blocking read, demux, and wide-signature dispatch
  end-to-end. **WSI bind set discovered** (for Task 7): `wl_compositor v6`, `wl_shm v2`, `xdg_wm_base v7`,
  `wl_seat v9`, `wl_output v4`, `zwp_linux_dmabuf_v1 v5`, `wp_linux_drm_syncobj_manager_v1 v1`, `wl_drm v2`.
- **Gate 2 precondition — DATA-symbol interposition: PROVEN (`spikes/data-export/`, commit 8263b79).**
  `#program_export` works on Jai globals (lands in `.dynsym` as `OBJECT/GLOBAL`, bare C name); a fake ICD's
  `extern` data ref binds to OUR exported table even when it `DT_NEEDED`s a stand-in real-libwayland
  defining the same symbol (reads our `0xC0FFEE`, not the provider's `0xDEAD`). So **Task-7 mechanism is
  settled**: `#program_export` each `<iface>_interface`; no C-owned data tables. (`st_size` Jai reports is
  bogus but irrelevant — name-based resolution, no COPY relocations.)
- **Task 7 — Vulkan swapchain harness: DONE + proven against live Hyprland (gate-2 SEMANTIC: GREEN).**
  `examples/hello_vkwl_swapchain.jai` builds an xdg_toplevel through OUR shim, hands the bare
  `wl_display`+`wl_surface` to `vkCreateWaylandSurfaceKHR`, and the RADV ICD owns a 4-image swapchain it
  presents through OUR engine (600/120 frames, color-cycled clear, Hyprland tiled+resized the managed
  window). `first.jai` compiles+links the one C bridge (`wl_marshal_varargs.o`) → **26/26** ICD symbols in
  `.dynsym`. `ldd` libc+libdl only; `/proc/self/maps` confirms no real libwayland. Facade gained
  `shim_request`/`shim_pump`. **Banked finding:** global interposition also hijacks co-resident
  real-libwayland users — the MESA device-select/MangoHud/anti-lag implicit Vulkan layers crash our
  marshaller; the harness disables them via `setenv` (their JSON `disable_environment` vars) before the
  loader reads them. **The duck-type thesis is now PROVEN end-to-end on Mesa/AMD.**
- **RESUME HERE → Task 8 (NVIDIA last-mile — laptop only):** `nm -D --undefined` the NVIDIA Vulkan ICD,
  diff its `wl_*` import set vs Mesa's 26 (watch for older `wl_proxy_marshal_constructor*` variadics — same
  C-shim shape), then run `hello_vkwl_swapchain` on NVIDIA and record the result + any symbol/table
  additions. Driver-agnostic ELF interposition should hold; the open question is the NVIDIA ICD's exact
  WSI bind/dispatch sequence through our engine.

Committed through Task 6 + the gate-2 data spike (`git log`: …b9b53af Task 5 done, d62af44 Task 6, 8263b79
data-export spike). **Engine, tables, facade, and BOTH interposition gates are proven**; what remains is
the Vulkan swapchain wiring (Task 7) and the NVIDIA last-mile (Task 8, laptop). Build standalone shim
tests with `~/jai/jai/bin/jai-linux tests/shim_<x>_test.jai`; build the live registry smoke with
`./build.sh - hello_shim_registry` (binaries gitignored via `/tests/shim_*test`).

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

**Exact ICD import surface (Mesa radeon, discovered 2026-06-24 via `nm -D --undefined
/usr/lib/libvulkan_radeon.so`):** 26 symbols total. **8 DATA tables** — `wl_buffer`, `wl_callback`,
`wl_fixes`, `wl_output`, `wl_registry`, `wl_shm`, `wl_shm_pool`, `wl_surface` `_interface` (NOT
`wl_compositor`/`xdg_*`/`zwp_linux_dmabuf_v1` — the app creates those, and Mesa bundles its own dmabuf).
**18 FUNCS** — `wl_proxy_{marshal_flags,add_listener,destroy,wrapper_destroy,get_id,get_version,
set_queue,create_wrapper}`, `wl_display_{flush,roundtrip_queue,dispatch_queue,dispatch_queue_pending,
dispatch_queue_timeout,create_queue_with_name}`, `wl_event_queue_destroy`, `wl_list_{init,insert,remove}`.
**Every one is already implemented** (the 8 tables in `tables.jai`; `wl_proxy_marshal_flags` in the C
varargs shim; the other 17 in queues/core_trivial/marshal_runtime). It imports the **variadic**
`wl_proxy_marshal_flags`, not the array form — validating the C bridge. It does NOT import
`prepare_read`/`read_events` — confirming the single-owner queue model.

- [x] **Export surface — DONE (no obstacle; plain `#program_export` suffices).** Verified on
  `build/hello_shim_registry`: **25 of the ICD's 26 symbols already export** — all 8 `wl_*_interface`
  DATA tables (`OBJECT GLOBAL DEFAULT`) and all 17 needed Jai procs (`FUNC GLOBAL DEFAULT`), with NO
  keepalive, NO special linker args. The 26th, `wl_proxy_marshal_flags`, is the C varargs shim — it
  enters when its `.o` is linked (next bullet); the compiled `wl_marshal_varargs.o` defines
  `T wl_proxy_marshal_flags` with an undefined ref to our Jai-exported `wl_proxy_marshal_array_flags`, so
  linking it yields 26/26.
  **CORRECTION (2026-06-24):** an earlier note here claimed ~9 procs failed to export. That was a
  **measurement artifact**, not a real issue — `readelf --dyn-syms` *without* `-W` truncates symbol
  names to ~25 columns, so an end-anchored `grep` for names ≥26 chars (`wl_display_roundtrip_queue`,
  `wl_display_create_queue_with_name`, …) silently missed them; the same truncation made the `-u` /
  `--no-gc-sections` / `--export-dynamic-symbol` relink probes look like failures. **Lesson: always use
  `readelf -W` (and don't end-anchor on possibly-truncated names) when auditing the export surface.**
  The keepalive experiment was unnecessary and was reverted.
- [x] **Wire the C varargs shim into the build — DONE.** `first.jai` gained `compile_c_object` (gcc
  `-c -O2 -fPIC`) and a `link_objects` param on `build_and_run_test` that sets
  `Build_Options.additional_linker_arguments`. The `hello_vkwl_swapchain` case compiles
  `wl_marshal_varargs.c` → `build/wl_marshal_varargs.o` and links it. Verified: all **26/26** ICD-imported
  `wl_*` symbols are now in `.dynsym` (`readelf -W`), including `wl_proxy_marshal_flags` from the `.o`.
- [x] **Build the window via facade — DONE.** Added `shim_request` (generic marshal primitive over
  `marshal_impl`, since it is `#scope_module`) and `shim_pump` (flush + non-blocking read + dispatch the
  DEFAULT queue) to `facade.jai`. The harness binds `wl_compositor`+`xdg_wm_base`, creates
  `wl_surface`→`xdg_surface`→`xdg_toplevel`, sets title, commits, and pumps to the first `configure`
  (acked). `xdg_wm_base.ping`→`pong`, `xdg_surface.configure`→`ack`, `xdg_toplevel.configure/close`
  serviced each frame.
- [x] **Vulkan swapchain — DONE.** `examples/hello_vkwl_swapchain.jai`: `VkInstance`
  (+`VK_KHR_surface`,`VK_KHR_wayland_surface`) → `vkCreateWaylandSurfaceKHR(our wl_display, our wl_surface)`
  → physical device whose graphics queue family passes `vkGetPhysicalDeviceSurfaceSupportKHR` on OUR
  surface → device (+`VK_KHR_swapchain`) → swapchain (`TRANSFER_DST` usage, FIFO) → per-frame acquire /
  `vkCmdClearColorImage` (color-cycled) / submit / present; loop N (`JAI_WAYLAND_VKWL_FRAMES`, default
  240). `VkWaylandSurfaceCreateInfoKHR` + `vkCreateWaylandSurfaceKHR` are declared in the harness (the
  vendored module was generated without the Wayland platform define).
- [x] **Verify — DONE (gate 2 SEMANTIC result: GREEN).** Under live Hyprland the RADV ICD created a
  **4-image B8G8R8A8 swapchain on OUR surface** and **presented 600 / 120 frames** (`grim`'d twice — the
  window clear color cycled yellow-green→magenta, Hyprland tiled+resized it via a second
  `xdg_toplevel.configure`, i.e. it managed a real mapped toplevel taking real buffers). The ICD drove
  `get_registry`/`bind`/`wl_buffer`/`attach`/`commit`/frame-callbacks entirely through OUR engine.
  Interposition asserted in-process (`/proc/self/maps` has no `libwayland-client`) and
  `ldd build/hello_vkwl_swapchain` is libc+libdl only — **no windowing/GPU libs**. `./build.sh -
  hello_vkwl_swapchain` runs the canonical smoke; `compile_only` gates it headlessly.
- [x] **FINDING (banked) — global interposition hijacks ALL in-process libwayland users.** The MESA
  **device-select** implicit Vulkan layer (and MangoHud / anti-lag) open their OWN `wl_display_connect()`
  to pick a GPU; our default-visibility `wl_*` symbols captured THOSE calls too, feeding a real-libwayland
  proxy (incompatible struct layout) into our marshaller → segfault in `wl_proxy_marshal_flags` during
  `vkEnumeratePhysicalDevices`. The ICD's own WSI path uses OUR objects and is consistent; only these
  orthogonal layers conflict. The harness disables them via their JSON `disable_environment` vars
  (`NODEVICE_SELECT`/`DISABLE_MANGOHUD`/`DISABLE_LAYER_MESA_ANTI_LAG`, set with `setenv` before the loader
  reads them). **Implication for game-bootstrap:** a production duck-type must guarantee it is the ONLY
  in-process libwayland consumer, or scope/namespace the interposition (e.g. `dlmopen`, or a private
  symbol namespace) — a real design constraint, not a smoke-test wart.

### Task 8: NVIDIA last-mile — RESOLVED 2026-06-24 (the duck-type is UNNECESSARY)

The whole reason this branch existed — the belief that NVIDIA forces Vulkan WSI (won't do clean DMA-BUF
export) — is **falsified**. Both display paths run on NVIDIA pure-dGPU through the clean, libwayland-free
model:

- [x] **GL/Simp — VALIDATED.** `skeletal-animation` runs on an NVIDIA-only laptop. GBM lets you request
  `DRM_FORMAT_MOD_INVALID`; the driver picks its own native modifier and its own compositor imports it.
- [x] **Vulkan — VALIDATED.** `hello_vulkan_dmabuf`'s driver-first selection
  (`choose_image_config_driver_first`) — enumerate the Vulkan driver's own modifiers
  (`VkDrmFormatModifierPropertiesListEXT`), probe each against the compositor (async `create` +
  `created`/`failed`, driver-tiled first / `LINEAR` fallback) — **presents on an NVIDIA RTX 3050 Ti
  pure-dGPU**: the first candidate `B8G8R8A8/AR24 modifier=0x0300000000606015` (NVIDIA block-linear tiled,
  vendor byte `0x03`) goes ACCEPTED, the triangle presents. This was prototyped as
  `hello_vulkan_dmabuf_hail_mary`, then **folded into the stock `hello_vulkan_dmabuf`** (the experiment file
  was deleted; the driver-first path is now the default, with the compositor-advertised path as fallback).
- [x] **Conclusion.** The clean model-1 DMA-BUF path covers every GPU for both GL and Vulkan. The duck-type
  WSI shim (`hello_vkwl_swapchain`, the whole `modules/libwayland_shim`) is a **proven-but-unnecessary
  curiosity** — kept as the receipt that the charade *works*, not because anything needs it. The fix that
  obviated it was "do what the GL path already does": don't trust the compositor's pessimistic feedback;
  enumerate the producing driver's modifiers and let `created`/`failed` arbitrate.

## Self-review notes

- Spec coverage: buckets 1/2/3, variadic C shim, queue model, milestone, NVIDIA last-mile, linkage
  thesis — each maps to a task (1,6 / 2-5 / 3 / 5 / 7 / 8 / global constraint).
- Discovery honesty: Tasks 6–7 depend on the ICD's real bind sequence; the registry log (Task 6) is the
  designed discovery hook so Task 7's interface set is empirical, not guessed.
