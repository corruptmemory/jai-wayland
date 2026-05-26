// New file (not vendored — original to this project).
// Wayland dispatcher placeholder. Stage 1 stub; Stage 2 implementation
// will fill in the body with EGL-on-GBM + DMA-BUF presentation (the
// same architecture hello_gl.jai uses).
// See docs/plans/2026-05-26-context-dispatch-stage1-design.md and
// docs/plans/2026-05-26-wayland-backend-question.md (Option B).

#scope_export

simp_wayland_dispatch :: (args: *Simp_Op_Args, info: *Window_Info) {
    assert(false, "Wayland backend dispatcher not yet implemented (Stage 2). running_wayland() should currently return false; if you hit this, init_linux_window picked the wrong path.");
}
