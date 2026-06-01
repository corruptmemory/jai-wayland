// Vendored from ~/jai/jai/modules/Window_Creation/linux.jai.
// Modified: (a) create_window picks the Wayland vs X11 arm directly via
//               WS.running_wayland(); the Wayland arm registers the window in
//               WS.wayland_global_windows (the X11 x_global_windows mirror).
//               Display-server selection is value-level (set in Simp's
//               CheckInit) — no context-dispatch init ceremony.
//           (b) parent parameter default changed from None (X11 s64) to
//               INVALID_WINDOW (Window_Type tagged-union sentinel).
//               In-body parent usages updated accordingly with .x11
//               extractions or tagged-union comparison.
//           (c) Return type of create_window changed from Window (the
//               raw X11.Window u64) to Window_Type (the tagged union).
//               Mirrors what HWND/*NSWindow do on the other platforms:
//               return value matches the declared Window_Type. Required
//               so that callers like invaders can feed the returned
//               value directly into Simp.set_render_target, which after
//               Task 1 takes Window_Type.
//           (d) get_dimensions(win) likewise changed to accept
//               Window_Type and unwrap .x11 internally before handing
//               off to XGetWindowAttributes.
//           See docs/plans/2026-05-26-context-dispatch-stage1-design.md.


//
// This x_global_display stuff is not the right way to do it. We should
// probably wrap the window type such that it contains a display pointer
// and a window pointer, thus is enough to uniquely identify a window.
//
#import "X11";

// Wayland module, named-imported so the wire-protocol API is namespaced. Used by
// the Wayland arm of create_window below. The `for :Wl.for_expansion` form is
// required to resolve the WaylandSession for_expansion through the named import.
//
// NAME-based (not #import,dir) is REQUIRED: Wayland_Support and Simp also import
// wayland, and all must share ONE instance (wayland declares `#add_context
// wayland_session` — two instances ⇒ conflicting context types). Jai dedups
// modules by import spelling; name-based dedups across modules regardless of each
// file's location, whereas dir-based paths can never string-match. Resolves via
// the build import_path (modules/ first — see first.jai).
//
// #scope_module: these named imports are INTERNAL to Window_Creation. Without it,
// the file's default export scope re-exports the Wl / WS / POSIX constants to
// importers of Window_Creation — and a re-exported WS collides with any app or
// module that imports Wayland_Support under the same name (e.g. hello_simp). They
// are used only in function bodies here, so module scope is sufficient.
#scope_module
Wl :: #import "wayland";

// Wayland_Support — the GPU-aware support module shared with Simp/Input. Used
// here for running_wayland (the backend probe) and register_wayland_window (the
// side effect that records each created Wayland window in the shared
// WS.wayland_global_windows registry — the mirror of X11's array_add into
// x_global_windows). Name-based so it dedups to one instance with Simp/Input.
WS :: #import "Wayland_Support";

// For getenv() and other POSIX bits used by this file. Named import; dedups with
// X11's transitive POSIX. (exit() comes from Basic.)
POSIX :: #import "POSIX";

#scope_export

window_minimized := false;

Saved_Window_Info :: struct {

}

