# libwayland-client proxy (duck-type) — design

**Status: DESIGN AGREED 2026-06-24.** Branch `libwayland-client-proxy` (jai-wayland sandbox).

**Goal:** Prove that our from-scratch native Wayland client can masquerade as `libwayland-client`
behind `vkCreateWaylandSurfaceKHR`, so the Vulkan driver owns the swapchain present (the path NVIDIA
forces) while real `libwayland-client` is never used. If proven here, the technique gets pulled into
`~/projects/game-bootstrap`.

**This is a sandbox proof, not a product.** game-bootstrap's real-`libwayland` path (dlopen the real
lib) stays the official route until the facade actually presents a frame.

---

## Why (the forcing function, and the reframe)

Native-Wayland present on NVIDIA is driver-owned: the only sanctioned path is `VkWaylandSurfaceKHR` +
`VK_KHR_swapchain`, which requires a real `libwayland` `wl_surface`. Our hand-rolled `dmabuf`-direct
present works on Mesa but is structurally foreclosed on NVIDIA (the ICD advertises DRM modifiers with
vendor byte `0x03`; the compositor advertises them vendor-zeroed — empty intersection). See
game-bootstrap `docs/research/2026-06-14-libwayland-client-gatekeeps-native-wayland.md` and the
windowing decision `docs/plans/2026-06-14-windowing-architecture-decision.md`.

That decision weighed **Option 3 — "duck-type libwayland"** as *"VIABLE and PRESERVES the engine, but
the most complex option"* and chose Option 2 (adopt the real lib). The cost that tipped it was named as
*"libwayland's multithreaded multi-queue dispatch."* That cost was **over-priced by a now-falsified
assumption that libwayland manages internal threads** — it spawns none (verified: pthread symbols are
mutex/cond self-protection only; all dispatch is caller-driven). Removing that misconception is what
reopens Option 3, which this branch revisits in the sandbox where the native client is alive.

Secondary motive (the NPE irritation): the real-lib path forces participation in libwayland's
all-or-NULL listener model — you either supply every callback or risk a null-dispatch crash, including
performative no-ops for events you don't care about. Owning the client lets us add support
incrementally with no performative ceremony. Moot until the facade presents, but a real pull.

## The linchpin — PROVEN (gate 1, green)

