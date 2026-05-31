# Upstream Integration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Vendor Jai's `Window_Creation`, `Simp`, `GetRect`, `GetRect_LeftHanded` modules into this repo and run upstream `invaders` against them with our runtime-loaded X11/GL stack, preserving the ldd-clean invariant.

**Architecture:** Verbatim vendor of 4 upstream modules under `modules/`. Two minimal patches: `modules/X11/module.jai` becomes self-initializing in `init_global_display`; `modules/Simp/backend/gl.jai` swaps its one `gl_load(*gl)` call for our `gl_load(glXGetProcAddress)` signature. New `./build.sh - invaders` target sets `import_path` to put our `modules/` first, compiles upstream's `source/invaders.jai` by absolute path, runs with `working_directory = ~/jai/jai/examples/invaders` so assets resolve.

**Tech Stack:** Jai (`~/jai/jai/bin/jai-linux`), bash, git. No new dependencies introduced.

**Design reference:** `docs/plans/2026-05-26-upstream-integration-design.md`

**Branch:** `upstream-integration` (already created, on `master` `b4f2a14`)

**Required skill before writing Jai code:** `jai-language` (per project CLAUDE.md)

---

## Validation Checkpoints (recap from design)

These are the gates. Each `checkpoint` task corresponds to one of these. Don't claim "done" until the final checkpoint passes.

| # | Signal | Defends against |
|---|---|---|
| 1 | `./build.sh - invaders` exits 0; `build/invaders` exists | Module path order broken; API mismatch with upstream |
| 2 | `ldd build/invaders` shows only `libc.so.6` + `linux-vdso.so.1` + `ld-linux-x86-64.so.2` | Transitive `#foreign`/`#library` leak |
| 3 | Binary launches, opens window, renders ≥60 non-corrupt frames | Init order; null function pointer crash |
| 4 | Full play-through: input works, waves spawn, exit clean | Keysym mapping; frame pacing; audio |

---

## Phase 1 — Vendor Upstream Modules

Each task in this phase: copy upstream files verbatim into our `modules/`, add a one-line provenance header at the top of each `.jai` file, commit. **No content changes.** Examples/ subdirs upstream are NOT copied.

The order matters only for clean commit history.

### Task 1: Vendor `Window_Creation/`

**Files:**
- Create: `modules/Window_Creation/module.jai`
- Create: `modules/Window_Creation/linux.jai`
- Create: `modules/Window_Creation/macos.jai`
- Create: `modules/Window_Creation/windows.jai`
- Create: `modules/Window_Creation/android.jai`

**Step 1: Copy verbatim**

```bash
mkdir -p modules/Window_Creation
cp ~/jai/jai/modules/Window_Creation/module.jai  modules/Window_Creation/
cp ~/jai/jai/modules/Window_Creation/linux.jai   modules/Window_Creation/
cp ~/jai/jai/modules/Window_Creation/macos.jai   modules/Window_Creation/
cp ~/jai/jai/modules/Window_Creation/windows.jai modules/Window_Creation/
cp ~/jai/jai/modules/Window_Creation/android.jai modules/Window_Creation/
```

**Step 2: Add provenance header to each file**

At the very top of each `.jai`, prepend:

```jai
// Vendored from ~/jai/jai/modules/Window_Creation/<filename>.jai.
// Verbatim copy.

```

(Replace `<filename>.jai` with the actual filename per file. Use Edit tool to insert at line 1.)

**Step 3: Verify diff vs. upstream is exactly the header**

```bash
diff <(tail -n +4 modules/Window_Creation/linux.jai) ~/jai/jai/modules/Window_Creation/linux.jai
```

Expected: no output (means everything after the 3-line header is identical).

**Step 4: Commit**