toggle_fullscreen :: (win: Window, desire_fullscreen: bool, saved: *Saved_Window_Info) -> success: bool, width: s32, height: s32 {
    if desire_fullscreen {
        if x_global_net_wm_state && x_global_net_wm_state_fullscreen {
            //
            xev: XEvent;
            xev.type = ClientMessage;
            xev.xclient.window = win;
            xev.xclient.message_type = x_global_net_wm_state;
            xev.xclient.format = 32;
            xev.xclient.data.l[0] = _NET_WM_STATE_ADD;
            xev.xclient.data.l[1] = cast(s64) x_global_net_wm_state_fullscreen;

            display := x_global_display;
            XSendEvent(display, DefaultRootWindow(display), False, SubstructureRedirectMask | SubstructureNotifyMask, *xev);
            XSync(display, False);

            width: u32;
            height: u32;

            // for what ever stupid reason, XGetGeometry crashes if you pass null in for any of its return parameters
            root: Window;
            x, y: s32;
            border_width: u32;
            depth_return: u32;
            // this will return the window's current dimensions, but it seems the server will imediately send a ConfigureNotify event
            // with the new size of the fullscreen window
            XGetGeometry(display, win, *root, *x, *y, *width, *height, *border_width, *depth_return);
            return true, cast(s32) width, cast(s32) height;
        } else {
            // :NoNET_WM_STATE_FULLSCREEN:
            // @TODO typically the window manager should support NET_WM_STATE and NET_WM_STATE_FULLSCREEN
            // however, in the event that it does not, we're supposed to change the window's attributes
            // to enable override_redirect. However, apparently in doing so, this causes the window manager
            // to ignore the window (the window, in essense, is considered as acting as a temporary window manager
            // accoring to the ICCM) requiring more work on our part. The ICCM strongly discourages doing this,
            // but this is the only other way to take control of the screen AFAICT. -josh
            return false, 0, 0;
        }
    } else {
        if x_global_net_wm_state && x_global_net_wm_state_fullscreen {
            xev: XEvent;
            xev.type = ClientMessage;
            xev.xclient.window = win;
            xev.xclient.message_type = x_global_net_wm_state;
            xev.xclient.format = 32;
            xev.xclient.data.l[0] = _NET_WM_STATE_REMOVE;
            xev.xclient.data.l[1] = cast(s64) x_global_net_wm_state_fullscreen;

            display := x_global_display;
            XSendEvent(display, DefaultRootWindow(display), False, SubstructureRedirectMask | SubstructureNotifyMask, *xev);

            width: u32;
            height: u32;

            // for what ever stupid reason, XGetGeometry crashes if you pass null in for any of its return parameters
            root: Window;
            x, y: s32;
            border_width: u32;
            depth_return: u32;
            XGetGeometry(display, win, *root, *x, *y, *width, *height, *border_width, *depth_return);
            return true, cast(s32) width, cast(s32) height;
        } else {
            // :NoNET_WM_STATE_FULLSCREEN:
            return false, 0, 0;
        }
    }
}

create_window :: (width: int, height: int, window_name: string, window_x := 0, window_y := 0, parent: Window_Type = INVALID_WINDOW, background_color_rgb := DEFAULT_WINDOW_CREATION_COLOR, wanted_msaa: s32 = DEFAULT_MSAA) -> Window_Type {
    // Backend selection is by value now (display server detected in Simp's
    // CheckInit), not a context dispatch pointer — so there is no lazy-init
    // ceremony here; we just pick the create arm directly.
    #if OS == .LINUX {
        if WS.running_wayland()  return create_window_wayland(width, height, window_name);
    }

    if !x_global_display
        init_global_display();

    d := x_global_display;

    XLockDisplay(d);
    root := DefaultRootWindow(d);
    // Parent defaults to INVALID_WINDOW; rebind to the X11 root if so.
    // Use a local because the parameter is immutable (Window_Type is a
    // struct after Task 1's tagged-union refactor; the upstream version
    // could reassign because Window_Type was a scalar u64 alias).
    parent_local := parent;
    if parent_local == INVALID_WINDOW { parent_local = .{ wtype = .X11, x11 = root }; }

    screen := DefaultScreen(d);

    // These attributes must match the attibutes we use to create the GL context. :GlContextAttributes
    //        -rluba, 2021-11-30
    attr := s32.[
        GLX_RGBA,
        GLX_DEPTH_SIZE, 24,
        GLX_DOUBLEBUFFER,
        GLX_RED_SIZE, 8,
        GLX_GREEN_SIZE, 8,
        GLX_BLUE_SIZE, 8,
        GLX_STENCIL_SIZE, 8,
        GLX_SAMPLE_BUFFERS, cast(s32) ifx wanted_msaa then 1 else 0,
        GLX_SAMPLES,        wanted_msaa,
        None
    ];

    vi := glXChooseVisual(d, screen, attr.data);
    // log("XVisualInfo: %", <<vi);
    cmap := XCreateColormap(d, parent_local.x11, vi.visual, AllocNone);

    to_u16 :: (f: float) -> u16 #expand {
        u := clamp(cast(s32)(f * 65535), 0, 65535);
        return cast(u16) u;
    }

    background_color: XColor;
    background_color.flags |= DoRed | DoGreen | DoBlue;
    background_color.red     = to_u16(background_color_rgb[0]);
    background_color.green   = to_u16(background_color_rgb[1]);
    background_color.blue    = to_u16(background_color_rgb[2]);
    XAllocColor(d, cmap, *background_color);


    swa: XSetWindowAttributes;
    swa.colormap = cmap;
    swa.event_mask = ExposureMask | KeyPressMask | KeyReleaseMask | ButtonPressMask | ButtonReleaseMask | StructureNotifyMask | FocusChangeMask | EnterWindowMask | LeaveWindowMask | PointerMotionHintMask | PointerMotionMask;
    swa.background_pixel = background_color.pixel;
    win := XCreateWindow(d, parent_local.x11, xx window_x, xx window_y, xx width, xx height, 0, vi.depth, InputOutput, vi.visual, cast(u64) (CWColormap | CWEventMask), *swa);