`spikes/symbol-scope/` proved on the AMD/Mesa desktop (2026-06-24) that a Jai **executable**
`#program_export`s a C-ABI `wl_*` symbol into `.dynsym` (Jai's default link already passes
`-export-dynamic` — **no `first.jai` config needed**) and **interposes** over a *real*
`libwayland-client.so.0` that a dlopened ICD pulls in via `DT_NEEDED`. Proven by call dispatch, not
just address: a fake ICD (gcc `-lwayland-client`, mirroring the real ICD's ELF shape) called
`wl_proxy_get_version(NULL)` and got our `0xDEADBEEF` sentinel; the real `/usr/lib/libvulkan_radeon.so`
also dlopens fine in the same process. The one all-or-nothing risk — can our symbols get in front of
the driver — is retired.

---

## What must be shadowed — the three buckets

The split falls almost entirely on the generatable side; the exception is the engine.

1. **Generated AND a symbol the ICD imports — the 8 `wl_*_interface` data tables.** game-bootstrap's
   `modules/wayland/code-generator/src/libwayland_emit.jai` (`emit_interface_tables`) already emits
   these in byte-exact wayland-scanner layout (one documented ABI-identical divergence: per-interface
   `types` arrays + a runtime back-pointer patch to dodge Jai's initializer cycles). For the proxy we
   reuse that output verbatim and mark each `<iface>_interface` global `#program_export`. Trivial
   generator change.

2. **Generated, but never symbols we provide — the request wrappers + listener structs.** These are
   the Jai twins of libwayland's `static inline` header wrappers. Because they're static-inline in C,
   the ICD compiles its own copies and never imports them. We keep them for our own client-side calls;
   they are irrelevant to satisfying the ICD.

3. **Hand-crafted — the ~15 core functions the ICD actually imports.** These are exactly the symbols
   `Wayland_Client/core.generated.jai` currently `dlsym`s from real libwayland. Nothing in the XML
   generates them; they ARE the runtime:
   - **Trivial** (over the native client's object map + connection): `wl_proxy_get_version`,
     `wl_proxy_get_id`, `wl_proxy_destroy`, `wl_proxy_wrapper_destroy`, `wl_display_flush`,
     `wl_event_queue_destroy`, `wl_list_init/insert/remove`.
   - **Engine, piece A — the runtime marshaller:** `wl_proxy_marshal_array_flags` (pure Jai) walks the
     `wl_message` signature the generated tables hand it, packs a `wl_argument[]` to the wire, allocates
     the `new_id` proxy when the request creates one. This is the *runtime-signature-driven* sibling of
     the native module's compile-time `marshal` macro.
   - **Engine, piece B — the multi-queue event engine:** `wl_proxy_add_listener` (store a `#c_call`
     vtable on the proxy), `wl_proxy_create_wrapper`/`wl_proxy_set_queue`, `wl_display_create_queue[_with_name]`,
     `wl_display_dispatch_queue[_pending/_timeout]`, `wl_display_roundtrip_queue`.

**The symmetry (the good news):** game-bootstrap's `Wayland_Client` is the mirror image of the facade —
generated tables/wrappers/listeners + a core `dlsym`'d from real libwayland. The proxy keeps the
generated half verbatim and *replaces the dlsym'd core with our own implementation over the native wire
client*. The generatable work is effectively done; the new work is a fixed ~15-function core, not an
N-interface explosion.

## The variadic boundary — exactly one C file

The ICD imports the **variadic** `wl_proxy_marshal_flags(proxy, op, iface, ver, flags, ...)`. Jai
**cannot author a C-variadic**: its only vararg facility is `..Any` (which needs Jai type-info raw C
varargs lack); the compiler rejects even forwarding (`"Cannot spread varargs into a #c_call"` —
`~/jai/jai/modules/Android/Jni.jai:263`); `Bindings_Generator` punts on `va_list` params as opaque
`*void`; no `va_arg`/`va_start` exists. Jai's own JNI module hit this identical wall and worked around
it by calling the **array form** (`Call*MethodA`) instead of the variadic — the same move
`emit_requests` already makes with `wl_proxy_marshal_array_flags`.

We can't dodge it on the *provider* side (the ICD picks the variadic). So **one ~30-line C file**
implements `wl_proxy_marshal_flags` (lifted from libwayland's MIT `wl_argument_from_va_list`: `va_start`
→ walk `iface->methods[op].signature` → `va_arg` each → fill `wl_argument[]`) and tail-calls our
pure-Jai `wl_proxy_marshal_array_flags`. That is the entire C surface. It's our own compiled-in object —
**no external library, linkage thesis intact.** (NVIDIA's ICD may also import the older
`wl_proxy_marshal_constructor[_versioned]`/`wl_proxy_marshal` — same shim shape; confirm via
`nm -D --undefined` on the laptop.)

---

## Architecture

```
  Vulkan ICD (Mesa radeon / NVIDIA)         <- dlopen'd by the Vulkan loader
        | imports (undefined wl_*)
        v
  ┌─────────────────────────────────────────┐
  │  modules/libwayland_shim   (NEW)         │
  │   - #program_export'd wl_*_interface     │  <- generated tables (bucket 1)
  │   - #program_export'd ~15 core wl_*      │  <- hand-crafted engine (bucket 3)
  │   - wl_marshal_varargs.c  (~30 lines)    │  <- the one C file (variadic entry)
  └───────────────┬─────────────────────────┘
                  | builds on
                  v
  ┌─────────────────────────────────────────┐
  │  modules/wayland   (EXISTING, native)    │
  │   Connection / object-id allocator /     │
  │   marshal / unmarshal / wire             │
  └─────────────────────────────────────────┘
```

- **Substrate:** the existing native `wayland` module is the wire engine — its `Connection`, object-id
  allocator, and wire read/write primitives are reused, not rewritten. The shim never opens its own
  socket conceptually distinct from the native client; there is one connection, one fd.
- **`wl_display*` / `wl_surface*` handed to Vulkan are our own objects** cast to the opaque handles.
  The ICD only ever touches them through the `wl_*` functions we export, so their layout is ours.
- **Object identity:** `wl_proxy` is our proxy record (id + interface + version + queue + listener
  vtable + user_data). Server-allocated ids (the ICD's `new_id` results from the compositor) ride the
  native `unmarshal` `*Interface` path; client ids stay in the native allocator's space (disjoint).

## The engine & queue model (crux #2), with a recon-driven simplification

The radeon ICD imports `wl_display_dispatch_queue[_pending/_timeout]` and `wl_display_roundtrip_queue`
but **not** `wl_display_prepare_read`/`read_events`/`cancel_read` — the WSI drives its own private queue
through `dispatch_queue`/`roundtrip_queue`; it does **not** use the manual reader handshake. That
collapses the model to a single-owner demultiplexer:

- **One socket-read routine** pulls all currently-available messages and routes each event to the
  target proxy's **assigned queue's buffer** (default queue, or a queue created via
  `wl_display_create_queue` + `wl_proxy_set_queue`/`create_wrapper`).
- **Each consumer dispatches only its own queue:** our pump drains the default queue (our window/input,
  later); the ICD drains its queue via `dispatch_queue`. Neither steals the other's events because
  routing happens at read time, before dispatch.
- **`wl_display_roundtrip_queue`** = send a `wl_display.sync` bound to that queue, then read+dispatch
  that queue until the sync `done` fires.
- **`wl_proxy_add_listener`** stores the C vtable + `user_data`; dispatch invokes
  `vtable[opcode](user_data, proxy, ...args)` as a `#c_call`, decoding args per the event signature.
- **Single-threaded for slice 1**, faithful to game-bootstrap's settled single-thread/single-window
  model: the ICD's WSI calls (`vkAcquireNextImageKHR`/`vkQueuePresentKHR`) land on our render thread,
  strictly sequenced with our pump. Multithread generality (the prepare_read locking) is deferred —
  and the Mesa ICD does not even request it.

## Interface set — discovered empirically, not guessed

A Wayland swapchain needs a role-assigned, configured surface, so the minimal real proof is a visible
`xdg_toplevel` window presenting through the swapchain — not a bare surface. Expected hand-stub set for
slice 1: `wl_display`, `wl_registry`, `wl_compositor`, `wl_surface`, `xdg_wm_base`, `xdg_surface`,
`xdg_toplevel`, plus whatever the WSI binds for buffers (`zwp_linux_dmabuf_v1`, possibly
`wp_presentation`). **We do not guess the set:** the facade's `wl_registry` logs every global the ICD
tries to bind, so the WSI declares its exact appetite on the first run. (Once proven, port
`libwayland_emit.jai` to generate the full table set for all interfaces.)

## First milestone & proving harness

`examples/hello_vkwl_swapchain.jai`: vendored `Vulkan` module → `VkInstance` (with
`VK_KHR_surface` + `VK_KHR_wayland_surface`) → `vkCreateWaylandSurfaceKHR(facade_display, facade_surface)`
→ `VK_KHR_swapchain` → acquire / clear (or triangle) / present, on a real `xdg_toplevel` window. Runs on
the AMD/Mesa desktop. Success = a visible window presents ≥1 frame driven entirely by the ICD's WSI
against our facade, with `ldd` clean of windowing/GPU libs and **no real `libwayland` symbol called**
(assert via the interposition check). Visual confirm via `grim` (see memory `visual_verification_via_grim`).

NVIDIA is the last-mile: `nm -D --undefined` its ICD for symbol-set deltas, then the same harness on the
laptop.

## Build wiring

- New `modules/libwayland_shim/` (Jai) + `wl_marshal_varargs.c`.
- The C file → `.o` via gcc in `first.jai` (we already invoke gcc), linked into the example via
  `Build_Options.additional_linker_arguments` (the `.o` path). No external `#library`.
- `#program_export` on the core procs and the `wl_*_interface` tables. **No linker-arg config needed**
  for export (Jai links `-export-dynamic` by default — proven).
- The example links the vendored `Vulkan` module (runtime-loaded; no `libvulkan` at link).

## Testing strategy

- **Unit (project's table-driven pattern, à la `wire_test`/`marshal_test`):** the runtime marshaller
  (signature string → wire bytes, incl. `new_id`, `fd`, `string`, `array`, untyped-`new_id` "sun"
  expansion) and the queue demux (events route to the right queue; `dispatch_queue` only fires its
  queue's listeners; roundtrip terminates on `sync.done`).
- **Integration:** the harness renders a window; `grim` screenshot Read in-session. An interposition
  assert (our sentinel / address check) guarantees no real-libwayland call slipped through.
- **NVIDIA:** the harness on the laptop after the symbol-delta check.

## Risks & open questions

- **The full symbol/data surface beyond slice 1** — NVIDIA may import older `marshal_constructor*`
  forms (same shim shape) and a slightly different table set; the laptop `nm` settles it.
- **Data-symbol (interface-table) interposition** — slice-1 proves function interposition; the tables
  are *data* symbols. As the *defining executable* we're on the favorable side, but confirm the ICD
  binds our `wl_surface_interface` (not a coincidentally-loaded real one) the first time the WSI
  marshals an object arg.
- **`wl_argument` / `wl_array` / `wl_fixed_t` ABI** must match libwayland byte-for-byte (already typed
  in `Wayland_Client/core.generated.jai` — reuse those definitions).
- **Multithread present** (a render thread distinct from the pump) is explicitly **out of scope** for
  the proof; revisit only if the single-thread model can't carry a real game loop.

## Out of scope

Full generator port (after slice 1), NVIDIA-specific modifier negotiation (the swapchain owns it),
multithreaded reader coordination, and any game-bootstrap integration (that follows a successful proof).

## Provenance

- Reopens Option 3 of game-bootstrap `docs/plans/2026-06-14-windowing-architecture-decision.md`.
- Mechanism/grief: game-bootstrap `docs/research/2026-06-14-libwayland-client-gatekeeps-native-wayland.md`,
  `docs/research/2026-06-15-the-nvidia-wayland-reckoning.md`.
- Generator to reuse: game-bootstrap `modules/wayland/code-generator/src/libwayland_emit.jai`,
  `modules/Wayland_Client/{core,protocol}.generated.jai`.
- Gate-1 proof: `spikes/symbol-scope/` (this repo). Memory: `libwayland-proxy-linchpin`.
