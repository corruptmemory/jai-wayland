// Minimal OpenGL bindings — types + constants + runtime-loaded function pointers.
//
// We vendor this instead of #import "GL" because Jai's stock GL module
// hard-links libGL (#foreign gl_lib in glad_core.jai) and pulls in X11
// transitively (#import "Window_Type"). That's fine for apps that already
// use GLX or don't care about closing dependencies, but it's at odds with
// this project's "no external library linkage" thesis.
//
// All GL symbols here are resolved at runtime through a caller-supplied
// eglGetProcAddress (or equivalent), populated via gl_load().
//
// Scope: the subset used by examples/headless_gl.jai, examples/hello_gl.jai,
// and whatever future examples need. Add more entry points as needed —
// there's no reason to bind everything up front.

#load "gl.jai";
#load "loader.jai";
