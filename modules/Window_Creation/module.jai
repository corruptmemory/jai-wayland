// Vendored from ~/jai/jai/modules/Window_Creation/module.jai.
// Modified: (a) added #load "linux_init.jai" in the Linux branch for the
//               context-dispatch init ceremony (running_wayland +
//               init_linux_window).
//           (b) re-exported INVALID_WINDOW and the Linux tagged-union
//               `operator ==` overloads from the WT namespace so importers
//               of Window_Creation can use them without a direct Window_Type
//               import. The upstream `WT :: #import "Window_Type"; Window_Type
//               :: WT.Window_Type;` pattern provides the type name but not
//               operators (named imports don't propagate operator overloads
//               in Jai); the explicit `operator == :: WT.operator==;`
//               re-export plugs that gap for Linux's tagged-union variant.
//           See docs/plans/2026-05-26-context-dispatch-stage1-design.md.

// Platform-independent window creation routines.
#module_parameters (DEFAULT_MSAA: s32 = 4);

#if OS == {
    case .WINDOWS; #load "windows.jai";
    case .LINUX;
        #load "linux.jai";
        #load "linux_init.jai";
    case .MACOS;   #load "macos.jai";
    case .PS5;     #load "ps5.jai";
    case .NN_SWITCH2;   #load "nintendo.jai";
    case .ANDROID; #load "android.jai";
    case;          #assert(false);
}

#scope_module

#import "Basic";

DEFAULT_WINDOW_CREATION_COLOR :: float.[.15,.15,.2];

#scope_export

// @CompilerBug: There is some kind of name importation problem that keeps happening,
// for example, Window_Type doesn't go through unless we do this weird WT thing.
// -jblow, 25 February 2021
WT :: #import "Window_Type";  // Define this for the people.
Window_Type :: WT.Window_Type;
// Re-export INVALID_WINDOW too so callers (e.g. invaders) can use it without
// importing Window_Type themselves.
INVALID_WINDOW :: WT.INVALID_WINDOW;
// Operator overloads. Named imports don't propagate operators (see Jai
// "Named vs Anonymous Import Semantics"). The tagged-union Window_Type on
// Linux defines `==` between Window_Type values and between Window_Type
// and X11.Window; we re-export both into Window_Creation's scope so
// importers of Window_Creation can compare values. The Linux X11 branch
// imports X11 anonymously in linux.jai, so the second overload's
// `X11.Window` operand resolves cleanly here.
#if OS == .LINUX {
    operator == :: WT.operator==;
}