```bash
git add modules/Window_Creation/
git commit -m "vendor: Window_Creation/ from ~/jai/jai/modules/

Verbatim copy of upstream Window_Creation. Per-OS files unchanged; we
will patch via our own X11 module's init_global_display (next phase),
keeping Window_Creation a pristine vendor.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 2: Vendor `Simp/`

**Files:**
- Create: `modules/Simp/module.jai`
- Create: `modules/Simp/bitmap.jai`
- Create: `modules/Simp/font.jai`
- Create: `modules/Simp/immediate.jai`
- Create: `modules/Simp/shader.jai`
- Create: `modules/Simp/texture.jai`
- Create: `modules/Simp/texture_format.jai`
- Create: `modules/Simp/backend/gl.jai`
- Create: `modules/Simp/backend/gl_screenshot.jai`
- Create: `modules/Simp/backend/none.jai`

**Step 1: Copy verbatim**

```bash
mkdir -p modules/Simp/backend
cp ~/jai/jai/modules/Simp/*.jai            modules/Simp/
cp ~/jai/jai/modules/Simp/backend/*.jai    modules/Simp/backend/
```

**Step 2: Add provenance header to each file**

Same 3-line header pattern as Task 1, on every `.jai` (top-level and in `backend/`).

**Step 3: Verify diff per file**

```bash
for f in modules/Simp/*.jai modules/Simp/backend/*.jai; do
    upstream="$HOME/jai/jai/modules/Simp/${f#modules/Simp/}"
    if ! diff -q <(tail -n +4 "$f") "$upstream" > /dev/null; then
        echo "DIFFERENT: $f"
    fi
done
```

Expected: no output (or you missed adding a header somewhere).

**Step 4: Commit**

```bash
git add modules/Simp/
git commit -m "vendor: Simp/ from ~/jai/jai/modules/

Verbatim copy of upstream Simp including backend/gl.jai, gl_screenshot.jai,
none.jai. The single gl_load patch comes in a follow-up commit.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 3: Vendor `GetRect/`

**Files:**
- Create: `modules/GetRect/module.jai`
- Create: `modules/GetRect/widgets/...` (all `.jai` files in upstream's `widgets/`)
- Create: `modules/GetRect/system/...` (all `.jai` files in upstream's `system/`)
- Create: `modules/GetRect/data/...` (if any non-empty content)

**Step 1: List upstream contents to confirm what to copy**

```bash
ls ~/jai/jai/modules/GetRect/
ls ~/jai/jai/modules/GetRect/widgets/  2>/dev/null
ls ~/jai/jai/modules/GetRect/system/   2>/dev/null
ls ~/jai/jai/modules/GetRect/data/     2>/dev/null
```

**Step 2: Copy verbatim (excluding examples/)**

```bash
mkdir -p modules/GetRect
cp ~/jai/jai/modules/GetRect/module.jai modules/GetRect/
cp -r ~/jai/jai/modules/GetRect/widgets modules/GetRect/
cp -r ~/jai/jai/modules/GetRect/system  modules/GetRect/
# Inspect data/ first; copy only if it contains default fonts/shaders.
# If empty or only examples/test data, skip.
[ -d ~/jai/jai/modules/GetRect/data ] && cp -r ~/jai/jai/modules/GetRect/data modules/GetRect/
```

**Step 3: Add provenance header to every `.jai`**

Same pattern: `// Vendored from ~/jai/jai/modules/GetRect/<rel-path>.jai. Verbatim copy.`

**Step 4: Diff-verify per file**

Same shell loop as Task 2, adapted for GetRect.

**Step 5: Commit**

```bash
git add modules/GetRect/
git commit -m "vendor: GetRect/ from ~/jai/jai/modules/

Verbatim copy of upstream GetRect (module.jai + widgets/ + system/ + data/).
No X11/GL touch in this module — pure widget/layout logic on top of Input
and Simp. No patches expected.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 4: Vendor `GetRect_LeftHanded/`

**Files:**
- Same shape as GetRect.

**Step 1-5: Identical to Task 3 with `GetRect_LeftHanded` substituted everywhere.**

```bash
mkdir -p modules/GetRect_LeftHanded
cp ~/jai/jai/modules/GetRect_LeftHanded/module.jai modules/GetRect_LeftHanded/
cp -r ~/jai/jai/modules/GetRect_LeftHanded/widgets modules/GetRect_LeftHanded/
cp -r ~/jai/jai/modules/GetRect_LeftHanded/system  modules/GetRect_LeftHanded/
[ -d ~/jai/jai/modules/GetRect_LeftHanded/data ] && cp -r ~/jai/jai/modules/GetRect_LeftHanded/data modules/GetRect_LeftHanded/
```

Add provenance headers; diff-verify; commit with same message template.

---

## Phase 2 — Minimal Patches

### Task 5: Self-initialize `init_global_display` in our X11 module

**Files:**
- Modify: `modules/X11/module.jai:133` (insert ~8 lines at top of `init_global_display`'s body)

**Step 1: Read the current shape**

```bash
sed -n '130,145p' modules/X11/module.jai
```

Note: confirm line 133 is `init_global_display :: () {` — the file might shift if any provenance edits affected line numbers.

**Step 2: Make the edit**

Use the Edit tool. The `old_string` is the function header + first statement; the `new_string` inserts our init calls in between:

```
old_string:
init_global_display :: () {
    [first existing statement]

new_string:
init_global_display :: () {
    if !init_x11() {
        log_error("Failed to load libX11 — cannot initialize X display");
        exit(1);
    }
    if !init_glx() {
        log_error("Failed to load libGLX/libGL — cannot initialize GL stack");
        exit(1);
    }

    [first existing statement]
```

(Use the actual surrounding text from the read in Step 1 to make `old_string` unique.)

**Step 3: Verify our existing X11 examples still build identically**

```bash
./build.sh - x11_smoke
./build.sh - hello_x11_gl
```

Expected: both compile and run identically to before. The new `init_x11`/`init_glx` calls inside `init_global_display` are no-ops on second invocation (the examples still call them explicitly first).

**Step 4: Verify ldd still clean for those examples**

```bash
ldd build/x11_smoke    | grep -E 'libX|libGL|libxcb' && echo "LEAKED" || echo "clean"
ldd build/hello_x11_gl | grep -E 'libX|libGL|libxcb' && echo "LEAKED" || echo "clean"
```

Expected: both `clean`.

**Step 5: Commit**

```bash
git add modules/X11/module.jai
git commit -m "patch: make X11 init_global_display self-initialize

Insert init_x11()/init_glx() calls at the top of init_global_display so
upstream Window_Creation/linux.jai (which calls init_global_display
without first loading the function pointers) works against our X11
module unmodified.

Idempotent: existing x11_smoke and hello_x11_gl examples that call
init_x11/init_glx explicitly remain correct — second call is a no-op.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 6: Patch Simp/backend/gl.jai's `gl_load` call

**Files:**
- Modify: `modules/Simp/backend/gl.jai` (one line)

**Step 1: Find the exact line**

```bash
grep -n "gl_load(" modules/Simp/backend/gl.jai
```

Expected: one match, e.g. `70:            gl_load(*gl);` (line number may shift because of the provenance header — that's fine, anchor on the match).

**Step 2: Make the edit**

Use Edit tool with `gl_load(*gl);` as `old_string` (will be unique in the file) and `gl_load(glXGetProcAddress);` as `new_string`.

**Step 3: Verify diff**

```bash
git diff modules/Simp/backend/gl.jai
```

Expected: exactly one line changed.

**Step 4: Commit (do not attempt to build yet — Phase 3 wires the build)**

```bash
git add modules/Simp/backend/gl.jai
git commit -m "patch: Simp backend uses our gl_load(get_proc) signature

Stock Jai GL is struct-based: gl_load(*gl) populates a GL_Procedures
struct that is then aliased into module scope via 'using gl'. Our GL
module is bare-globals: gl_load(get_proc) populates top-level
function-pointer variables. Call-site syntax is identical for everything
except the load call itself.

glXGetProcAddress is visible because Simp/module.jai already imports
X11 on Linux.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Phase 3 — Build System Wiring

### Task 7: Add `upstream_import_path` and `build_and_run_upstream_example` helpers

**Files:**
- Modify: `first.jai` (top — add helper near existing imports; add `build_and_run_upstream_example` near existing `build_and_run_test`; add `Process` import)

**Step 1: Read current `first.jai` top + bottom**

```bash
head -30 first.jai
tail -10 first.jai
```

Confirm: `#import "Process";` either is or is not already present (it was used in `compile_vulkan_example_shaders` so probably present). If not, add it next to the existing imports.

**Step 2: Add `upstream_import_path` helper**

Use Edit tool. Insert near the top of the file (after `set_working_directory(#filepath);` block in `build()`, or just below the `#import` block — file the new helper as a free proc).

```jai
upstream_import_path :: () -> [] string {
    home := to_string(getenv("HOME"));
    return string.[
        "modules",                            // ours first
        tprint("%/jai/jai/modules", home),    // stdlib for everything else
    ];
}
```

`getenv` and `to_string` should be visible (Basic + POSIX). Add `#import "POSIX";` near the imports if not already there.

**Step 3: Add `build_and_run_upstream_example` helper**

Insert right after the existing `build_and_run_test` definition (around line 93 currently):

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
    opts.import_path = upstream_import_path();
    make_directory_if_it_does_not_exist("build");
    set_build_options(opts, w);

    compiler_begin_intercept(w);
    add_build_file(tprint("%/%", upstream_dir, source_subpath), w);
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
    result := run_command(binary, working_directory = upstream_dir);
    if result.exit_code != 0  exit(result.exit_code);
}
```

**Step 4: Build an unrelated existing target to verify `first.jai` still parses**

```bash
./build.sh - test
```

Expected: 22 XML/protocol tests pass (unchanged). If `first.jai` has a syntax error, the build dies before tests run.

**Step 5: Commit**

```bash
git add first.jai
git commit -m "build: add upstream_import_path and example build helpers

Helpers for compiling stock Jai distribution examples against our
vendored modules. upstream_import_path() puts our modules/ first so
#import calls resolve to ours; build_and_run_upstream_example() handles
the full compile + run flow with working_directory set to the upstream
example's data dir.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 8: Add the `invaders` target case

**Files:**
- Modify: `first.jai` (add `case "invaders"` to the args switch; update the unknown-arg compiler_report list)

**Step 1: Add the case**

Find the existing `case "hello_x11_gl";` block in the for-each args loop. Add right after it:

```jai
case "invaders";
    home := to_string(getenv("HOME"));
    build_and_run_upstream_example(
        workspace_name = "invaders",
        executable_name = "invaders",
        upstream_dir    = tprint("%/jai/jai/examples/invaders", home),
        source_subpath  = "source/invaders.jai",
    );
    set_build_options_dc(.{do_output=false});
```

**Step 2: Update the unknown-arg help message**

Find the `case;` arm at the bottom of the switch (currently lists valid args). Add `'invaders'` to the list.

**Step 3: Verify by running with an invalid arg**

```bash
./build.sh - frobnicate 2>&1 | grep "Unknown argument"
```

Expected: error message includes `'invaders'` in the list of valid options.

**Step 4: Commit (do NOT attempt to build invaders yet — Phase 4 is the first real attempt)**

```bash
git add first.jai
git commit -m "build: add 'invaders' target wiring

./build.sh - invaders now compiles upstream's
~/jai/jai/examples/invaders/source/invaders.jai against our vendored
modules and runs it with CWD set to the upstream invaders dir.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Phase 4 — Validation Checkpoints

These tasks have an iterative flavor: try to advance the checkpoint, triage failures, patch, retry. **Each meaningful patch is its own commit.**

### Task 9: Checkpoint 1 — Compilation passes

**Step 1: Attempt the build**

```bash
./build.sh - invaders 2>&1 | tee /tmp/invaders-build.log
```

**Step 2: Triage**

If exit 0: skip to Step 5.

If compile errors: read the log. Most likely failure modes:

- **"Undeclared identifier: gl"** in some Simp/backend file → we need a `gl` symbol after all. Investigate at the failure site; either add a stub `gl: GL_Procedures` global to our `modules/GL/` or rewrite the Simp access to bare-name.
- **"Procedure X not found"** in our X11/GL → upstream uses an X11/GL API our vendored module didn't export. Add the missing declaration + dlsym in `loader.jai`.
- **"Type mismatch"** somewhere → signature drift between upstream's expectation and ours. Patch the site.
- **"Cannot find module: <name>"** → import path order or a stdlib module we accidentally shadowed. Re-check `upstream_import_path()`.

**Step 3: For each fix, commit separately**

```bash
git add <fixed files>
git commit -m "fix: <one-line description of what was patched> (Checkpoint 1)"
```

**Step 4: Re-run from Step 1 until exit 0**

**Step 5: Confirm binary exists**

```bash
ls -la build/invaders
```

Expected: file exists, executable bit set.

**Step 6: Commit a checkpoint marker (just a docs update or a tag) — optional**

You can tag this commit if helpful:

```bash
git tag invaders-checkpoint-1
```

---

### Task 10: Checkpoint 2 — ldd-clean invariant

**Step 1: Run ldd**

```bash
ldd build/invaders | tee /tmp/invaders-ldd.log
```

**Step 2: Verify allowed set only**

```bash
ldd build/invaders | grep -vE 'libc\.so\.6|linux-vdso|ld-linux'
```

Expected: empty output (no other libraries).

If output is non-empty, those are leaks.

**Step 3: For each leak, trace and fix**

For `<libname>`:

```bash
grep -rn '#library\|#foreign' modules/ ~/jai/jai/modules/<suspect-module>/ 2>/dev/null
```

Identify the offending `#library` / `#foreign` directive. Options:
- If the offender is in a stdlib module (like `stb_image`) — vendor a runtime-loaded replacement under `modules/<Name>/`, or convert the calls to runtime-loaded.
- If the offender is in one of our vendored modules — convert the `#foreign` decl to a function-pointer variable + dlsym loader.

Commit each fix.

**Step 4: Re-verify**

```bash
ldd build/invaders | grep -vE 'libc\.so\.6|linux-vdso|ld-linux'
```

Expected: empty.

**Step 5: Tag (optional)**

```bash
git tag invaders-checkpoint-2
```

---

### Task 11: Checkpoint 3 — Launch and first frame

**Step 1: Launch invaders interactively**

```bash
./build.sh - invaders
```

You should see a window open showing the invaders title or main screen. Let it render for at least 5 seconds. Close cleanly (window close or Esc).

**Step 2: Triage common failures**

- **Crash immediately on launch**: usually a null function-pointer call. Run under gdb:
  ```bash
  cd ~/jai/jai/examples/invaders
  gdb -batch -ex run -ex bt $HOME/projects/jai-wayland/build/invaders 2>&1 | tail -40
  ```
  The backtrace names the function. Add it to our X11 or GL loader.
- **Window opens but renders garbage**: GL function pointers not resolved against the right context. Verify `gl_load(glXGetProcAddress)` runs AFTER GLX context is current (per upstream Simp logic that ordering should be right; if not, the patch in Task 6 needs to move).
- **Window opens but immediately closes**: invaders detected something missing (e.g. data dir). Confirm CWD when running:
  ```bash
  cd ~/jai/jai/examples/invaders && $HOME/projects/jai-wayland/build/invaders
  ```
  If running with explicit CWD works but `./build.sh - invaders` doesn't, the `working_directory` parameter to `run_command` is wrong.

**Step 3: For each fix, commit**

```bash
git commit -m "fix: <one-line> (Checkpoint 3)"
```

**Step 4: Tag (optional)**

```bash
git tag invaders-checkpoint-3
```

---

### Task 12: Checkpoint 4 — Full play-through

**Step 1: Play invaders**

```bash
./build.sh - invaders
```

Verify, in order:
- Main menu / title screen renders.
- Keyboard input moves the ship (typically arrow keys, A/D).
- Fire button works (typically space).
- Aliens descend, bullets register hits.
- Death → respawn or game-over.
- Esc / close cleanly exits.

**Step 2: Resolve audio known-unknown**

Listen for sound effects (shooting, alien deaths). If silent:

```bash
# Search for audio-related code paths
grep -rn 'audio\|sound\|wav\|Audio\|Sound' ~/jai/jai/examples/invaders/source/ | head -20
# Search for audio module imports indirectly
grep -rn 'Mixer\|OpenAL\|alsa\|pulse\|Audio' ~/jai/jai/examples/invaders/source/ | head -10
```

Possible outcomes:
- Invaders has no audio. Done.
- Invaders uses an audio module we haven't vendored — vendor it or accept silence and document.
- Invaders calls audio APIs that need additional X11/ALSA/Pulse setup — investigate per crash.

**Step 3: For each fix, commit**

**Step 4: Tag**

```bash
git tag invaders-checkpoint-4
```

---

## Phase 5 — Documentation

### Task 13: Update CLAUDE.md and AGENTS.md

**Files:**
- Modify: `CLAUDE.md` (Build Commands section, possibly Architecture)
- Modify: `AGENTS.md` (Build And Test section)

**Step 1: Add `./build.sh - invaders` to the Build Commands table in CLAUDE.md**

Edit the build commands block to include:

```
./build.sh - invaders         # Build and run upstream invaders example against our vendored modules
```

**Step 2: Document the vendored modules in the Architecture section**

Add a paragraph similar to the existing Vulkan / X11 module descriptions:

```
**Upstream vendored modules** (`modules/Window_Creation/`, `modules/Simp/`,
`modules/GetRect/`, `modules/GetRect_LeftHanded/`) — Jai distribution
modules copied verbatim from `~/jai/jai/modules/` for compatibility with
upstream graphical examples. Two patches: our `modules/X11/module.jai`
self-initializes via `init_x11`/`init_glx` in `init_global_display`;
`modules/Simp/backend/gl.jai` uses our `gl_load(glXGetProcAddress)`
signature instead of stock `gl_load(*gl)`. The `./build.sh - invaders`
target compiles upstream's `~/jai/jai/examples/invaders/source/invaders.jai`
against these vendored modules — proving Phase 6's "vendored upstream
window/graphics stack" foundation.
```

**Step 3: Mirror to AGENTS.md**

Update the Build And Test section's live examples list to include `invaders`.

**Step 4: Mark Phase 6 progress in CLAUDE.md "Next Steps"**

The current item 4 about vendored Window_Creation/Simp/GetRect can be amended with "(in progress on upstream-integration branch — invaders playable as proof)".

**Step 5: Commit**

```bash
git add CLAUDE.md AGENTS.md
git commit -m "docs: document invaders target and vendored upstream modules

Add ./build.sh - invaders to build commands, describe the four vendored
upstream modules and the two minimal patches that make them work with
our runtime-loaded X11/GL stack.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Phase 6 — Merge

### Task 14: Push branch and verify final state

**Step 1: Run the full validation one more time**

```bash
./build.sh - test gen_test wire_test marshal_test unmarshal_test compile_test
./build.sh - invaders   # Manual play-through; close cleanly
ldd build/invaders | grep -vE 'libc\.so\.6|linux-vdso|ld-linux'   # expect empty
```

**Step 2: Push the branch**

```bash
git push -u origin upstream-integration
```

**Step 3: Stop and check in with the user**

Branch is ready for review. Don't merge to master without an explicit user instruction. Don't open a PR on GitHub unless the user asks.

---

## Notes and Hard-Won Wisdom

- **Don't break our existing examples while patching X11.** After Task 5, before moving on, build at least `x11_smoke` and `hello_x11_gl` to verify they still work and stay ldd-clean. The patch is supposed to be transparent for callers that already invoke `init_x11()` explicitly — the inserted calls are idempotent — but verify.

- **Commit per patch.** When iterating in Checkpoints 1–4, every meaningful patch is its own commit with the checkpoint number in the message. Future archaeology benefits enormously from "this fix happened during Checkpoint 3 triage" being visible.

- **Don't suppress compile errors.** If the compiler complains about a missing identifier in upstream Simp/Window_Creation, the answer is almost always "add the missing thing to our module" not "comment out the upstream line". Upstream knows what it needs; treat its expectations as spec.

- **Don't get clever about `gl: GL_Procedures`.** If Checkpoint 1 surfaces struct-prefix `gl.<field>` accesses in upstream Simp, the temptation will be to add a `gl :: struct { ... }` global to our GL module to satisfy them. Don't — change the upstream access sites to bare names (single-line patches via Edit). That's still "minimal patch" territory. A struct just to satisfy a small number of cosmetic call sites is over-engineering.

- **CWD for `run_command`.** The `working_directory` arg to `Process.run_command` must be the upstream invaders dir (absolute, expanded). Use `tprint("%/jai/jai/examples/invaders", to_string(getenv("HOME")))`. Don't pass `~/...` literally — Jai/POSIX don't expand `~`.

- **The validation checkpoints are not unit tests.** This work has no isolated unit-testable functions; the project's tests (XML/wire/marshal/unmarshal/etc.) still pass as they always have, but they don't exercise the new code. Checkpoint 1–4 ARE the validation regime here.

---

## Execution Handoff

Plan complete and saved to `docs/plans/2026-05-26-upstream-integration-impl.md`. Two execution options:

**1. Subagent-Driven (this session)** — I dispatch a fresh subagent per task, review between tasks, fast iteration loop. Best when you want to stay engaged and steer.

**2. Parallel Session (separate)** — Open a new session with the `superpowers:executing-plans` skill, batch execution with checkpoints. Best when you want to walk away and review the result later.

Which approach?