//    XSetWindowBackground(d, win, background_color.pixel);

    win_name := temp_c_string(window_name);
    if window_name then XStoreName(d, win, win_name);

    class_hints := XAllocClassHint();
    if class_hints {
        // this changes the application name for now (not the window title)
        // unset, gnome3 will just display "Unknown" in the activity bar and the dock
        if window_name {
            class_hints.res_name = win_name;
            class_hints.res_class = win_name;
        } else {
            class_hints.res_name = "jai-application";
            class_hints.res_class = "JAI-Application";
        }
        XSetClassHint(d, win, class_hints);
    }

    XMapWindow(d, win);

    XSetWMProtocols(d, win, *x_global_wm_delete_window, 1);

    x_global_input_context = XCreateIC(
        x_global_input_method,
        XNClientWindow, win,
        XNFocusWindow, win,
        XNInputStyle, XIMPreeditNothing | XIMStatusNothing,
        null,
    );

    if !x_global_input_context {
        log_error("Could not create X11 input context\n");
    }


    array_add(*x_global_windows, win);

    XUnlockDisplay(d);
    return .{ wtype = .X11, x11 = win };
}

// Wayland arm of create_window. Creates the compositor surface stack
// (wl_surface / xdg_surface / xdg_toplevel), commits, then blocks until the
// first xdg configure to learn the initial size. Ported from
// examples/hello_gl.jai:99-127. This builds ONLY the window identity; the GL
// backend state is created later in Simp's BACKEND_INIT: Wayland_Support owns
// the shared EGL/GBM context and the per-window BO slots, exactly as the X11
// path leaves GL to Simp.
//
// Slice 1 has no teardown hook: the WaylandSession created here is leaked at
// process exit. That is acceptable for now — end_wayland_session is a Stage-2
// follow-up once window destruction has a home.
create_window_wayland :: (width: int, height: int, window_name: string) -> Window_Type {
    if !Wl.session() {
        if !Wl.init_wayland_session() {
            // Unrecoverable: no window means nothing can render, and the
            // (unmodifiable) caller does not validity-check the result.
            // Returning a sentinel would mis-route — INVALID_WINDOW is
            // .X11-tagged, so on a live Wayland session Simp would take the
            // X11/GLX path (or mis-read info.window.wayland). Fail loud.
            log_error("create_window_wayland: could not initialize Wayland session");
            exit(1);  // Basic.exit
        }
    }

    // Surface / xdg role creation. allocate_id() is called immediately before
    // the request that creates each object so IDs go out contiguously and in
    // monotonically increasing order on the wire (compositor requirement).
    batch: Wl.MessageBuilder;

    surface := Wl.Wl_Surface.{ id = Wl.allocate_id() };
    Wl.wl_compositor_create_surface(*batch, Wl.compositor(), surface.id);

    xdg_surface := Wl.Xdg_Surface.{ id = Wl.allocate_id() };
    Wl.xdg_wm_base_get_xdg_surface(*batch, Wl.wm_base(), xdg_surface.id, *surface);

    toplevel := Wl.Xdg_Toplevel.{ id = Wl.allocate_id() };
    Wl.xdg_surface_get_toplevel(*batch, *xdg_surface, toplevel.id);

    if window_name  Wl.xdg_toplevel_set_title(*batch, *toplevel, window_name);
    Wl.wl_surface_commit(*batch, *surface);
    Wl.wayland_send(*batch);

    // Wait for the initial configure. xdg_toplevel.configure carries the
    // suggested size (may be 0x0, meaning "you decide"); xdg_surface.configure
    // carries the serial we must ack and terminates the configure sequence.
    // wm_base ping/pong and wl_display.error are handled by the for_expansion.
    win_width:  s32 = cast(s32) width;
    win_height: s32 = cast(s32) height;
    configure_serial: u32 = 0;
    got_configure := false;   // distinct from serial==0: a real serial may be 0
    // Named iterator: the WaylandSession for_expansion lives in the `Wl`
    // module and is not merged into this scope by the named import.
    for :Wl.for_expansion Wl.session() {
        if it.object_id == toplevel.id && it.opcode == Wl.XDG_TOPLEVEL_CONFIGURE {
            args: Wl.Xdg_Toplevel_Configure_Args;
            Wl.unmarshal(*args, it.payload, recv);
            if args.width > 0 && args.height > 0 {
                win_width  = args.width;
                win_height = args.height;
            }
        } else if it.object_id == xdg_surface.id && it.opcode == Wl.XDG_SURFACE_CONFIGURE {
            configure_serial = Wl.read_u32(it.payload);
            got_configure = true;
            break;
        } else {
            WS.wl_route_registered_window_control_event(it, recv);
        }
    }

    if !got_configure {
        // Unrecoverable (disconnect / wl_display.error before configure). Fail
        // loud rather than return the .X11-tagged sentinel — see above.
        log_error("create_window_wayland: did not receive xdg_surface.configure");
        exit(1);  // Basic.exit
    }

    // Ack the configure so the compositor lets us map content.
    ack_batch: Wl.MessageBuilder;
    Wl.xdg_surface_ack_configure(*ack_batch, *xdg_surface, configure_serial);
    Wl.wayland_send(*ack_batch);

    log("create_window_wayland: configured window %x%", win_width, win_height);

    // Register this window in the shared WS registry — the Wayland mirror of
    // X11's `array_add(*x_global_windows, win)` (linux.jai). Records identity +
    // initial size; Simp's wl_backend_init later fills in the EGL/slot state, and
    // the single Wayland_Support pump routes this window's events by these ids.
    WS.register_wayland_window(surface.id, xdg_surface.id, toplevel.id, win_width, win_height);

    return .{
        wtype   = .Wayland,
        wayland = .{ surface = surface.id },  // identity only; full state lives in WS.wayland_global_windows
    };
}

