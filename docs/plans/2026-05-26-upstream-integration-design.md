# Upstream Integration Design — Window_Creation, Simp, GetRect, GetRect_LeftHanded

## Goal

Vendor four Jai-distribution modules (`Window_Creation`, `Simp`, `GetRect`,
`GetRect_LeftHanded`) into this repo so we can run a stock upstream
graphical example (`invaders`) against our runtime-loaded X11/GL stack —
preserving the project thesis:

- No hard linkage to `libX11`, `libGLX`, `libGL`, `libxcb`.
- No `#foreign` or `#library` declarations introduced into project code.
- Application owns the event loop.

This is the first concrete step toward Phase 6: a vendored Linux
window/graphics stack with runtime-selectable Wayland or X11 backends,
the eventual replacement for raw Wayland calls in user-facing apps.

## Non-goals

- Wayland backend dispatch inside `Window_Creation` (deferred to a later
  branch; X11 is enough to prove the vendoring pattern).
- Cross-platform paths. `linux.jai` is in scope; `windows.jai`,
  `macos.jai`, `android.jai` are vendored but untouched.
- Replacing or refactoring upstream's module structure. Patches stay
  surgical.
- Audio. invaders ships WAV files but no audio import surfaces in a quick
  grep; we resolve audio in Checkpoint 4 (validation), not in design.

## Approach

**Approach 1 — vendor + standalone build target.** Our `first.jai` gains
an `invaders` target that creates a workspace with our `modules/` first
on `import_path`, compiles upstream's `source/invaders.jai` directly by
absolute path, and launches the result with CWD = upstream's invaders
directory so asset paths resolve.

We considered two alternatives:

- **Approach 2** — reuse upstream's own `first.jai` with adjusted
  `import_path`. Rejected because upstream's `first.jai` has 200+ lines
  of Android/Switch2 cross-compile scaffolding and is awkward to override
  from a parent metaprogram.
- **Approach 3** — copy invaders' source into `examples/`. Rejected
  because of repo bloat (~10–30 MB of assets) and inevitable drift from
  upstream.

Approach 1 mirrors our existing `build_and_run_test` idiom, leaves
upstream untouched on disk, and the CWD trick is cheap.

## Section 1 — Branch and Vendoring Layout

**Branch:** `upstream-integration`, off `master` (`b4f2a14`).

**New directories under `modules/`:**

| Path | Lines | Patched? |
|---|---|---|
| `modules/Window_Creation/` | ~970, 5 files | No (verbatim) |
| `modules/Simp/` | ~2580 + 1500 line `backend/` | Yes, 1 line in `backend/gl.jai` |
| `modules/GetRect/` | ~1026 + `widgets/` + `system/` + `data/` | No (verbatim) |
| `modules/GetRect_LeftHanded/` | ~1010 + same shape | No (verbatim) |

**Copied:** `.jai` source files, plus `data/` subdirs of GetRect /
GetRect_LeftHanded if they contain default fonts/shaders loaded at
runtime (confirm during vendoring; likely needed for text input widget).

