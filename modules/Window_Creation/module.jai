// Vendored from ~/jai/jai/modules/Window_Creation/module.jai.
// Modified: added #load "linux_init.jai" in the Linux branch for the
//           context-dispatch init ceremony (running_wayland +
//           init_linux_window). See
//           docs/plans/2026-05-26-context-dispatch-stage1-design.md.

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