get_dimensions :: (win: Window_Type, right_handed: bool) -> (x: s32, y: s32, width: s32, height: s32, success := true) {
    if win.wtype == .Wayland {
        // Wayland clients have no XGetWindowAttributes and are not told their
        // on-screen position (the compositor owns placement), so x/y are 0. Size
        // is the single source of truth in the shared registry. right_handed has
        // no effect with y == 0. (Matches Simp.get_render_dimensions.)
        ww := WS.find_wayland_window(win.wayland.surface);
        if ww  return 0, 0, ww.width, ww.height;
        return 0, 0, 0, 0, false;
    }

    xwa: XWindowAttributes;
    XGetWindowAttributes(x_global_display, win.x11, *xwa);

    y := ifx right_handed then xwa.y+xwa.height else xwa.y;
    return xwa.x, y, xwa.width, xwa.height;
}

get_mouse_pointer_position :: (dpy: *Display, win: Window, right_handed: bool) -> x: int, y: int, success: bool {
    root_x, root_y: s32;
    win_x, win_y: s32;
    root, child: Window;
    modifier_mask: u32;

    // @TODO XQueryPointer is a round trip to the X server, which means this could be very slow.
    // It may be more desirable to update a global mouse state by capturing mouse events in X11_Input.jai:update_x11_window_events()
    ok := XQueryPointer(dpy, win, *root, *child, *root_x, *root_y, *win_x, *win_y, *modifier_mask);

    if right_handed {
        xwa: XWindowAttributes;
        XGetWindowAttributes(dpy, win, *xwa);
        win_y = xwa.height - win_y;
    }
    return win_x, win_y, ok == True;
}

get_mouse_pointer_position :: (win: Window, right_handed: bool) -> x: int, y: int, success: bool {
    x, y, success := get_mouse_pointer_position(x_global_display, win, right_handed);
    return x, y, success;
}

// Window_Type overload — GetRect resolves this (get_mouse_pointer_position(dummy:
// Window_Type, true)). On Wayland the position is surface-local, tracked by the
// pump (no round-trip). right_handed flips Y to bottom-left origin using the
// registry size, matching the X11 path so UI hit-testing lines up with Simp's
// y-up rendering. (Window vs Window_Type are distinct types -> no overload clash.)
get_mouse_pointer_position :: (win: Window_Type, right_handed: bool) -> x: int, y: int, success: bool {
    if win.wtype == .Wayland {
        x := cast(int) WS.wl_mouse_x;
        y := cast(int) WS.wl_mouse_y;
        if right_handed {
            ww := WS.find_wayland_window(win.wayland.surface);
            if ww  y = ww.height - y;
        }
        return x, y, true;
    }
    x, y, success := get_mouse_pointer_position(win.x11, right_handed);
    return x, y, success;
}

get_mouse_pointer_position :: inline (right_handed := false) -> x: int, y: int, success: bool {
    dpy := x_global_display;
    if !dpy return 0, 0, false;
    win: Window;
    revert: s32;
    XGetInputFocus(dpy, *win, *revert);
    x, y, success := get_mouse_pointer_position(dpy, win, right_handed);
    return x, y, success;
}


//#scope_file

// libc :: #library,system "libc";