**Not copied:** `examples/` subdirs inside each upstream module (those
are upstream's own demos; we have our own `examples/`).

**License preservation:** Each vendored file gets a brief header
comment mirroring the existing `modules/X11/module.jai` style:

```jai
// Vendored from ~/jai/jai/modules/<Module>/<file>.jai.
// <Optional note about modifications, or "Verbatim copy.">
```

**Commit shape:** One commit per vendored module (4 verbatim-copy
commits), then separate commits for the two patches. History stays
legible — anyone reading later can diff "what's ours" vs. "what's
upstream's" cleanly.

## Section 2 — Module Path Order Injection

Jai's compiler walks `Build_Options.import_path` in order; first match
wins. The new build target prepends our `modules/` ahead of the stdlib
modules path.

```jai
upstream_import_path :: () -> [] string {
    home := to_string(getenv("HOME"));
    return string.[
        "modules",                            // ours wins
        tprint("%/jai/jai/modules", home),    // stdlib for everything else
    ];
}
```

`getenv("HOME")` is the one environment-variable concession (every Linux
tool resolves install-relative paths this way). If a future contributor
needs a non-`~/jai/jai` install location, a `--jai-install-path=` CLI
flag is the right escape hatch — not adding more env vars.

**Resolution outcomes for upstream invaders' `#import` calls:**

| Import | Resolves to | Reason |
|---|---|---|
| `Window_Creation` | `modules/Window_Creation` (ours) | Vendored |
| `Simp` | `modules/Simp` (ours) | Vendored |
| `X11` (transitive) | `modules/X11` (ours) | Vendored, runtime-loaded |
| `GL` (transitive) | `modules/GL` (ours) | Already exists, runtime-loaded |
| `Basic`, `Math`, `Input`, `Hash_Table`, `Pool`, `Sloppy_Math`, `stb_image*` | `~/jai/jai/modules/...` | Stdlib, unmodified |

**Asset CWD handling:** The invaders target does *not* use
`Autorun.run_build_result_of_workspace` (which would inherit compile-time
CWD = our repo root, breaking invaders' relative `data/` paths). Instead,
after compile, the target uses `Process.run_command` with
`working_directory = upstream_invaders_dir`. The launched binary then
finds `data/sprites/bug1.png` etc. exactly where it expects.

**Why prepend, not replace:** Replacing the stdlib path would break
`#import "Basic"`, `#import "Math"`, etc. — modules we have no intention
of vendoring. Prepending is strictly safer.

## Section 3 — The Minimal Patches

Two files patched. Everything else is verbatim vendor.

### Patch 1 — `modules/X11/module.jai` (our existing module)

Stock `init_global_display` opens an X display, sets up atoms, creates an
input method — but it doesn't load the libX11/libGLX function pointers
itself (we expect callers to invoke `init_x11()`/`init_glx()` separately).
For upstream `Window_Creation/linux.jai` calling `init_global_display()`,
we'd have to patch Window_Creation too — undesirable.

Better: **make `init_global_display` self-initializing.** Add ~6 lines at
the top of its body:

```jai
init_global_display :: () {
    if !init_x11() {
        log_error("Failed to load libX11");
        exit(1);
    }
    if !init_glx() {
        log_error("Failed to load libGLX/libGL");
        exit(1);
    }
    // ... existing body unchanged ...
}
```

`init_x11` and `init_glx` are idempotent (per `modules/X11/loader.jai`),
so existing `x11_smoke` / `hello_x11_gl` examples that call them
explicitly remain correct — second call is a no-op. **And
Window_Creation/linux.jai becomes a pristine verbatim copy.**

### Patch 2 — `modules/Simp/backend/gl.jai` (1 line)

Stock line 70:

```jai
gl_load(*gl);  // populates the GL_Procedures struct
```

Patched:

```jai
gl_load(glXGetProcAddress);  // populates our top-level function-pointer vars
```

Stock Jai GL is struct-based (`gl: GL_Procedures` + `using gl;`); ours is
bare top-level function-pointer variables. **Call sites are identical
either way** (`glViewport(...)` works because of `using gl`), so every
other line in `backend/gl.jai` stays unchanged. `glXGetProcAddress` is
visible because `Simp/module.jai` already does `#import "X11"` on Linux
(line 52), and our X11 module exports it.

### What is *not* patched

- `modules/Window_Creation/{module,linux,windows,macos,android}.jai` —
  0 patches.
- `modules/Simp/{module,bitmap,font,immediate,shader,texture,texture_format}.jai`
  — 0 patches (only `backend/gl.jai`).
- `modules/GetRect/`, `modules/GetRect_LeftHanded/` — 0 patches.
- Stock `Input` module — not vendored. Resolves to `~/jai/jai/modules/Input/`
  via the second path entry. Input's `x11.jai` does `#import "X11"`
  which then resolves to our vendored X11, inheriting the function
  pointers `init_global_display` loaded. Transitive wiring by path order
  alone.

### Known risk

If anywhere inside Simp (especially `backend/gl.jai` lines 80–1097) the
code references `gl.<field>` directly (rather than the `using`-aliased
bare form), that compile site fails against our GL module because we
have no `gl` global. The initial grep shows the only struct-prefix
access is `gl_load(*gl)` itself. We discover any others at Checkpoint 1
and patch site-by-site. The user has acknowledged this — more patches
likely as we go.

## Section 4 — Build Target Shape

New target in `first.jai`:

```jai
case "invaders";
    build_and_run_upstream_example(
        workspace_name = "invaders",
        executable_name = "invaders",
        upstream_dir    = tprint("%/jai/jai/examples/invaders",
                                  to_string(getenv("HOME"))),
        source_subpath  = "source/invaders.jai",
    );
    set_build_options_dc(.{do_output=false});
```

New generic helper, structurally identical to `build_and_run_test` with
three deltas:

```jai
build_and_run_upstream_example :: (
    workspace_name: string,
    executable_name: string,
    upstream_dir: string,
    source_subpath: string,
) {
    w := compiler_create_workspace(workspace_name);
    if !w  { print("% workspace creation failed.\n", workspace_name); return; }

    opts := get_build_options(w);
    set_optimization(*opts, .DEBUG);
    opts.arithmetic_overflow_check = .FATAL;
    opts.output_executable_name = executable_name;
    opts.output_path = "build";
    opts.import_path = upstream_import_path();   // delta 1
    make_directory_if_it_does_not_exist("build");
    set_build_options(opts, w);

    compiler_begin_intercept(w);
    add_build_file(tprint("%/%", upstream_dir, source_subpath), w);  // delta 2
    while true {
        message := compiler_wait_for_message();
        if message.kind == {
            case .COMPLETE;
                mc := cast(*Message_Complete) message;
                if mc.error_code != .NONE  exit(1);
                break;
        }
    }
    compiler_end_intercept(w);

    binary := tprint("%/build/%", #filepath, executable_name);
    result := run_command(binary, working_directory = upstream_dir);  // delta 3
    if result.exit_code != 0  exit(result.exit_code);
}
```

The helper generalizes — adding `skeletal-animation` (or any future
upstream example) is one new `case` plus four named-argument values.

`upstream_import_path` lives at the top of `first.jai`. Existing
targets (`hello_gl`, `headless_vulkan`, etc.) are unaffected — they
keep using the compiler-default import path.

`build.sh - invaders` is added to the list of valid args in
`first.jai`'s `compiler_report` and to `AGENTS.md` / `CLAUDE.md` build
commands.

## Section 5 — Validation Plan

Four checkpoints, in increasing order of confidence. Each gates the
next.

### Checkpoint 1 — Compilation gates pass

**Signal:** `./build.sh - invaders` exits 0 at the compile-end step.
`build/invaders` exists.

**Defends against:** Module path order broken; struct/proc signature
mismatch between our X11/GL and what Simp/Window_Creation expect.

**On failure:** Patch the named site (most likely a `gl.<field>` access
into a missing struct, or a proc we forgot to export from our X11).
Iterate.

### Checkpoint 2 — ldd invariant holds

**Signal:** `ldd build/invaders` shows only `libc.so.6` + `linux-vdso.so.1`
+ `ld-linux-x86-64.so.2`. No `libX11`, `libGLX`, `libGL`, `libxcb`,
`libXau`, `libXdmcp`.

**Defends against:** A transitive `#foreign` slipped through — most
likely from a stdlib module we picked up via path order that we
expected to be safe.

**On failure:** `ldd` names the leaked library. `grep -rn '#library\|#foreign'`
in the offending module to locate the link directive. Either vendor a
runtime-loaded replacement or drop the dependency.

### Checkpoint 3 — Launch + first frame

**Signal:** Binary launches, opens a window, renders ≥60 non-corrupt
frames, exits cleanly on close.

**Defends against:** Init order wrong; null-pointer crash on first
XLib/GLX/GL call; GLX configure failing silently.

**On failure:** `gdb build/invaders` (cd'd to upstream invaders) — the
backtrace pinpoints the unloaded symbol. Add to our X11 or GL loader.

### Checkpoint 4 — Full play-through (the "done" bar)

**Signal:** Boots to main screen; accepts keyboard input (move, shoot);
spawns waves; plays sound effects if invaders has audio; handles death
and restart; exits cleanly.

**Defends against:** Keysym mapping wrong; frame pacing broken; audio
uninit.

**On failure:** Triage by symptom — Input broken → check Input/x11.jai
event flow; visual glitch → Simp drawing path; audio missing → resolve
the audio known-unknown below.

### Audio — explicit known-unknown

A quick grep showed no audio module in invaders' source `#import`
list, but invaders ships WAV files. Possibilities: (a) silent
fallback when no audio backend, (b) audio loaded via a path the grep
missed, (c) audio conditionally compiled out on this platform.
**Resolved at Checkpoint 4**, not designed for upfront.

### Validation evidence

Each checkpoint produces a one-line confirmation in commit messages as
we hit it (e.g. `feat: invaders compiles against vendored modules
(Checkpoint 1)`). Branch is mergeable once all four pass.

## File Inventory

What this design touches when implemented:

**New (vendored, mostly verbatim):**
- `modules/Window_Creation/{module,linux,windows,macos,android}.jai`
- `modules/Simp/{module,bitmap,font,immediate,shader,texture,texture_format}.jai`
- `modules/Simp/backend/{gl,gl_screenshot,none}.jai`
- `modules/GetRect/module.jai`, `widgets/...`, `system/...`, `data/...`
- `modules/GetRect_LeftHanded/...` (same shape)

**Modified:**
- `modules/X11/module.jai` — ~6 lines added in `init_global_display`
- `modules/Simp/backend/gl.jai` — 1 line changed in `backend_init`
- `first.jai` — `upstream_import_path` helper + `build_and_run_upstream_example`
  helper + `invaders` case + arg list in `compiler_report`
- `CLAUDE.md`, `AGENTS.md` — document `./build.sh - invaders` and the
  vendored modules

**Untouched:**
- Everything else.

## Open Questions

1. **Audio in invaders.** Resolved at Checkpoint 4; flagged as a
   known-unknown above.
2. **GetRect's `data/` subdir.** Confirmed-needed for default
   fonts? Verify during vendoring.
3. **stb_image transitive linkage.** Stock Jai's `stb_image` likely
   compiles its C source via `#foreign` or build-time gcc invocation.
   Need to verify it doesn't leak a link-time `libpng` / `libz`
   dependency. Investigate during Checkpoint 2.

## References

- `~/jai/jai/modules/Window_Creation/linux.jai:7` — `#import "X11"`
  splice point
- `~/jai/jai/modules/Window_Creation/linux.jai:83` — `create_window`
  entry; calls `init_global_display`
- `~/jai/jai/modules/X11/module.jai:131` — `init_global_display`
  definition (mirrored at line 133 in our vendored X11)
- `~/jai/jai/modules/Simp/module.jai:52` — `#import "X11"` on Linux
- `~/jai/jai/modules/Simp/backend/gl.jai:70` — `gl_load(*gl)` patch site
- `~/jai/jai/modules/GL/GL.jai:64` — stock `gl_load` signature
- `modules/X11/loader.jai` — our `init_x11`/`init_glx` (idempotent)
- `modules/GL/loader.jai` — our `gl_load(get_proc)` signature
- `modules/X11/module.jai:133` — our vendored `init_global_display`
  (patch target)
- `first.jai:93` — our existing `build_and_run_test` (helper to mirror)
- `~/jai/jai/examples/invaders/source/invaders.jai` — build target
- `~/jai/jai/examples/invaders/data/` — runtime assets dir
