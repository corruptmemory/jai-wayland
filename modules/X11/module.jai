// X11 bindings.
// Vendored from ~/jai/jai/modules/X11/module.jai, with Xlib/GLX entry points
// converted from #foreign declarations to runtime-loaded function pointers.

x_global_display: *Display;
x_global_input_method: XIM;
x_global_input_context: XIC;
x_global_wm_delete_window: Atom;
x_global_wm_protocols: Atom;
x_global_net_wm_demands_attention: Atom;
x_global_net_wm_state: Atom;
x_global_net_wm_state_fullscreen: Atom;
x_global_xa_clipboard: Atom;
x_global_xa_utf8: Atom;
x_global_xa_targets: Atom;
x_global_xa_multiple: Atom;
x_global_xa_atom: Atom;

x_global_image_png: Atom;
x_global_image_bmp: Atom;
x_global_image_jpeg: Atom;

x_global_invisible_cursor: Cursor;

x_global_non_protocol_atom: Atom;

// Xdnd support by Jens Frederich. Send questions his way. Licensed under the MIT license; see copyright at the end of the file.
XdndEnter         : Atom;
XdndPosition      : Atom;
XdndStatus        : Atom;
XdndTypeList      : Atom;
XdndAware         : Atom;
XdndActionMove    : Atom;
XdndActionLink    : Atom;
XdndActionCopy    : Atom;
XdndDrop          : Atom;
XdndLeave         : Atom;
XdndFinished      : Atom;
XdndSelection     : Atom;
XdndProxy         : Atom;

x_global_clipboard_buffer: struct {
    text_data: string;

    rgb_data: *u8;
    width: s32;
    height: s32;
    pitch: s32;
};

x_release_clipboard_data :: () {
    XLockDisplay(x_global_display);

    using x_global_clipboard_buffer;
    free(text_data);
    text_data.data = null;
    text_data.count = 0;

    if rgb_data then free(rgb_data);

    rgb_data = null;
    width, height, pitch = 0;

    XUnlockDisplay(x_global_display);
}

x_global_windows: [..] Window;

_NET_WM_STATE_REMOVE :: 0;
_NET_WM_STATE_ADD    :: 1;
_NET_WM_STATE_TOGGLE :: 2;

Xdnd_Stage :: enum {
    DROP_IDLE       :: 0;
    DROP_CONVERTING :: 1;
    DROP_ENTERED    :: 2;
}

XDND_VERSION :: 5;   // I dunno, some version.

Xdnd_Context :: struct {
    stage := Xdnd_Stage.DROP_IDLE;

    dragging_version := 0;
    dragger_typelist: [..] Atom;
    dragger_window: Window;

    want_position := false;
    will_accept := false;

    rectangle: XRectangle;
    dropper_window: Window;
    dropper_toplevel: Window;
    root_window: Window;
    supported_action: Atom;
    desired_type: Atom;
    x: s32;
    y: s32;
    time: Time;
}

Drop_Info :: struct {
    data: [..] u8;
    x: int;
    y: int;

    return_type: Atom;
    return_action: Atom;

    user_typelist: [..] Atom;
    user_actions:  [..] Atom;
}

drop_info: Drop_Info; // @Incomplete: Maybe move to dnd.
x_global_xdnd_context: Xdnd_Context;

xdnd_context_reset :: (dnd: *Xdnd_Context) {
    dnd.stage = Xdnd_Stage.DROP_IDLE;
    dnd.dragging_version = 0;
    dnd.want_position = false;
    dnd.will_accept = false;
    dnd.rectangle.x = 0;
    dnd.rectangle.y = 0;
    dnd.rectangle.width = 0;
    dnd.rectangle.height = 0;
    dnd.dropper_window = 0;
    dnd.dragger_window = 0;
    dnd.desired_type = 0;
    array_reset(*dnd.dragger_typelist);
}


init_global_display :: () {
    if !init_x11() {
        log_error("Failed to load libX11 — cannot initialize X display");
        exit(1);
    }
    if !init_glx() {
        log_error("Failed to load libGLX/libGL — cannot initialize GL stack");
        exit(1);
    }

    if x_global_display return;

    old_locale := setlocale(LC_ALL, null);
    old_xmods  := XSetLocaleModifiers(null);

    defer {
        if old_locale {
            setlocale(LC_ALL, old_locale);
        }
        if old_xmods {
            XSetLocaleModifiers(old_xmods);
        }
    }

    // Default locale, which is "C", doesn't support multibyte characters,
    // so we do all of this to get an actual system locale which is hopefully set up correctly

    // Result of setlocale will either be a correct locale from the environment,
    // or NULL if setlocale fails, or it will be "C" if a user has explicit LC_ALL="" exported.
    new_locale := to_string(setlocale(LC_ALL, ""));

    // We need to check whether the current locale is supported by X server. The support is not
    // guaranteed regardless of whether setlocale call succeeded or not.
    // If setlocale didn't work, we try our best to get the locale from a few well-known
    // environment variables in case one of them is set up correctly. glibc's setlocale
    // first tries $LC_ALL, then a category you specify in the first argument to setlocale,
    // and then $LANG env variable. The issue here is that glibc bails out of this sequence
    // as soon as it encounteres something that is set, even if it's not set correctly. So the call to
    // setlocale will end up failing. That's why we do this process ourselves.
    // This process vaguely resembles the way musl gets current locale, and it is reasonable enough.
    if !new_locale || new_locale == "C" || !XSupportsLocale() {
        // getenv can have two "falsy" outcomes - env variable exists but is an empty string
        // and env variable doesn't exist at all. In first case, we get a pointer to an empty string,
        // in the second case we get NULL as a result. Converting to Jai string covers both cases.
        lc_ctype := trim(to_string(getenv("LC_CTYPE")));
        if !lc_ctype {
            lang := trim(to_string(getenv("LANG")));

            if !lang {
                log_error("LANG environment variable is not found, trying to fall back to C.UTF-8\n");
                new_locale = to_string(setlocale(LC_ALL, "C.UTF-8"));
            } else {
                new_locale = to_string(setlocale(LC_ALL, temp_c_string(lang)));
            }
        } else {
            new_locale = to_string(setlocale(LC_ALL, temp_c_string(lc_ctype)));
        }

        if !new_locale || !XSupportsLocale() {
            error :: #string __error
            Couldn't set unicode-capable locale from environment, falling back to default one: %.
                This is likely an indicator that your locale is set incorrectly.
                Inspect available locales [$ locale -a] and the one you have set up: [$ locale]
            __error
            log_error(error, to_string(old_locale));
            setlocale(LC_ALL, old_locale);
        }
    }


    XInitThreads();

    x_global_display = XOpenDisplay(null);
    d := x_global_display;

    x_global_wm_delete_window = XInternAtom(d, "WM_DELETE_WINDOW", True);
    x_global_wm_protocols     = XInternAtom(d, "WM_PROTOCOLS", True);

    x_global_net_wm_demands_attention = XInternAtom(d, "_NET_WM_STATE_DEMANDS_ATTENTION", True);
    x_global_net_wm_state = XInternAtom(d, "_NET_WM_STATE", True);
    x_global_net_wm_state_fullscreen = XInternAtom(d, "_NET_WM_STATE_FULLSCREEN", True);

    x_global_xa_clipboard = XInternAtom(d, "CLIPBOARD", True);
    x_global_xa_utf8      = XInternAtom(d, "UTF8_STRING", False);
    x_global_xa_targets   = XInternAtom(d, "TARGETS", False);
    x_global_xa_multiple  = XInternAtom(d, "MULTIPLE", False);
    x_global_xa_atom      = XInternAtom(d, "ATOM", False);
    x_global_non_protocol_atom = XInternAtom(d, "JXSelectionWindowProperty", False);

    XdndEnter             = XInternAtom(d, "XdndEnter", False);
    XdndPosition          = XInternAtom(d, "XdndPosition", False);
    XdndStatus            = XInternAtom(d, "XdndStatus", False);
    XdndTypeList          = XInternAtom(d, "XdndTypeList", False);
    XdndActionMove        = XInternAtom(d, "XdndActionMove", False);
    XdndActionLink        = XInternAtom(d, "XdndActionLink", False);
    XdndActionCopy        = XInternAtom(d, "XdndActionCopy", False);
    XdndDrop              = XInternAtom(d, "XdndDrop", False);
    XdndLeave             = XInternAtom(d, "XdndLeave", False);
    XdndFinished          = XInternAtom(d, "XdndFinished", False);
    XdndSelection         = XInternAtom(d, "XdndSelection", False);
    XdndProxy             = XInternAtom(d, "XdndProxy", False);
    XdndAware             = XInternAtom(d, "XdndAware", False);


    // x_global_image_jpeg   = XInternAtom(d, "image/jpeg", True);
    // x_global_image_png    = XInternAtom(d, "image/png", True);
    x_global_image_bmp    = XInternAtom(d, "image/bmp", True);

    // Try the best we can to get the right input method
    XSetLocaleModifiers("");
    x_global_input_method = XOpenIM(x_global_display, null, null, null);
    if !x_global_input_method {
        // It seems like local is the same as nothing, but more examples on the Internet use it.
        XSetLocaleModifiers("@im=local");
        x_global_input_method = XOpenIM(x_global_display, null, null, null);

        if x_global_input_method {
            XSetLocaleModifiers("@im=");
            x_global_input_method = XOpenIM(x_global_display, null, null, null);

            // Nothing more we can do.
            if !x_global_input_method {
                log_error("Could not get X11 Input Method\n");
            }
        }
    }

    data: u8 = 0;
    pmap: Pixmap;
    color: XColor;

    pmap = XCreateBitmapFromData(d, DefaultRootWindow(d), *data, 1, 1);
    x_global_invisible_cursor = XCreatePixmapCursor(d, pmap, pmap, *color, *color, 0, 0);
    XFreePixmap(d, pmap);

    xdnd_context_reset(*x_global_xdnd_context);
}

enable_drag_and_drop :: (window: Window, typelist: [] string) {
    version : s32 = XDND_VERSION;

    XChangeProperty(x_global_display, window, XdndAware, XA_ATOM, 32, PropModeReplace, cast(*u8) *version, 1);

    root_return: Window;
    parent: Window;
    child_return: *Window;
    child_return_count: u32;
    XQueryTree(x_global_display, window, *root_return, *parent, *child_return, *child_return_count);

    if child_return  XFree(child_return);

    if parent != root_return  enable_drag_and_drop(parent, typelist);

    typelist_atoms: [..] Atom;
    array_reset(*drop_info.user_typelist);

    for typelist {
        atom := XInternAtom(x_global_display, it.data, False);
        array_add(*typelist_atoms, atom);
        array_add(*drop_info.user_typelist, atom);
    }

    XChangeProperty(x_global_display, window, XdndTypeList, XA_ATOM, 32, PropModeReplace, cast(*u8) typelist_atoms.data, cast(s32) typelist_atoms.count);
}


x_demand_attention :: (display: *Display, win: Window) {
    if x_global_net_wm_state && x_global_net_wm_demands_attention {
        xev: XEvent;
        xev.type = ClientMessage;
        xev.xclient.window = win;
        xev.xclient.message_type = x_global_net_wm_state;
        xev.xclient.format = 32;
        xev.xclient.data.l[0] = _NET_WM_STATE_ADD;
        xev.xclient.data.l[1] = cast(s64) x_global_net_wm_demands_attention;

        XSendEvent(display, DefaultRootWindow(display), False, SubstructureRedirectMask | SubstructureNotifyMask, *xev);
    }

    // setting the urgency hint doesnt seem to do anything on gnome3
    // it seems _NET_WM_STATE_DEMANDS_ATTENTION better suits the task
    /*
    hints := XGetWMHints(display, win);
    if !hints then return;

    defer XFree(hints);

    hints.flags |= XUrgencyHint;

    if !XSetWMHints(display, win, hints) then return;
    */
}

x_selection_notify_predicate :: (display: *Display, event: *XEvent, arg: XPointer) -> Bool #c_call {
    if event.type == SelectionNotify {
        ev := cast(*XSelectionEvent) event;
        if ev.requestor == (.*) cast(*Window)arg
            return True;
    }
    return False;
}

x_window_is_ours :: (display: *Display, win: Window) -> bool {
    XLockDisplay(display);
    for x_global_windows {
        if win == it
            return true;
    }
    XUnlockDisplay(display);
    return false;
}

// immediate-mode helper GUI for some basic toolkit functions (message box, save file dialogue)

#scope_file
EVENT_MASK :: ExposureMask | KeyPressMask | KeyReleaseMask | ButtonPressMask | ButtonReleaseMask | ButtonMotionMask | PointerMotionMask;

ui_id :: s32;
NOT_ACTIVE :ui_id: -1;

Ui_Context :: struct {
    hot: ui_id = NOT_ACTIVE;
    active: ui_id = NOT_ACTIVE;
    mouse_x: s32;
    mouse_y: s32;
    mouse_went_up: bool;
    mouse_went_down: bool;
}

is_inside :: (ctx: *Ui_Context, x: s32, y: s32, width: u32, height: u32) -> bool {
    mx := ctx.mouse_x;
    my := ctx.mouse_y;

    return mx >= x && mx < (x + xx width) && my >= y && my < (y + xx height);
}

is_active :: (using ctx: *Ui_Context, id: ui_id) -> bool {
    return active == id;
}

is_hot :: (using ctx: *Ui_Context, id: ui_id) -> bool {
    return hot == id;
}

do_button :: (using ctx: *Ui_Context, id: ui_id, x: s32, y: s32, width: u32, height: u32) -> bool {
    result := false;
    if is_active(ctx, id) {
        if mouse_went_up {
            if is_hot(ctx, id) result = true;
            active = NOT_ACTIVE;
        }
    } else if is_hot(ctx, id) {
        if mouse_went_down active = id;
    }

    if is_inside(ctx, x, y, width, height) hot = id;
    else if is_hot(ctx, id) hot = NOT_ACTIVE;

    return result;
}

x_toolkit_update_events :: (dpy: *Display, win: Window, ctx: *Ui_Context, window_width: *s32 = null, window_height: *s32 = null) -> should_exit: bool, should_redraw: bool {
    e: XEvent;
    should_exit := false;
    should_redraw := false;
    while XCheckWindowEvent(dpy, win, EVENT_MASK, *e) {
        if e.type == Expose {
            if window_width then window_width.* = e.xexpose.width;
            if window_height then window_height.* = e.xexpose.height;
            should_redraw = true;
        } else if e.type == ButtonPress {
            if (e.xbutton.button == Button1) {
                ctx.mouse_went_down = true;
                should_redraw = true;
            }
            ctx.mouse_y = e.xbutton.y;
            ctx.mouse_x = e.xbutton.x;
        } else if e.type == ButtonRelease {
            if (e.xbutton.button == Button1) {
                ctx.mouse_went_up = true;
                should_redraw = true;
            }
            ctx.mouse_y = e.xbutton.y;
            ctx.mouse_x = e.xbutton.x;
        } else if e.type == MotionNotify {
            ctx.mouse_y = e.xmotion.y;
            ctx.mouse_x = e.xmotion.x;
            // print("%\n", ctx);
        }
    }

    // ClientMessage doesn't show up in XCheckWindowEvent so we handle that here
    if XCheckTypedWindowEvent(dpy, win, ClientMessage, *e) {
        if e.type == ClientMessage {
            if x_global_wm_delete_window == cast(Atom) e.xclient.data.l[0]
                && e.xclient.window == win {
                // do nothing ?
            }
        }
    }

    return should_exit, should_redraw;
}

#import "Basic";

#scope_export

// @Note this is intended to keep the X11 toolkit stuff self-contained and simple
// create_window from Window_Creation should be used instead for apps
x_toolkit_create_simple_window :: (dpy: *Display, parent: Window, width: s32, height: s32, title: string) -> Window {
    XLockDisplay(dpy);
    defer XUnlockDisplay(dpy);

    win := XCreateSimpleWindow(dpy, parent, 100, 100, cast(u32) width, cast(u32) height, 0, 0, 0);

    XSelectInput(dpy, win, EVENT_MASK);

    XSetWMProtocols(x_global_display, win, *x_global_wm_delete_window, 1);

    XStoreName(dpy, win, temp_c_string(title));
    XMapWindow(dpy, win);
    return win;
}

X_Message_Box_Response :: enum {
    ABORT;
    CANCEL;
    CONTINUE;
    IGNORE;
    NO;
    OK;
    RETRY;
    TRY_AGAIN;
    YES;
}

X_Message_Box_Style :: enum {
    ST_ABORT_RETRY_IGNORE;
    ST_CANCEL_TRY_CONTINUE;
    ST_OK;
    ST_OK_CANCEL;
    ST_RETRY_CANCEL;
    ST_YES_NO;
    ST_YES_NO_CANCEL;
}

x_message_box :: (parent: Window, msg: string, caption: string, style: X_Message_Box_Style) -> X_Message_Box_Response {
    init_global_display();
    dpy := x_global_display;

    // @TODO is it safe to lock the display here? Do we want to? It may be desirable to make all windows by other threads in our process wait on us,
    // unless the user code would want us to not block those...
    XLockDisplay(dpy);
    if parent == None
        parent = DefaultRootWindow(dpy);

    // @Robustness we should resize the window to fit the total bounds that our message + buttons would occupy
    DEFAULT_WIDTH :: 300;
    DEFAULT_HEIGHT :: 150;

    win := x_toolkit_create_simple_window(dpy, parent, DEFAULT_WIDTH, DEFAULT_HEIGHT, caption);

    // x_lock_window_size(dpy, win, DEFAULT_WIDTH, DEFAULT_HEIGHT);

    cmap := XDefaultColormap(dpy, DefaultScreen(dpy));
    s := DefaultScreen(dpy);

    grey := x_color_to_pixel(dpy, cmap, x_rgb_to_color(0xC0, 0xC0, 0xC0));
    black := XBlackPixel(dpy, DefaultScreen(dpy));

    gc := DefaultGC(dpy, s);

    XSetBackground(dpy, gc, grey);
    XSetForeground(dpy, gc, black);

    BUTTON_WIDTH :: 60;
    BUTTON_HEIGHT :: 30;
    BUTTON_SPACING :: 15;

    num_buttons: s32 = 3;
    button_texts: [3] string;
    responses: [3] X_Message_Box_Response;

    using X_Message_Box_Style;

    if style == {
        case ST_ABORT_RETRY_IGNORE;
            num_buttons = 3;
            button_texts[0] = "Abort";
            button_texts[1] = "Retry";
            button_texts[2] = "Ignore";
            responses[0] = X_Message_Box_Response.ABORT;
            responses[1] = X_Message_Box_Response.RETRY;
            responses[2] = X_Message_Box_Response.IGNORE;
        case ST_CANCEL_TRY_CONTINUE;
            num_buttons = 3;
            button_texts[0] = "Cancel";
            button_texts[1] = "Try Again";
            button_texts[2] = "Continue";
            responses[0] = X_Message_Box_Response.CANCEL;
            responses[1] = X_Message_Box_Response.TRY_AGAIN;
            responses[2] = X_Message_Box_Response.CONTINUE;
        case ST_OK;
            num_buttons = 1;
            button_texts[0] = "OK";
            responses[0] = X_Message_Box_Response.OK;
        case ST_OK_CANCEL;
            num_buttons = 2;
            button_texts[0] = "OK";
            button_texts[1] = "Cancel";
            responses[0] = X_Message_Box_Response.OK;
            responses[1] = X_Message_Box_Response.CANCEL;
        case ST_RETRY_CANCEL;
            num_buttons = 2;
            button_texts[0] = "Retry";
            button_texts[1] = "Cancel";
            responses[0] = X_Message_Box_Response.RETRY;
            responses[1] = X_Message_Box_Response.CANCEL;
        case ST_YES_NO;
            num_buttons = 2;
            button_texts[0] = "Yes";
            button_texts[1] = "No";
            responses[0] = X_Message_Box_Response.YES;
            responses[1] = X_Message_Box_Response.NO;
        case ST_YES_NO_CANCEL;
            num_buttons = 3;
            button_texts[0] = "Yes";
            button_texts[1] = "No";
            button_texts[2] = "Cancel";
            responses[0] = X_Message_Box_Response.YES;
            responses[1] = X_Message_Box_Response.NO;
            responses[2] = X_Message_Box_Response.CANCEL;
    }

    font := XQueryFont(dpy, XGContextFromGC(gc));
    defer XFreeFontInfo(null, font, 1);

    text_height := (font.ascent - font.descent) / 2;

    ctx: Ui_Context;

    x_offset: s32;
    y_offset: s32;
    window_width: s32;
    window_height: s32;
    response := X_Message_Box_Response.CANCEL;
    while true {
        should_exit, should_redraw := x_toolkit_update_events(dpy, win, *ctx, *window_width, *window_height);
        for 0..num_buttons-1 {
            if do_button(*ctx, it, x_offset + (BUTTON_WIDTH + BUTTON_SPACING) * it, y_offset, BUTTON_WIDTH, BUTTON_HEIGHT) {
                response = responses[it];
                should_exit = true;
                break;
            }
        }

        if should_exit break;

        if should_redraw {
            x_offset = (window_width / 2) - ((BUTTON_WIDTH*num_buttons + BUTTON_SPACING*(num_buttons-1)) / 2);
            BIAS :: 20;
            y_offset = (window_height / 2) + BIAS;

            XSetForeground(dpy, gc, grey);
            XFillRectangle(dpy, win, gc, 0, 0, xx window_width, xx window_height);

            XSetForeground(dpy, gc, black);
            text_width := XTextWidth(font, msg.data, cast(s32) msg.count) / 2;
            // x_draw_string(dpy, win, cast(s32) (window_width / 2) - text_width, cast(s32) (window_height / 2) + text_height - BIAS, msg);

            x_draw_textpanel(dpy, win, 20, 20, window_width - 40, y_offset - 40, msg);

            x_draw_button(dpy, win, x_offset, y_offset, BUTTON_WIDTH, BUTTON_HEIGHT, is_active(*ctx, 0), button_texts[0]);
            if num_buttons > 1 x_draw_button(dpy, win, x_offset + BUTTON_WIDTH + BUTTON_SPACING, y_offset, BUTTON_WIDTH, BUTTON_HEIGHT, is_active(*ctx, 1), button_texts[1]);
            if num_buttons > 2 x_draw_button(dpy, win, x_offset + 2 * (BUTTON_WIDTH + BUTTON_SPACING), y_offset, BUTTON_WIDTH, BUTTON_HEIGHT, is_active(*ctx, 2), button_texts[2]);

            XSync(dpy, False);
        }

        ctx.mouse_went_down = false;
        ctx.mouse_went_up = false;
    }

    XUnmapWindow(dpy, win);
    XDestroyWindow(dpy, win);

    XFlush(dpy);

    XUnlockDisplay(dpy);
    return response;
}

x_draw_textpanel :: (dpy: *Display, w: Window, x: s32, y: s32, width: s32, height: s32, msg: string) {
    gc := DefaultGC(dpy, DefaultScreen(dpy));

    font := XQueryFont(dpy, XGContextFromGC(gc));
    defer XFreeFontInfo(null, font, 1);

    text_height := (font.ascent - font.descent);

    arr: [] u8;
    arr.data = msg.data;
    arr.count = msg.count;

    current_line_width: s32;
    current_consumed_height: s32;
    current_line := msg;
    current_line.count = 0;
    for arr {
        slice := msg;
        slice.data += it_index;
        slice.count -= it_index;

        draw_line := current_line;
        draw_current_line := false;
        if (it == #char "\n") {
            draw_current_line = true;

            current_line_width = 0;
            current_line.data = msg.data + it_index + 1;
            current_line.count = 0;
        } else {
            // @TODO parse UTF8 character length
            slice.count = 1;
            char_width := x_textwidth(font, slice);

            if (current_line_width + char_width) > width {
                draw_current_line = true;
                current_line_width = 0;
                current_line.data = msg.data + it_index;
                current_line.count = 0;
            } else {
                current_line_width += char_width;
            }
        }


        if draw_current_line {
            if ((current_consumed_height + text_height) < height) {
                x_draw_string(dpy, w, x, y + current_consumed_height, draw_line);
                current_consumed_height += text_height;
            }
        } else {
            current_line.count += 1;
        }

        if (current_consumed_height >= height) break;
    }

    if ((current_consumed_height + text_height) < height) {
        x_draw_string(dpy, w, x, y + current_consumed_height, current_line);
        current_consumed_height += text_height;

        current_line_width = 0;
        // current_line.data = msg.data + it_index;
        // current_line.count = 0;
    }
}

x_color_to_pixel :: (dpy: *Display, cmap: Colormap, col: XColor) -> u64 {
    XAllocColor(dpy, cmap, *col);
    return col.pixel;
}

x_draw_button :: (dpy: *Display, w: Window, x: s32, y: s32, width: u32, height: u32, pressed: bool, msg: string) {
    white := XWhitePixel(dpy, DefaultScreen(dpy));
    black := XBlackPixel(dpy, DefaultScreen(dpy));

    cmap := XDefaultColormap(dpy, DefaultScreen(dpy));
    grey := x_color_to_pixel(dpy, cmap, x_rgb_to_color(0xC0, 0xC0, 0xC0));

    gc := DefaultGC(dpy, DefaultScreen(dpy));

    font := XQueryFont(dpy, XGContextFromGC(gc));
    defer XFreeFontInfo(null, font, 1);

    text_height := (font.ascent - font.descent) / 2;
    if !pressed {
        XSetForeground(dpy, gc, white);
        XFillRectangle(dpy, w, gc, x, y, width, height);

        XSetForeground(dpy, gc, black);
        XDrawRectangle(dpy, w, gc, x, y, width, height);

        XSetForeground(dpy, gc, grey);
        SCALE_FACTOR :: 10; // percent
        hdiff := (height / SCALE_FACTOR);
        wdiff := hdiff;
        XDrawRectangle(dpy, w, gc, x + cast(s32) wdiff, y + cast(s32) hdiff, width - wdiff*2,  height - hdiff*2);
    } else {
        XSetForeground(dpy, gc, grey);
        XFillRectangle(dpy, w, gc, x, y, width, height);

        XSetForeground(dpy, gc, black);
        XDrawRectangle(dpy, w, gc, x, y, width, height);
    }

    XSetForeground(dpy, gc, black);
    text_width := XTextWidth(font, msg.data, cast(s32) msg.count) / 2;
    XDrawString(dpy, w, gc, x + cast(s32) (width / 2) - text_width, y + cast(s32) (height / 2) + text_height, msg.data, cast(s32) msg.count);
}

x_draw_string :: (dpy: *Display, d: Drawable, x: s32, y: s32, msg: string) {
    gc := DefaultGC(dpy, DefaultScreen(dpy));
    XDrawString(dpy, d, gc, x, y, msg.data, cast(s32) msg.count);
}

x_textwidth :: (font: *XFontStruct, msg: string) -> s32 {
    return XTextWidth(font, msg.data, cast(s32) msg.count);
}

// end immediate-mode stuff



// @Note on some implementations of X servers, XSizeHints apparently doesn't work and you have to manually control the window size.
// On gnome3 at least, this correctly turns off the window resizing
x_lock_window_size :: (dpy: *Display, w: Window, width: s32, height: s32) {
    hints := XAllocSizeHints();
    hints.flags = PSize | PMinSize | PMaxSize;
    hints.min_width = width;
    hints.max_width = width;
    hints.min_height = height;
    hints.max_height = height;
    hints.width = width;
    hints.height = height;

    XSetWMNormalHints(dpy, w, hints);
    XFree(hints);
}

x_rgb_to_color :: (_r: u8, _g: u8, _b: u8) -> XColor {
    TO_16BIT_RANGE :: (1.0 / 255.0) * 65535.0;
    r := cast(u16) ((cast(float) _r) * TO_16BIT_RANGE);
    g := cast(u16) ((cast(float) _g) * TO_16BIT_RANGE);
    b := cast(u16) ((cast(float) _b) * TO_16BIT_RANGE);

    col: XColor;
    col.flags = DoRed | DoGreen | DoBlue;
    col.red = r;
    col.green = g;
    col.blue = b;
    return col;
}

// X bindings

// CARD32 :: u32;

XID :: u64;

Mask :: u64;

Atom :: u64;

VisualID :: u64;

Time :: u64;

Window :: XID;

Drawable :: XID;

Font :: XID;

Pixmap :: XID;

Cursor :: XID;

Colormap :: XID;

GContext :: XID;

KeySym :: XID;

KeyCode :: u8;


// <--- Xutil

InputHint        :: (1 << 0);
StateHint        :: (1 << 1);
IconPixmapHint   :: (1 << 2);
IconWindowHint   :: (1 << 3);
IconPositionHint :: (1 << 4);
IconMaskHint     :: (1 << 5);
WindowGroupHint  :: (1 << 6);
AllHints         :: (InputHint|StateHint|IconPixmapHint|IconWindowHint|IconPositionHint|IconMaskHint|WindowGroupHint);
XUrgencyHint     :: (1 << 8);

PAllHints :: PPosition | PSize | PMinSize | PMaxSize | PResizeInc | PAspect;

USPosition  :: (1 << 0);
USSize      :: (1 << 1);
PPosition   :: (1 << 2);
PSize       :: (1 << 3);
PMinSize    :: (1 << 4);
PMaxSize    :: (1 << 5);
PResizeInc  :: (1 << 6);
PAspect     :: (1 << 7);
PBaseSize   :: (1 << 8);
PWinGravity :: (1 << 9);


// ---> Xutil

Bool :: s32;
Status :: s32;

True :: 1;
False :: 0;

None :: 0;

Success :: 0;
BadRequest :: 1;
BadValue :: 2;
BadWindow :: 3;
BadPixmap :: 4;
BadAtom :: 5;
BadCursor :: 6;
BadFont :: 7;
BadMatch :: 8;
BadDrawable :: 9;
BadAccess :: 10;
BadAlloc :: 11;
BadColor :: 12;
BadGC :: 13;
BadIDChoice :: 14;
BadName :: 15;
BadLength :: 16;
BadImplementation :: 17;
FirstExtensionError :: 128;
LastExtensionError :: 255;

DoRed          :: (1 << 0);
DoGreen        :: (1 << 1);
DoBlue         :: (1 << 2);

XYBitmap       :: 0;
XYPixmap       :: 1;
ZPixmap        :: 2;

GCFunction          :: (1 << 0);
GCPlaneMask         :: (1 << 1);
GCForeground        :: (1 << 2);
GCBackground        :: (1 << 3);
GCLineWidth         :: (1 << 4);
GCLineStyle         :: (1 << 5);
GCCapStyle          :: (1 << 6);
GCJoinStyle         :: (1 << 7);
GCFillStyle         :: (1 << 8);
GCFillRule          :: (1 << 9);
GCTile              :: (1 << 10);
GCStipple           :: (1 << 11);
GCTileStipXOrigin   :: (1 << 12);
GCTileStipYOrigin   :: (1 << 13);
GCFont              :: (1 << 14);
GCSubwindowMode     :: (1 << 15);
GCGraphicsExposures :: (1 << 16);
GCClipXOrigin       :: (1 << 17);
GCClipYOrigin       :: (1 << 18);
GCClipMask          :: (1 << 19);
GCDashOffset        :: (1 << 20);
GCDashList          :: (1 << 21);
GCArcMode           :: (1 << 22);

GCLastBit           :: 22;

ParentRelative :: 1;
CopyFromParent :: 0;
PointerWindow :: 0;
InputFocus :: 1;
PointerRoot :: 1;
AnyPropertyType :: 0;
AnyKey :: 0;
AnyButton :: 0;
AllTemporary :: 0;
CurrentTime :: 0;
NoSymbol :: 0;

GrabModeSync     :: 0;
GrabModeAsync    :: 1;

GrabSuccess      :: 0;
AlreadyGrabbed   :: 1;
GrabInvalidTime  :: 2;
GrabNotViewable  :: 3;
GrabFrozen       :: 4;

PropModeReplace  :: 0;
PropModePrepend  :: 1;
PropModeAppend   :: 2;

AllocNone :: 0;
AllocAll  :: 1;

// standard Atoms from Xatom
XA_PRIMARY ::  1;
XA_SECONDARY ::  2;
XA_ARC ::  3;
XA_ATOM ::  4;
XA_BITMAP ::  5;
XA_CARDINAL ::  6;
XA_COLORMAP ::  7;
XA_CURSOR ::  8;
XA_CUT_BUFFER0 ::  9;
XA_CUT_BUFFER1 ::  10;
XA_CUT_BUFFER2 ::  11;
XA_CUT_BUFFER3 ::  12;
XA_CUT_BUFFER4 ::  13;
XA_CUT_BUFFER5 ::  14;
XA_CUT_BUFFER6 ::  15;
XA_CUT_BUFFER7 ::  16;
XA_DRAWABLE ::  17;
XA_FONT ::  18;
XA_INTEGER ::  19;
XA_PIXMAP ::  20;
XA_POINT ::  21;
XA_RECTANGLE ::  22;
XA_RESOURCE_MANAGER ::  23;
XA_RGB_COLOR_MAP ::  24;
XA_RGB_BEST_MAP ::  25;
XA_RGB_BLUE_MAP ::  26;
XA_RGB_DEFAULT_MAP ::  27;
XA_RGB_GRAY_MAP ::  28;
XA_RGB_GREEN_MAP ::  29;
XA_RGB_RED_MAP ::  30;
XA_STRING ::  31;
XA_VISUALID ::  32;
XA_WINDOW ::  33;
XA_WM_COMMAND ::  34;
XA_WM_HINTS ::  35;
XA_WM_CLIENT_MACHINE ::  36;
XA_WM_ICON_NAME ::  37;
XA_WM_ICON_SIZE ::  38;
XA_WM_NAME ::  39;
XA_WM_NORMAL_HINTS ::  40;
XA_WM_SIZE_HINTS ::  41;
XA_WM_ZOOM_HINTS ::  42;
XA_MIN_SPACE ::  43;
XA_NORM_SPACE ::  44;
XA_MAX_SPACE ::  45;
XA_END_SPACE ::  46;
XA_SUPERSCRIPT_X ::  47;
XA_SUPERSCRIPT_Y ::  48;
XA_SUBSCRIPT_X ::  49;
XA_SUBSCRIPT_Y ::  50;
XA_UNDERLINE_POSITION ::  51;
XA_UNDERLINE_THICKNESS ::  52;
XA_STRIKEOUT_ASCENT ::  53;
XA_STRIKEOUT_DESCENT ::  54;
XA_ITALIC_ANGLE ::  55;
XA_X_HEIGHT ::  56;
XA_QUAD_WIDTH ::  57;
XA_WEIGHT ::  58;
XA_POINT_SIZE ::  59;
XA_RESOLUTION ::  60;
XA_COPYRIGHT ::  61;
XA_NOTICE ::  62;
XA_FONT_NAME ::  63;
XA_FAMILY_NAME ::  64;
XA_FULL_NAME ::  65;
XA_CAP_HEIGHT ::  66;
XA_WM_CLASS ::  67;
XA_WM_TRANSIENT_FOR ::  68;


QueuedAlready      :: 0;
QueuedAfterReading :: 1;
QueuedAfterFlush   :: 2;

NoEventMask              :: 0;
KeyPressMask             :: (1 << 0);
KeyReleaseMask           :: (1 << 1);
ButtonPressMask          :: (1 << 2);
ButtonReleaseMask        :: (1 << 3);
EnterWindowMask          :: (1 << 4);
LeaveWindowMask          :: (1 << 5);
PointerMotionMask        :: (1 << 6);
PointerMotionHintMask    :: (1 << 7);
Button1MotionMask        :: (1 << 8);
Button2MotionMask        :: (1 << 9);
Button3MotionMask        :: (1 << 10);
Button4MotionMask        :: (1 << 11);
Button5MotionMask        :: (1 << 12);
ButtonMotionMask         :: (1 << 13);
KeymapStateMask          :: (1 << 14);
ExposureMask             :: (1 << 15);
VisibilityChangeMask     :: (1 << 16);
StructureNotifyMask      :: (1 << 17);
ResizeRedirectMask       :: (1 << 18);
SubstructureNotifyMask   :: (1 << 19);
SubstructureRedirectMask :: (1 << 20);
FocusChangeMask          :: (1 << 21);
PropertyChangeMask       :: (1 << 22);
ColormapChangeMask       :: (1 << 23);
OwnerGrabButtonMask      :: (1 << 24);

KeyPress            :: 2;
KeyRelease          :: 3;
ButtonPress         :: 4;
ButtonRelease       :: 5;
MotionNotify        :: 6;
EnterNotify         :: 7;
LeaveNotify         :: 8;
FocusIn             :: 9;
FocusOut            :: 10;
KeymapNotify        :: 11;
Expose              :: 12;
GraphicsExpose      :: 13;
NoExpose            :: 14;
VisibilityNotify    :: 15;
CreateNotify        :: 16;
DestroyNotify       :: 17;
UnmapNotify         :: 18;
MapNotify           :: 19;
MapRequest          :: 20;
ReparentNotify      :: 21;
ConfigureNotify     :: 22;
ConfigureRequest    :: 23;
GravityNotify       :: 24;
ResizeRequest       :: 25;
CirculateNotify     :: 26;
CirculateRequest    :: 27;
PropertyNotify      :: 28;
SelectionClear      :: 29;
SelectionRequest    :: 30;
SelectionNotify     :: 31;
ColormapNotify      :: 32;
ClientMessage       :: 33;
MappingNotify       :: 34;
GenericEvent        :: 35;

Button1       :: 1;
Button2       :: 2;
Button3       :: 3;
Button4       :: 4;
Button5       :: 5;

InputOutput :: 1;
InputOnly   :: 2;

CWEventMask :: (1 << 11);
CWColormap  :: (1 << 13);


ShiftMask      :: (1 << 0);
LockMask       :: (1 << 1);
ControlMask    :: (1 << 2);
Mod1Mask       :: (1 << 3);
Mod2Mask       :: (1 << 4);
Mod3Mask       :: (1 << 5);
Mod4Mask       :: (1 << 6);
Mod5Mask       :: (1 << 7);

Button1Mask    :: (1 << 8);
Button2Mask    :: (1 << 9);
Button3Mask    :: (1 << 10);
Button4Mask    :: (1 << 11);
Button5Mask    :: (1 << 12);

XIMPreeditArea      :: 0x0001;
XIMPreeditCallbacks :: 0x0002;
XIMPreeditPosition  :: 0x0004;
XIMPreeditNothing   :: 0x0008;
XIMPreeditNone      :: 0x0010;
XIMStatusArea       :: 0x0100;
XIMStatusCallbacks  :: 0x0200;
XIMStatusNothing    :: 0x0400;
XIMStatusNone       :: 0x0800;

XNClientWindow :: "clientWindow".data;
XNFocusWindow  :: "focusWindow".data;
XNInputStyle   :: "inputStyle".data;

XBufferOverflow :: -1;
XLookupNone     ::  1;
XLookupChars    ::  2;
XLookupKeySym   ::  3;
XLookupBoth     ::  4;


// keysym defs

XK_ISO_Left_Tab            ::  0xfe20;
XK_BackSpace               ::  0xff08;
XK_Tab                     ::  0xff09;
XK_Linefeed                ::  0xff0a;
XK_Clear                   ::  0xff0b;
XK_Return                  ::  0xff0d;
XK_Pause                   ::  0xff13;
XK_Scroll_Lock             ::  0xff14;
XK_Sys_Req                 ::  0xff15;
XK_Escape                  ::  0xff1b;
XK_Delete                  ::  0xffff;

XK_Home                    ::  0xff50;
XK_Left                    ::  0xff51;
XK_Up                      ::  0xff52;
XK_Right                   ::  0xff53;
XK_Down                    ::  0xff54;
XK_Prior                   ::  0xff55;
XK_Page_Up                 ::  0xff55;
XK_Next                    ::  0xff56;
XK_Page_Down               ::  0xff56;
XK_End                     ::  0xff57;
XK_Begin                   ::  0xff58;

XK_F1                      ::  0xffbe;
XK_F2                      ::  0xffbf;
XK_F3                      ::  0xffc0;
XK_F4                      ::  0xffc1;
XK_F5                      ::  0xffc2;
XK_F6                      ::  0xffc3;
XK_F7                      ::  0xffc4;
XK_F8                      ::  0xffc5;
XK_F9                      ::  0xffc6;
XK_F10                     ::  0xffc7;
XK_F11                     ::  0xffc8;
XK_L1                      ::  0xffc8;
XK_F12                     ::  0xffc9;
XK_L2                      ::  0xffc9;
XK_F13                     ::  0xffca;
XK_L3                      ::  0xffca;
XK_F14                     ::  0xffcb;
XK_L4                      ::  0xffcb;
XK_F15                     ::  0xffcc;
XK_L5                      ::  0xffcc;
XK_F16                     ::  0xffcd;
XK_L6                      ::  0xffcd;
XK_F17                     ::  0xffce;
XK_L7                      ::  0xffce;
XK_F18                     ::  0xffcf;
XK_L8                      ::  0xffcf;
XK_F19                     ::  0xffd0;
XK_L9                      ::  0xffd0;
XK_F20                     ::  0xffd1;
XK_L10                     ::  0xffd1;
XK_F21                     ::  0xffd2;
XK_R1                      ::  0xffd2;
XK_F22                     ::  0xffd3;
XK_R2                      ::  0xffd3;
XK_F23                     ::  0xffd4;
XK_R3                      ::  0xffd4;
XK_F24                     ::  0xffd5;
XK_R4                      ::  0xffd5;
XK_F25                     ::  0xffd6;
XK_R5                      ::  0xffd6;
XK_F26                     ::  0xffd7;
XK_R6                      ::  0xffd7;
XK_F27                     ::  0xffd8;
XK_R7                      ::  0xffd8;
XK_F28                     ::  0xffd9;
XK_R8                      ::  0xffd9;
XK_F29                     ::  0xffda;
XK_R9                      ::  0xffda;
XK_F30                     ::  0xffdb;
XK_R10                     ::  0xffdb;
XK_F31                     ::  0xffdc;
XK_R11                     ::  0xffdc;
XK_F32                     ::  0xffdd;
XK_R12                     ::  0xffdd;
XK_F33                     ::  0xffde;
XK_R13                     ::  0xffde;
XK_F34                     ::  0xffdf;
XK_R14                     ::  0xffdf;
XK_F35                     ::  0xffe0;
XK_R15                     ::  0xffe0;


XK_Shift_L                 ::  0xffe1;
XK_Shift_R                 ::  0xffe2;
XK_Control_L               ::  0xffe3;
XK_Control_R               ::  0xffe4;
XK_Caps_Lock               ::  0xffe5;
XK_Shift_Lock              ::  0xffe6;

XK_Meta_L                  ::  0xffe7;
XK_Meta_R                  ::  0xffe8;
XK_Alt_L                   ::  0xffe9;
XK_Alt_R                   ::  0xffea;
XK_Super_L                 ::  0xffeb;
XK_Super_R                 ::  0xffec;
XK_Hyper_L                 ::  0xffed;
XK_Hyper_R                 ::  0xffee;

XK_space                   ::  0x0020;
XK_exclam                  ::  0x0021;
XK_quotedbl                ::  0x0022;
XK_numbersign              ::  0x0023;
XK_dollar                  ::  0x0024;
XK_percent                 ::  0x0025;
XK_ampersand               ::  0x0026;
XK_apostrophe              ::  0x0027;
XK_quoteright              ::  0x0027;
XK_parenleft               ::  0x0028;
XK_parenright              ::  0x0029;
XK_asterisk                ::  0x002a;
XK_plus                    ::  0x002b;
XK_comma                   ::  0x002c;
XK_minus                   ::  0x002d;
XK_period                  ::  0x002e;
XK_slash                   ::  0x002f;
XK_0                       ::  0x0030;
XK_1                       ::  0x0031;
XK_2                       ::  0x0032;
XK_3                       ::  0x0033;
XK_4                       ::  0x0034;
XK_5                       ::  0x0035;
XK_6                       ::  0x0036;
XK_7                       ::  0x0037;
XK_8                       ::  0x0038;
XK_9                       ::  0x0039;
XK_colon                   ::  0x003a;
XK_semicolon               ::  0x003b;
XK_less                    ::  0x003c;
XK_equal                   ::  0x003d;
XK_greater                 ::  0x003e;
XK_question                ::  0x003f;
XK_at                      ::  0x0040;
XK_A                       ::  0x0041;
XK_B                       ::  0x0042;
XK_C                       ::  0x0043;
XK_D                       ::  0x0044;
XK_E                       ::  0x0045;
XK_F                       ::  0x0046;
XK_G                       ::  0x0047;
XK_H                       ::  0x0048;
XK_I                       ::  0x0049;
XK_J                       ::  0x004a;
XK_K                       ::  0x004b;
XK_L                       ::  0x004c;
XK_M                       ::  0x004d;
XK_N                       ::  0x004e;
XK_O                       ::  0x004f;
XK_P                       ::  0x0050;
XK_Q                       ::  0x0051;
XK_R                       ::  0x0052;
XK_S                       ::  0x0053;
XK_T                       ::  0x0054;
XK_U                       ::  0x0055;
XK_V                       ::  0x0056;
XK_W                       ::  0x0057;
XK_X                       ::  0x0058;
XK_Y                       ::  0x0059;
XK_Z                       ::  0x005a;
XK_bracketleft             ::  0x005b;
XK_backslash               ::  0x005c;
XK_bracketright            ::  0x005d;
XK_asciicircum             ::  0x005e;
XK_underscore              ::  0x005f;
XK_grave                   ::  0x0060;
XK_quoteleft               ::  0x0060;
XK_a                       ::  0x0061;
XK_b                       ::  0x0062;
XK_c                       ::  0x0063;
XK_d                       ::  0x0064;
XK_e                       ::  0x0065;
XK_f                       ::  0x0066;
XK_g                       ::  0x0067;
XK_h                       ::  0x0068;
XK_i                       ::  0x0069;
XK_j                       ::  0x006a;
XK_k                       ::  0x006b;
XK_l                       ::  0x006c;
XK_m                       ::  0x006d;
XK_n                       ::  0x006e;
XK_o                       ::  0x006f;
XK_p                       ::  0x0070;
XK_q                       ::  0x0071;
XK_r                       ::  0x0072;
XK_s                       ::  0x0073;
XK_t                       ::  0x0074;
XK_u                       ::  0x0075;
XK_v                       ::  0x0076;
XK_w                       ::  0x0077;
XK_x                       ::  0x0078;
XK_y                       ::  0x0079;
XK_z                       ::  0x007a;
XK_braceleft               ::  0x007b;
XK_bar                     ::  0x007c;
XK_braceright              ::  0x007d;
XK_asciitilde              ::  0x007e;

XK_Print                   ::  0xff61;
XK_Insert                  ::  0xff63;
XK_Menu                    ::  0xff67;

XK_KP_Space                ::  0xff80;
XK_KP_Tab                  ::  0xff89;
XK_KP_Enter                ::  0xff8d;
XK_KP_F1                   ::  0xff91;
XK_KP_F2                   ::  0xff92;
XK_KP_F3                   ::  0xff93;
XK_KP_F4                   ::  0xff94;
XK_KP_Home                 ::  0xff95;
XK_KP_Left                 ::  0xff96;
XK_KP_Up                   ::  0xff97;
XK_KP_Right                ::  0xff98;
XK_KP_Down                 ::  0xff99;
XK_KP_Prior                ::  0xff9a;
XK_KP_Page_Up              ::  0xff9a;
XK_KP_Next                 ::  0xff9b;
XK_KP_Page_Down            ::  0xff9b;
XK_KP_End                  ::  0xff9c;
XK_KP_Begin                ::  0xff9d;
XK_KP_Insert               ::  0xff9e;
XK_KP_Delete               ::  0xff9f;
XK_KP_Equal                ::  0xffbd;
XK_KP_Multiply             ::  0xffaa;
XK_KP_Add                  ::  0xffab;
XK_KP_Separator            ::  0xffac;
XK_KP_Subtract             ::  0xffad;
XK_KP_Decimal              ::  0xffae;
XK_KP_Divide               ::  0xffaf;
XK_KP_0                    ::  0xffb0;
XK_KP_1                    ::  0xffb1;
XK_KP_2                    ::  0xffb2;
XK_KP_3                    ::  0xffb3;
XK_KP_4                    ::  0xffb4;
XK_KP_5                    ::  0xffb5;
XK_KP_6                    ::  0xffb6;
XK_KP_7                    ::  0xffb7;
XK_KP_8                    ::  0xffb8;
XK_KP_9                    ::  0xffb9;

XK_ISO_Level3_Shift        ::  0xfe03;

_Xmblen: #type (str: *u8, len: s32) -> s32 #c_call;

XPointer :: *void;

_XExtData :: struct {
    number: s32;
    next: *_XExtData;
    free_private: #type (a0: *_XExtData) -> s32 #c_call;
    private_data: XPointer;
}

XExtData :: _XExtData;

XExtCodes :: struct {
    extension: s32;
    major_opcode: s32;
    first_event: s32;
    first_error: s32;
}

XPixmapFormatValues :: struct {
    depth: s32;
    bits_per_pixel: s32;
    scanline_pad: s32;
}

XGCValues :: struct {
    function: s32;
    plane_mask: u64;
    foreground: u64;
    background: u64;
    line_width: s32;
    line_style: s32;
    cap_style: s32;
    join_style: s32;
    fill_style: s32;
    fill_rule: s32;
    arc_mode: s32;
    tile: Pixmap;
    stipple: Pixmap;
    ts_x_origin: s32;
    ts_y_origin: s32;
    font: Font;
    subwindow_mode: s32;
    graphics_exposures: s32;
    clip_x_origin: s32;
    clip_y_origin: s32;
    clip_mask: Pixmap;
    dash_offset: s32;
    dashes: u8;
}

_XGC :: struct {
    ext_data: XExtData;
    gid: GContext;
}

GC :: *_XGC;

Visual :: struct {
    ext_data: *XExtData;
    visualid: VisualID;
    class: s32;
    red_mask: u64;
    green_mask: u64;
    blue_mask: u64;
    bits_per_rgb: s32;
    map_entries: s32;
}


Depth :: struct {
    depth: s32;
    nvisuals: s32;
    visuals: *Visual;
}

_XDisplay :: struct {
}

Screen :: struct {
    ext_data: *XExtData;
    display: *_XDisplay;
    root: Window;
    width: s32;
    height: s32;
    mwidth: s32;
    mheight: s32;
    ndepths: s32;
    depths: *Depth;
    root_depth: s32;
    root_visual: *Visual;
    default_gc: GC;
    cmap: Colormap;
    white_pixel: u64;
    black_pixel: u64;
    max_maps: s32;
    min_maps: s32;
    backing_store: s32;
    save_unders: s32;
    root_input_mask: s64;
}

ScreenFormat :: struct {
    ext_data: *XExtData;
    depth: s32;
    bits_per_pixel: s32;
    scanline_pad: s32;
}

XSetWindowAttributes :: struct {
    background_pixmap: Pixmap;
    background_pixel: u64;
    border_pixmap: Pixmap;
    border_pixel: u64;
    bit_gravity: s32;
    win_gravity: s32;
    backing_store: s32;
    backing_planes: u64;
    backing_pixel: u64;
    save_under: s32;
    event_mask: s64;
    do_not_propagate_mask: s64;
    override_redirect: s32;
    colormap: Colormap;
    cursor: Cursor;
}

XWindowAttributes :: struct {
    x: s32;
    y: s32;
    width: s32;
    height: s32;
    border_width: s32;
    depth: s32;
    visual: *Visual;
    root: Window;
    class: s32;
    bit_gravity: s32;
    win_gravity: s32;
    backing_store: s32;
    backing_planes: u64;
    backing_pixel: u64;
    save_under: s32;
    colormap: Colormap;
    map_installed: s32;
    map_state: s32;
    all_event_masks: s64;
    your_event_mask: s64;
    do_not_propagate_mask: s64;
    override_redirect: s32;
    screen: *Screen;
}

XHostAddress :: struct {
    family: s32;
    length: s32;
    address: *u8;
}

XServerInterpretedAddress :: struct {
    typelength: s32;
    valuelength: s32;
    type: *u8;
    value: *u8;
}

_XImage :: struct {
    width: s32;
    height: s32;
    xoffset: s32;
    format: s32;
    data: *u8;
    byte_order: s32;
    bitmap_unit: s32;
    bitmap_bit_order: s32;
    bitmap_pad: s32;
    depth: s32;
    bytes_per_line: s32;
    bits_per_pixel: s32;
    red_mask: u64;
    green_mask: u64;
    blue_mask: u64;
    obdata: XPointer;
    funcs :: struct {
        create_image: #type (a0: *_XDisplay, a1: *Visual, a2: u32, a3: s32, a4: s32, a5: *u8, a6: u32, a7: u32, a8: s32, a9: s32) -> *_XImage #c_call;
        destroy_image: #type (a0: *_XImage) -> s32 #c_call;
        get_pixel: #type (a0: *_XImage, a1: s32, a2: s32) -> u64 #c_call;
        put_pixel: #type (a0: *_XImage, a1: s32, a2: s32, a3: u64) -> s32 #c_call;
        sub_image: #type (a0: *_XImage, a1: s32, a2: s32, a3: u32, a4: u32) -> *_XImage #c_call;
        add_pixel: #type (a0: *_XImage, a1: s64) -> s32 #c_call;
    }
    f: funcs;
}

XImage :: _XImage;

XWindowChanges :: struct {
    x: s32;
    y: s32;
    width: s32;
    height: s32;
    border_width: s32;
    sibling: Window;
    stack_mode: s32;
}

XColor :: struct {
    pixel: u64;
    red: u16;
    green: u16;
    blue: u16;
    flags: u8;
    pad: u8;
}

XSegment :: struct {
    x1: s16;
    y1: s16;
    x2: s16;
    y2: s16;
}

XPoint :: struct {
    x: s16;
    y: s16;
}

XRectangle :: struct {
    x: s16;
    y: s16;
    width: u16;
    height: u16;
}

XArc :: struct {
    x: s16;
    y: s16;
    width: u16;
    height: u16;
    angle1: s16;
    angle2: s16;
}

XKeyboardControl :: struct {
    key_click_percent: s32;
    bell_percent: s32;
    bell_pitch: s32;
    bell_duration: s32;
    led: s32;
    led_mode: s32;
    key: s32;
    auto_repeat_mode: s32;
}

XKeyboardState :: struct {
    key_click_percent: s32;
    bell_percent: s32;
    bell_pitch: u32;
    bell_duration: u32;
    led_mask: u64;
    global_auto_repeat: s32;
    auto_repeats: [32] u8;
}

XTimeCoord :: struct {
    time: Time;
    x: s16;
    y: s16;
}

XModifierKeymap :: struct {
    max_keypermod: s32;
    modifiermap: *KeyCode;
}

Display :: _XDisplay;

_XPrivate :: struct {
}

_XrmHashBucketRec :: struct {
}

_XPrivDisplay :: *__XPrivDisplay;
__XPrivDisplay :: struct {
    ext_data: *XExtData;
    private1: *_XPrivate;
    fd: s32;
    private2: s32;
    proto_major_version: s32;
    proto_minor_version: s32;
    vendor: *u8;
    private3: XID;
    private4: XID;
    private5: XID;
    private6: s32;
    resource_alloc: #type (a0: *_XDisplay) -> XID #c_call;
    byte_order: s32;
    bitmap_unit: s32;
    bitmap_pad: s32;
    bitmap_bit_order: s32;
    nformats: s32;
    pixmap_format: *ScreenFormat;
    private8: s32;
    release: s32;
    private9: *_XPrivate;
    private10: *_XPrivate;
    qlen: s32;
    last_request_read: u64;
    request: u64;
    private11: XPointer;
    private12: XPointer;
    private13: XPointer;
    private14: XPointer;
    max_request_size: u32;
    db: *_XrmHashBucketRec;
    private15: #type (a0: *_XDisplay) -> s32 #c_call;
    display_name: *u8;
    default_screen: s32;
    nscreens: s32;
    screens: *Screen;
    motion_buffer: u64;
    private16: u64;
    min_keycode: s32;
    max_keycode: s32;
    private17: XPointer;
    private18: XPointer;
    private19: s32;
    xdefaults: *u8;
}

XKeyEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    window: Window;
    root: Window;
    subwindow: Window;
    time: Time;
    x: s32;
    y: s32;
    x_root: s32;
    y_root: s32;
    state: u32;
    keycode: u32;
    same_screen: s32;
}

XKeyPressedEvent :: XKeyEvent;

XKeyReleasedEvent :: XKeyEvent;

XButtonEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    window: Window;
    root: Window;
    subwindow: Window;
    time: Time;
    x: s32;
    y: s32;
    x_root: s32;
    y_root: s32;
    state: u32;
    button: u32;
    same_screen: s32;
}

XButtonPressedEvent :: XButtonEvent;

XButtonReleasedEvent :: XButtonEvent;

XMotionEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    window: Window;
    root: Window;
    subwindow: Window;
    time: Time;
    x: s32;
    y: s32;
    x_root: s32;
    y_root: s32;
    state: u32;
    is_hint: u8;
    same_screen: s32;
}

XPointerMovedEvent :: XMotionEvent;

XCrossingEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    window: Window;
    root: Window;
    subwindow: Window;
    time: Time;
    x: s32;
    y: s32;
    x_root: s32;
    y_root: s32;
    mode: s32;
    detail: s32;
    same_screen: s32;
    focus: s32;
    state: u32;
}

XEnterWindowEvent :: XCrossingEvent;

XLeaveWindowEvent :: XCrossingEvent;

XFocusChangeEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    window: Window;
    mode: s32;
    detail: s32;
}

XFocusInEvent :: XFocusChangeEvent;

XFocusOutEvent :: XFocusChangeEvent;

XKeymapEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    window: Window;
    key_vector: [32] u8;
}

XExposeEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    window: Window;
    x: s32;
    y: s32;
    width: s32;
    height: s32;
    count: s32;
}

XGraphicsExposeEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    drawable: Drawable;
    x: s32;
    y: s32;
    width: s32;
    height: s32;
    count: s32;
    major_code: s32;
    minor_code: s32;
}

XNoExposeEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    drawable: Drawable;
    major_code: s32;
    minor_code: s32;
}

XVisibilityEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    window: Window;
    state: s32;
}

XCreateWindowEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    parent: Window;
    window: Window;
    x: s32;
    y: s32;
    width: s32;
    height: s32;
    border_width: s32;
    override_redirect: s32;
}

XDestroyWindowEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    event: Window;
    window: Window;
}

XUnmapEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    event: Window;
    window: Window;
    from_configure: s32;
}

XMapEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    event: Window;
    window: Window;
    override_redirect: s32;
}

XMapRequestEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    parent: Window;
    window: Window;
}

XReparentEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    event: Window;
    window: Window;
    parent: Window;
    x: s32;
    y: s32;
    override_redirect: s32;
}

XConfigureEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    event: Window;
    window: Window;
    x: s32;
    y: s32;
    width: s32;
    height: s32;
    border_width: s32;
    above: Window;
    override_redirect: s32;
}

XGravityEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    event: Window;
    window: Window;
    x: s32;
    y: s32;
}

XResizeRequestEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    window: Window;
    width: s32;
    height: s32;
}

XConfigureRequestEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    parent: Window;
    window: Window;
    x: s32;
    y: s32;
    width: s32;
    height: s32;
    border_width: s32;
    above: Window;
    detail: s32;
    value_mask: u64;
}

XCirculateEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    event: Window;
    window: Window;
    place: s32;
}

XCirculateRequestEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    parent: Window;
    window: Window;
    place: s32;
}

XPropertyEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    window: Window;
    atom: Atom;
    time: Time;
    state: s32;
}

XSelectionClearEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    window: Window;
    selection: Atom;
    time: Time;
}

XSelectionRequestEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    owner: Window;
    requestor: Window;
    selection: Atom;
    target: Atom;
    property: Atom;
    time: Time;
}

XSelectionEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    requestor: Window;
    selection: Atom;
    target: Atom;
    property: Atom;
    time: Time;
}

XColormapEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    window: Window;
    colormap: Colormap;
    new: s32;
    state: s32;
}

XClientMessageEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    window: Window;
    message_type: Atom;
    format: s32;
    data: union {
        b: [20] u8;
        s: [10] s16;
        l: [5] s64;
    };
}

XMappingEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    window: Window;
    request: s32;
    first_keycode: s32;
    count: s32;
}

XErrorEvent :: struct {
    type: s32;
    display: *Display;
    resourceid: XID;
    serial: u64;
    error_code: u8;
    request_code: u8;
    minor_code: u8;
}

XAnyEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    window: Window;
}

XGenericEvent :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    extension: s32;
    evtype: s32;
}

XGenericEventCookie :: struct {
    type: s32;
    serial: u64;
    send_event: s32;
    display: *Display;
    extension: s32;
    evtype: s32;
    cookie: u32;
    data: *void;
}

_XEvent :: union {
    type: s32;
    xany: XAnyEvent;
    xkey: XKeyEvent;
    xbutton: XButtonEvent;
    xmotion: XMotionEvent;
    xcrossing: XCrossingEvent;
    xfocus: XFocusChangeEvent;
    xexpose: XExposeEvent;
    xgraphicsexpose: XGraphicsExposeEvent;
    xnoexpose: XNoExposeEvent;
    xvisibility: XVisibilityEvent;
    xcreatewindow: XCreateWindowEvent;
    xdestroywindow: XDestroyWindowEvent;
    xunmap: XUnmapEvent;
    xmap: XMapEvent;
    xmaprequest: XMapRequestEvent;
    xreparent: XReparentEvent;
    xconfigure: XConfigureEvent;
    xgravity: XGravityEvent;
    xresizerequest: XResizeRequestEvent;
    xconfigurerequest: XConfigureRequestEvent;
    xcirculate: XCirculateEvent;
    xcirculaterequest: XCirculateRequestEvent;
    xproperty: XPropertyEvent;
    xselectionclear: XSelectionClearEvent;
    xselectionrequest: XSelectionRequestEvent;
    xselection: XSelectionEvent;
    xcolormap: XColormapEvent;
    xclient: XClientMessageEvent;
    xmapping: XMappingEvent;
    xerror: XErrorEvent;
    xkeymap: XKeymapEvent;
    xgeneric: XGenericEvent;
    xcookie: XGenericEventCookie;
    pad: [24] s64;
}

XEvent :: _XEvent;

XCharStruct :: struct {
    lbearing: s16;
    rbearing: s16;
    width: s16;
    ascent: s16;
    descent: s16;
    attributes: u16;
}

XFontProp :: struct {
    name: Atom;
    card32: u64;
}

XFontStruct :: struct {
    ext_data: *XExtData;
    fid: Font;
    direction: u32;
    min_char_or_byte2: u32;
    max_char_or_byte2: u32;
    min_byte1: u32;
    max_byte1: u32;
    all_chars_exist: s32;
    default_char: u32;
    n_properties: s32;
    properties: *XFontProp;
    min_bounds: XCharStruct;
    max_bounds: XCharStruct;
    per_char: *XCharStruct;
    ascent: s32;
    descent: s32;
}

XTextItem :: struct {
    chars: *u8;
    nchars: s32;
    delta: s32;
    font: Font;
}

XChar2b :: struct {
    byte1: u8;
    byte2: u8;
}

XTextItem16 :: struct {
    chars: *XChar2b;
    nchars: s32;
    delta: s32;
    font: Font;
}

XEDataObject :: union {
    display: *Display;
    gc: GC;
    visual: *Visual;
    screen: *Screen;
    pixmap_format: *ScreenFormat;
    font: *XFontStruct;
}

XFontSetExtents :: struct {
    max_ink_extent: XRectangle;
    max_logical_extent: XRectangle;
}

_XOM :: struct {
}

XOM :: *_XOM;

_XOC :: struct {
}

XOC :: *_XOC;

XFontSet :: *_XOC;

XmbTextItem :: struct {
    chars: *u8;
    nchars: s32;
    delta: s32;
    font_set: XFontSet;
}

XwcTextItem :: struct {
    chars: *wchar_t;
    nchars: s32;
    delta: s32;
    font_set: XFontSet;
}

XOMCharSetList :: struct {
    charset_count: s32;
    charset_list: **u8;
}

using XOrientation :: enum u32 {
    XOMOrientation_LTR_TTB :: 0;
    XOMOrientation_RTL_TTB :: 1;
    XOMOrientation_TTB_LTR :: 2;
    XOMOrientation_TTB_RTL :: 3;
    XOMOrientation_Context :: 4;
}

XOMOrientation :: struct {
    num_orientation: s32;
    orientation: *XOrientation;
}

XOMFontInfo :: struct {
    num_font: s32;
    font_struct_list: **XFontStruct;
    font_name_list: **u8;
}

_XIM :: struct {
}

XIM :: *_XIM;

_XIC :: struct {
}

XIC :: *_XIC;

XIMProc :: #type (a0: XIM, a1: XPointer, a2: XPointer) -> void #c_call;

XICProc :: #type (a0: XIC, a1: XPointer, a2: XPointer) -> s32 #c_call;

XIDProc :: #type (a0: *Display, a1: XPointer, a2: XPointer) -> void #c_call;

XIMStyle :: u64;

XIMStyles :: struct {
    count_styles: u16;
    supported_styles: *XIMStyle;
}

XVaNestedList :: *void;

XIMCallback :: struct {
    client_data: XPointer;
    callback: XIMProc;
}

XICCallback :: struct {
    client_data: XPointer;
    callback: XICProc;
}

XIMFeedback :: u64;

_XIMText :: struct {
    length: u16;
    feedback: *XIMFeedback;
    encoding_is_wchar: s32;
    _string: union {
        multi_byte: *u8;
        wide_char: *wchar_t;
    };
}

XIMText :: _XIMText;

XIMPreeditState :: u64;

_XIMPreeditStateNotifyCallbackStruct :: struct {
    state: XIMPreeditState;
}

XIMPreeditStateNotifyCallbackStruct :: _XIMPreeditStateNotifyCallbackStruct;

XIMResetState :: u64;

XIMStringConversionFeedback :: u64;

_XIMStringConversionText :: struct {
    length: u16;
    feedback: *XIMStringConversionFeedback;
    encoding_is_wchar: s32;
    _string: union {
        mbs: *u8;
        wcs: *wchar_t;
    };
}

XIMStringConversionText :: _XIMStringConversionText;

XIMStringConversionPosition :: u16;

XIMStringConversionType :: u16;

XIMStringConversionOperation :: u16;

using XIMCaretDirection :: enum u32 {
    XIMForwardChar :: 0;
    XIMBackwardChar :: 1;
    XIMForwardWord :: 2;
    XIMBackwardWord :: 3;
    XIMCaretUp :: 4;
    XIMCaretDown :: 5;
    XIMNextLine :: 6;
    XIMPreviousLine :: 7;
    XIMLineStart :: 8;
    XIMLineEnd :: 9;
    XIMAbsolutePosition :: 10;
    XIMDontChange :: 11;
}

_XIMStringConversionCallbackStruct :: struct {
    position: XIMStringConversionPosition;
    direction: XIMCaretDirection;
    operation: XIMStringConversionOperation;
    factor: u16;
    text: *XIMStringConversionText;
}

XIMStringConversionCallbackStruct :: _XIMStringConversionCallbackStruct;

_XIMPreeditDrawCallbackStruct :: struct {
    caret: s32;
    chg_first: s32;
    chg_length: s32;
    text: *XIMText;
}

XIMPreeditDrawCallbackStruct :: _XIMPreeditDrawCallbackStruct;

using XIMCaretStyle :: enum u32 {
    XIMIsInvisible :: 0;
    XIMIsPrimary :: 1;
    XIMIsSecondary :: 2;
}

_XIMPreeditCaretCallbackStruct :: struct {
    position: s32;
    direction: XIMCaretDirection;
    style: XIMCaretStyle;
}

XIMPreeditCaretCallbackStruct :: _XIMPreeditCaretCallbackStruct;

using XIMStatusDataType :: enum u32 {
    XIMTextType :: 0;
    XIMBitmapType :: 1;
}

_XIMStatusDrawCallbackStruct :: struct {
    type: XIMStatusDataType;
    data: union {
        text: *XIMText;
        bitmap: Pixmap;
    };
}

XIMStatusDrawCallbackStruct :: _XIMStatusDrawCallbackStruct;

_XIMHotKeyTrigger :: struct {
    keysym: KeySym;
    modifier: s32;
    modifier_mask: s32;
}

XIMHotKeyTrigger :: _XIMHotKeyTrigger;

_XIMHotKeyTriggers :: struct {
    num_hot_key: s32;
    key: *XIMHotKeyTrigger;
}

XIMHotKeyTriggers :: _XIMHotKeyTriggers;

XIMHotKeyState :: u64;

XIMValuesList :: struct {
    count_values: u16;
    supported_values: **u8;
}

_Xdebug: s32;

XLoadQueryFont: #type (unk0: *Display, unk1: *u8) -> *XFontStruct #c_call;

XQueryFont: #type (unk0: *Display, unk1: XID) -> *XFontStruct #c_call;

XGetMotionEvents: #type (unk0: *Display, unk1: Window, unk2: Time, unk3: Time, unk4: *s32) -> *XTimeCoord #c_call;

XDeleteModifiermapEntry: #type (unk0: *XModifierKeymap, unk1: KeyCode, unk2: s32) -> *XModifierKeymap #c_call;

XGetModifierMapping: #type (unk0: *Display) -> *XModifierKeymap #c_call;

XInsertModifiermapEntry: #type (unk0: *XModifierKeymap, unk1: KeyCode, unk2: s32) -> *XModifierKeymap #c_call;

XNewModifiermap: #type (unk0: s32) -> *XModifierKeymap #c_call;

XCreateImage: #type (unk0: *Display, unk1: *Visual, unk2: u32, unk3: s32, unk4: s32, unk5: *u8, unk6: u32, unk7: u32, unk8: s32, unk9: s32) -> *XImage #c_call;

XDestroyImage: #type (img: *XImage) #c_call;

XInitImage: #type (unk0: *XImage) -> s32 #c_call;

XGetImage: #type (unk0: *Display, unk1: Drawable, unk2: s32, unk3: s32, unk4: u32, unk5: u32, unk6: u64, unk7: s32) -> *XImage #c_call;

XGetSubImage: #type (unk0: *Display, unk1: Drawable, unk2: s32, unk3: s32, unk4: u32, unk5: u32, unk6: u64, unk7: s32, unk8: *XImage, unk9: s32, unk10: s32) -> *XImage #c_call;

XOpenDisplay: #type (unk0: *u8) -> *Display #c_call;

XrmInitialize: #type () -> void #c_call;

XFetchBytes: #type (unk0: *Display, unk1: *s32) -> *u8 #c_call;

XFetchBuffer: #type (unk0: *Display, unk1: *s32, unk2: s32) -> *u8 #c_call;

XGetAtomName: #type (unk0: *Display, unk1: Atom) -> *u8 #c_call;

XGetAtomNames: #type (unk0: *Display, unk1: *Atom, unk2: s32, unk3: **u8) -> s32 #c_call;

XGetDefault: #type (unk0: *Display, unk1: *u8, unk2: *u8) -> *u8 #c_call;

XDisplayName: #type (unk0: *u8) -> *u8 #c_call;

XKeysymToString: #type (unk0: KeySym) -> *u8 #c_call;

XSynchronize: #type (unk0: *Display, unk1: *Display, unk2: s32) -> ((a0: *Display) -> s32 #c_call) #c_call;

XSetAfterFunction: #type (unk0: *Display, unk1: *Display, unk2: #type (a0: *Display) -> s32 #c_call) -> ((a0: *Display) -> s32 #c_call) #c_call;

XInternAtom: #type (unk0: *Display, unk1: *u8, unk2: s32) -> Atom #c_call;

XInternAtoms: #type (unk0: *Display, unk1: **u8, unk2: s32, unk3: s32, unk4: *Atom) -> s32 #c_call;

XCopyColormapAndFree: #type (unk0: *Display, unk1: Colormap) -> Colormap #c_call;

XCreateColormap: #type (unk0: *Display, unk1: Window, unk2: *Visual, unk3: s32) -> Colormap #c_call;

XCreatePixmapCursor: #type (unk0: *Display, unk1: Pixmap, unk2: Pixmap, unk3: *XColor, unk4: *XColor, unk5: u32, unk6: u32) -> Cursor #c_call;

XCreateGlyphCursor: #type (unk0: *Display, unk1: Font, unk2: Font, unk3: u32, unk4: u32, unk5: *XColor, unk6: *XColor) -> Cursor #c_call;

XCreateFontCursor: #type (unk0: *Display, unk1: u32) -> Cursor #c_call;

XLoadFont: #type (unk0: *Display, unk1: *u8) -> Font #c_call;

XCreateGC: #type (unk0: *Display, unk1: Drawable, unk2: u64, unk3: *XGCValues) -> GC #c_call;

XGContextFromGC: #type (unk0: GC) -> GContext #c_call;

XFlushGC: #type (unk0: *Display, unk1: GC) -> void #c_call;

XCreatePixmap: #type (unk0: *Display, unk1: Drawable, unk2: u32, unk3: u32, unk4: u32) -> Pixmap #c_call;

XCreateBitmapFromData: #type (unk0: *Display, unk1: Drawable, unk2: *u8, unk3: u32, unk4: u32) -> Pixmap #c_call;

XCreatePixmapFromBitmapData: #type (unk0: *Display, unk1: Drawable, unk2: *u8, unk3: u32, unk4: u32, unk5: u64, unk6: u64, unk7: u32) -> Pixmap #c_call;

XCreateSimpleWindow: #type (unk0: *Display, unk1: Window, unk2: s32, unk3: s32, unk4: u32, unk5: u32, unk6: u32, unk7: u64, unk8: u64) -> Window #c_call;

XGetSelectionOwner: #type (unk0: *Display, unk1: Atom) -> Window #c_call;

XCreateWindow: #type (unk0: *Display, unk1: Window, unk2: s32, unk3: s32, unk4: u32, unk5: u32, unk6: u32, unk7: s32, unk8: u32, unk9: *Visual, unk10: u64, unk11: *XSetWindowAttributes) -> Window #c_call;

XListInstalledColormaps: #type (unk0: *Display, unk1: Window, unk2: *s32) -> *Colormap #c_call;

XListFonts: #type (unk0: *Display, unk1: *u8, unk2: s32, unk3: *s32) -> **u8 #c_call;

XListFontsWithInfo: #type (unk0: *Display, unk1: *u8, unk2: s32, unk3: *s32, unk4: **XFontStruct) -> **u8 #c_call;

XGetFontPath: #type (unk0: *Display, unk1: *s32) -> **u8 #c_call;

XListExtensions: #type (unk0: *Display, unk1: *s32) -> **u8 #c_call;

XListProperties: #type (unk0: *Display, unk1: Window, unk2: *s32) -> *Atom #c_call;

XListHosts: #type (unk0: *Display, unk1: *s32, unk2: *s32) -> *XHostAddress #c_call;

XKeycodeToKeysym: #type (unk0: *Display, unk1: KeyCode, unk2: s32) -> KeySym #c_call;

XLookupKeysym: #type (unk0: *XKeyEvent, unk1: s32) -> KeySym #c_call;

XGetKeyboardMapping: #type (unk0: *Display, unk1: KeyCode, unk2: s32, unk3: *s32) -> *KeySym #c_call;

XStringToKeysym: #type (unk0: *u8) -> KeySym #c_call;

XMaxRequestSize: #type (unk0: *Display) -> s64 #c_call;

XExtendedMaxRequestSize: #type (unk0: *Display) -> s64 #c_call;

XResourceManagerString: #type (unk0: *Display) -> *u8 #c_call;

XScreenResourceString: #type (unk0: *Screen) -> *u8 #c_call;

XDisplayMotionBufferSize: #type (unk0: *Display) -> u64 #c_call;

XVisualIDFromVisual: #type (unk0: *Visual) -> VisualID #c_call;

XInitThreads: #type () -> s32 #c_call;

XLockDisplay: #type (unk0: *Display) -> void #c_call;

XUnlockDisplay: #type (unk0: *Display) -> void #c_call;

XInitExtension: #type (unk0: *Display, unk1: *u8) -> *XExtCodes #c_call;

XAddExtension: #type (unk0: *Display) -> *XExtCodes #c_call;

XFindOnExtensionList: #type (unk0: **XExtData, unk1: s32) -> *XExtData #c_call;

XEHeadOfExtensionList: #type (unk0: XEDataObject) -> **XExtData #c_call;

XRootWindow: #type (unk0: *Display, unk1: s32) -> Window #c_call;

XDefaultRootWindow: #type (unk0: *Display) -> Window #c_call;

XRootWindowOfScreen: #type (unk0: *Screen) -> Window #c_call;

XDefaultVisual: #type (unk0: *Display, unk1: s32) -> *Visual #c_call;

XDefaultVisualOfScreen: #type (unk0: *Screen) -> *Visual #c_call;

XDefaultGC: #type (unk0: *Display, unk1: s32) -> GC #c_call;

XDefaultGCOfScreen: #type (unk0: *Screen) -> GC #c_call;

XBlackPixel: #type (unk0: *Display, unk1: s32) -> u64 #c_call;

XWhitePixel: #type (unk0: *Display, unk1: s32) -> u64 #c_call;

XAllPlanes: #type () -> u64 #c_call;

XBlackPixelOfScreen: #type (unk0: *Screen) -> u64 #c_call;

XWhitePixelOfScreen: #type (unk0: *Screen) -> u64 #c_call;

XNextRequest: #type (unk0: *Display) -> u64 #c_call;

XLastKnownRequestProcessed: #type (unk0: *Display) -> u64 #c_call;

XServerVendor: #type (unk0: *Display) -> *u8 #c_call;

XDisplayString: #type (unk0: *Display) -> *u8 #c_call;

XDefaultColormap: #type (unk0: *Display, unk1: s32) -> Colormap #c_call;

XDefaultColormapOfScreen: #type (unk0: *Screen) -> Colormap #c_call;

XDisplayOfScreen: #type (unk0: *Screen) -> *Display #c_call;

XScreenOfDisplay: #type (unk0: *Display, unk1: s32) -> *Screen #c_call;

XDefaultScreenOfDisplay: #type (unk0: *Display) -> *Screen #c_call;

XEventMaskOfScreen: #type (unk0: *Screen) -> s64 #c_call;

XScreenNumberOfScreen: #type (unk0: *Screen) -> s32 #c_call;

XErrorHandler :: #type (a0: *Display, a1: *XErrorEvent) -> s32 #c_call;

XSetErrorHandler: #type (unk0: XErrorHandler) -> XErrorHandler #c_call;

XIOErrorHandler :: #type (a0: *Display) -> s32 #c_call;

XSetIOErrorHandler: #type (unk0: XIOErrorHandler) -> XIOErrorHandler #c_call;

XListPixmapFormats: #type (unk0: *Display, unk1: *s32) -> *XPixmapFormatValues #c_call;

XListDepths: #type (unk0: *Display, unk1: s32, unk2: *s32) -> *s32 #c_call;

XReconfigureWMWindow: #type (unk0: *Display, unk1: Window, unk2: s32, unk3: u32, unk4: *XWindowChanges) -> s32 #c_call;

XGetWMProtocols: #type (unk0: *Display, unk1: Window, unk2: **Atom, unk3: *s32) -> s32 #c_call;

XSetWMProtocols: #type (unk0: *Display, unk1: Window, unk2: *Atom, unk3: s32) -> s32 #c_call;

XIconifyWindow: #type (unk0: *Display, unk1: Window, unk2: s32) -> s32 #c_call;

XWithdrawWindow: #type (unk0: *Display, unk1: Window, unk2: s32) -> s32 #c_call;

XGetCommand: #type (unk0: *Display, unk1: Window, unk2: ***u8, unk3: *s32) -> s32 #c_call;

XGetWMColormapWindows: #type (unk0: *Display, unk1: Window, unk2: **Window, unk3: *s32) -> s32 #c_call;

XSetWMColormapWindows: #type (unk0: *Display, unk1: Window, unk2: *Window, unk3: s32) -> s32 #c_call;

XFreeStringList: #type (unk0: **u8) -> void #c_call;

XSetTransientForHint: #type (unk0: *Display, unk1: Window, unk2: Window) -> s32 #c_call;

XActivateScreenSaver: #type (unk0: *Display) -> s32 #c_call;

XAddHost: #type (unk0: *Display, unk1: *XHostAddress) -> s32 #c_call;

XAddHosts: #type (unk0: *Display, unk1: *XHostAddress, unk2: s32) -> s32 #c_call;

XAddToExtensionList: #type (unk0: **_XExtData, unk1: *XExtData) -> s32 #c_call;

XAddToSaveSet: #type (unk0: *Display, unk1: Window) -> s32 #c_call;

XAllocColor: #type (unk0: *Display, unk1: Colormap, unk2: *XColor) -> s32 #c_call;

XAllocColorCells: #type (unk0: *Display, unk1: Colormap, unk2: s32, unk3: *u64, unk4: u32, unk5: *u64, unk6: u32) -> s32 #c_call;

XAllocColorPlanes: #type (unk0: *Display, unk1: Colormap, unk2: s32, unk3: *u64, unk4: s32, unk5: s32, unk6: s32, unk7: s32, unk8: *u64, unk9: *u64, unk10: *u64) -> s32 #c_call;

XAllocNamedColor: #type (unk0: *Display, unk1: Colormap, unk2: *u8, unk3: *XColor, unk4: *XColor) -> s32 #c_call;

XAllowEvents: #type (unk0: *Display, unk1: s32, unk2: Time) -> s32 #c_call;

XAutoRepeatOff: #type (unk0: *Display) -> s32 #c_call;

XAutoRepeatOn: #type (unk0: *Display) -> s32 #c_call;

XBell: #type (unk0: *Display, unk1: s32) -> s32 #c_call;

XBitmapBitOrder: #type (unk0: *Display) -> s32 #c_call;

XBitmapPad: #type (unk0: *Display) -> s32 #c_call;

XBitmapUnit: #type (unk0: *Display) -> s32 #c_call;

XCellsOfScreen: #type (unk0: *Screen) -> s32 #c_call;

XChangeActivePointerGrab: #type (unk0: *Display, unk1: u32, unk2: Cursor, unk3: Time) -> s32 #c_call;

XChangeGC: #type (unk0: *Display, unk1: GC, unk2: u64, unk3: *XGCValues) -> s32 #c_call;

XChangeKeyboardControl: #type (unk0: *Display, unk1: u64, unk2: *XKeyboardControl) -> s32 #c_call;

XChangeKeyboardMapping: #type (unk0: *Display, unk1: s32, unk2: s32, unk3: *KeySym, unk4: s32) -> s32 #c_call;

XChangePointerControl: #type (unk0: *Display, unk1: s32, unk2: s32, unk3: s32, unk4: s32, unk5: s32) -> s32 #c_call;

XChangeProperty: #type (unk0: *Display, unk1: Window, unk2: Atom, unk3: Atom, unk4: s32, unk5: s32, unk6: *u8, unk7: s32) -> s32 #c_call;

XChangeSaveSet: #type (unk0: *Display, unk1: Window, unk2: s32) -> s32 #c_call;

XChangeWindowAttributes: #type (unk0: *Display, unk1: Window, unk2: u64, unk3: *XSetWindowAttributes) -> s32 #c_call;

XCheckIfEvent: #type (unk0: *Display, unk1: *XEvent, unk2: #type (a0: *Display, a1: *XEvent, a2: XPointer) -> s32 #c_call, unk3: XPointer) -> s32 #c_call;

XCheckMaskEvent: #type (unk0: *Display, unk1: s64, unk2: *XEvent) -> s32 #c_call;

XCheckTypedEvent: #type (unk0: *Display, unk1: s32, unk2: *XEvent) -> s32 #c_call;

XCheckTypedWindowEvent: #type (unk0: *Display, unk1: Window, unk2: s32, unk3: *XEvent) -> s32 #c_call;

XCheckWindowEvent: #type (unk0: *Display, unk1: Window, unk2: s64, unk3: *XEvent) -> s32 #c_call;

XCirculateSubwindows: #type (unk0: *Display, unk1: Window, unk2: s32) -> s32 #c_call;

XCirculateSubwindowsDown: #type (unk0: *Display, unk1: Window) -> s32 #c_call;

XCirculateSubwindowsUp: #type (unk0: *Display, unk1: Window) -> s32 #c_call;

XClearArea: #type (unk0: *Display, unk1: Window, unk2: s32, unk3: s32, unk4: u32, unk5: u32, unk6: s32) -> s32 #c_call;

XClearWindow: #type (unk0: *Display, unk1: Window) -> s32 #c_call;

XCloseDisplay: #type (unk0: *Display) -> s32 #c_call;

XConfigureWindow: #type (unk0: *Display, unk1: Window, unk2: u32, unk3: *XWindowChanges) -> s32 #c_call;

XConnectionNumber: #type (unk0: *Display) -> s32 #c_call;

XConvertSelection: #type (unk0: *Display, unk1: Atom, unk2: Atom, unk3: Atom, unk4: Window, unk5: Time) -> s32 #c_call;

XCopyArea: #type (unk0: *Display, unk1: Drawable, unk2: Drawable, unk3: GC, unk4: s32, unk5: s32, unk6: u32, unk7: u32, unk8: s32, unk9: s32) -> s32 #c_call;

XCopyGC: #type (unk0: *Display, unk1: GC, unk2: u64, unk3: GC) -> s32 #c_call;

XCopyPlane: #type (unk0: *Display, unk1: Drawable, unk2: Drawable, unk3: GC, unk4: s32, unk5: s32, unk6: u32, unk7: u32, unk8: s32, unk9: s32, unk10: u64) -> s32 #c_call;

XDefaultDepth: #type (unk0: *Display, unk1: s32) -> s32 #c_call;

XDefaultDepthOfScreen: #type (unk0: *Screen) -> s32 #c_call;

XDefaultScreen: #type (unk0: *Display) -> s32 #c_call;

XDefineCursor: #type (unk0: *Display, unk1: Window, unk2: Cursor) -> s32 #c_call;

XDeleteProperty: #type (unk0: *Display, unk1: Window, unk2: Atom) -> s32 #c_call;

XDestroyWindow: #type (unk0: *Display, unk1: Window) -> s32 #c_call;

XDestroySubwindows: #type (unk0: *Display, unk1: Window) -> s32 #c_call;

XDoesBackingStore: #type (unk0: *Screen) -> s32 #c_call;

XDoesSaveUnders: #type (unk0: *Screen) -> s32 #c_call;

XDisableAccessControl: #type (unk0: *Display) -> s32 #c_call;

XDisplayCells: #type (unk0: *Display, unk1: s32) -> s32 #c_call;

XDisplayHeight: #type (unk0: *Display, unk1: s32) -> s32 #c_call;

XDisplayHeightMM: #type (unk0: *Display, unk1: s32) -> s32 #c_call;

XDisplayKeycodes: #type (unk0: *Display, unk1: *s32, unk2: *s32) -> s32 #c_call;

XDisplayPlanes: #type (unk0: *Display, unk1: s32) -> s32 #c_call;

XDisplayWidth: #type (unk0: *Display, unk1: s32) -> s32 #c_call;

XDisplayWidthMM: #type (unk0: *Display, unk1: s32) -> s32 #c_call;

XDrawArc: #type (unk0: *Display, unk1: Drawable, unk2: GC, unk3: s32, unk4: s32, unk5: u32, unk6: u32, unk7: s32, unk8: s32) -> s32 #c_call;

XDrawArcs: #type (unk0: *Display, unk1: Drawable, unk2: GC, unk3: *XArc, unk4: s32) -> s32 #c_call;

XDrawImageString: #type (unk0: *Display, unk1: Drawable, unk2: GC, unk3: s32, unk4: s32, unk5: *u8, unk6: s32) -> s32 #c_call;

XDrawImageString16: #type (unk0: *Display, unk1: Drawable, unk2: GC, unk3: s32, unk4: s32, unk5: *XChar2b, unk6: s32) -> s32 #c_call;

XDrawLine: #type (unk0: *Display, unk1: Drawable, unk2: GC, unk3: s32, unk4: s32, unk5: s32, unk6: s32) -> s32 #c_call;

XDrawLines: #type (unk0: *Display, unk1: Drawable, unk2: GC, unk3: *XPoint, unk4: s32, unk5: s32) -> s32 #c_call;

XDrawPoint: #type (unk0: *Display, unk1: Drawable, unk2: GC, unk3: s32, unk4: s32) -> s32 #c_call;

XDrawPoints: #type (unk0: *Display, unk1: Drawable, unk2: GC, unk3: *XPoint, unk4: s32, unk5: s32) -> s32 #c_call;

XDrawRectangle: #type (unk0: *Display, unk1: Drawable, unk2: GC, unk3: s32, unk4: s32, unk5: u32, unk6: u32) -> s32 #c_call;

XDrawRectangles: #type (unk0: *Display, unk1: Drawable, unk2: GC, unk3: *XRectangle, unk4: s32) -> s32 #c_call;

XDrawSegments: #type (unk0: *Display, unk1: Drawable, unk2: GC, unk3: *XSegment, unk4: s32) -> s32 #c_call;

XDrawString: #type (unk0: *Display, unk1: Drawable, unk2: GC, unk3: s32, unk4: s32, unk5: *u8, unk6: s32) -> s32 #c_call;

XDrawString16: #type (unk0: *Display, unk1: Drawable, unk2: GC, unk3: s32, unk4: s32, unk5: *XChar2b, unk6: s32) -> s32 #c_call;

XDrawText: #type (unk0: *Display, unk1: Drawable, unk2: GC, unk3: s32, unk4: s32, unk5: *XTextItem, unk6: s32) -> s32 #c_call;

XDrawText16: #type (unk0: *Display, unk1: Drawable, unk2: GC, unk3: s32, unk4: s32, unk5: *XTextItem16, unk6: s32) -> s32 #c_call;

XEnableAccessControl: #type (unk0: *Display) -> s32 #c_call;

XEventsQueued: #type (unk0: *Display, unk1: s32) -> s32 #c_call;

XFetchName: #type (unk0: *Display, unk1: Window, unk2: **u8) -> s32 #c_call;

XFillArc: #type (unk0: *Display, unk1: Drawable, unk2: GC, unk3: s32, unk4: s32, unk5: u32, unk6: u32, unk7: s32, unk8: s32) -> s32 #c_call;

XFillArcs: #type (unk0: *Display, unk1: Drawable, unk2: GC, unk3: *XArc, unk4: s32) -> s32 #c_call;

XFillPolygon: #type (unk0: *Display, unk1: Drawable, unk2: GC, unk3: *XPoint, unk4: s32, unk5: s32, unk6: s32) -> s32 #c_call;

XFillRectangle: #type (unk0: *Display, unk1: Drawable, unk2: GC, unk3: s32, unk4: s32, unk5: u32, unk6: u32) -> s32 #c_call;

XFillRectangles: #type (unk0: *Display, unk1: Drawable, unk2: GC, unk3: *XRectangle, unk4: s32) -> s32 #c_call;

XFlush: #type (unk0: *Display) -> s32 #c_call;

XForceScreenSaver: #type (unk0: *Display, unk1: s32) -> s32 #c_call;

XFree: #type (unk0: *void) -> s32 #c_call;

XFreeColormap: #type (unk0: *Display, unk1: Colormap) -> s32 #c_call;

XFreeColors: #type (unk0: *Display, unk1: Colormap, unk2: *u64, unk3: s32, unk4: u64) -> s32 #c_call;

XFreeCursor: #type (unk0: *Display, unk1: Cursor) -> s32 #c_call;

XFreeExtensionList: #type (unk0: **u8) -> s32 #c_call;

XFreeFont: #type (unk0: *Display, unk1: *XFontStruct) -> s32 #c_call;

XFreeFontInfo: #type (unk0: **u8, unk1: *XFontStruct, unk2: s32) -> s32 #c_call;

XFreeFontNames: #type (unk0: **u8) -> s32 #c_call;

XFreeFontPath: #type (unk0: **u8) -> s32 #c_call;

XFreeGC: #type (unk0: *Display, gc: GC) -> s32 #c_call;

XFreeModifiermap: #type (unk0: *XModifierKeymap) -> s32 #c_call;

XFreePixmap: #type (unk0: *Display, unk1: Pixmap) -> s32 #c_call;

XGeometry: #type (unk0: *Display, unk1: s32, unk2: *u8, unk3: *u8, unk4: u32, unk5: u32, unk6: u32, unk7: s32, unk8: s32, unk9: *s32, unk10: *s32, unk11: *s32, unk12: *s32) -> s32 #c_call;

XGetErrorDatabaseText: #type (unk0: *Display, unk1: *u8, unk2: *u8, unk3: *u8, unk4: *u8, unk5: s32) -> s32 #c_call;

XGetErrorText: #type (unk0: *Display, unk1: s32, unk2: *u8, unk3: s32) -> s32 #c_call;

XGetFontProperty: #type (unk0: *XFontStruct, unk1: Atom, unk2: *u64) -> s32 #c_call;

XGetGCValues: #type (unk0: *Display, unk1: GC, unk2: u64, unk3: *XGCValues) -> s32 #c_call;

XGetGeometry: #type (unk0: *Display, unk1: Drawable, unk2: *Window, unk3: *s32, unk4: *s32, unk5: *u32, unk6: *u32, unk7: *u32, unk8: *u32) -> s32 #c_call;

XGetIconName: #type (unk0: *Display, unk1: Window, unk2: **u8) -> s32 #c_call;

XGetInputFocus: #type (unk0: *Display, unk1: *Window, unk2: *s32) -> s32 #c_call;

XGetKeyboardControl: #type (unk0: *Display, unk1: *XKeyboardState) -> s32 #c_call;

XGetPointerControl: #type (unk0: *Display, unk1: *s32, unk2: *s32, unk3: *s32) -> s32 #c_call;

XGetPointerMapping: #type (unk0: *Display, unk1: *u8, unk2: s32) -> s32 #c_call;

XGetScreenSaver: #type (unk0: *Display, unk1: *s32, unk2: *s32, unk3: *s32, unk4: *s32) -> s32 #c_call;

XGetTransientForHint: #type (unk0: *Display, unk1: Window, unk2: *Window) -> s32 #c_call;

XGetWindowProperty: #type (unk0: *Display, unk1: Window, unk2: Atom, unk3: s64, unk4: s64, unk5: s32, unk6: Atom, unk7: *Atom, unk8: *s32, unk9: *u64, unk10: *u64, unk11: **u8) -> s32 #c_call;

XGetWindowAttributes: #type (unk0: *Display, unk1: Window, unk2: *XWindowAttributes) -> s32 #c_call;

XGrabButton: #type (unk0: *Display, unk1: u32, unk2: u32, unk3: Window, unk4: s32, unk5: u32, unk6: s32, unk7: s32, unk8: Window, unk9: Cursor) -> s32 #c_call;

XGrabKey: #type (unk0: *Display, unk1: s32, unk2: u32, unk3: Window, unk4: s32, unk5: s32, unk6: s32) -> s32 #c_call;

XGrabKeyboard: #type (unk0: *Display, unk1: Window, unk2: s32, unk3: s32, unk4: s32, unk5: Time) -> s32 #c_call;

XGrabPointer: #type (unk0: *Display, unk1: Window, unk2: s32, unk3: u32, unk4: s32, unk5: s32, unk6: Window, unk7: Cursor, unk8: Time) -> s32 #c_call;

XGrabServer: #type (unk0: *Display) -> s32 #c_call;

XHeightMMOfScreen: #type (unk0: *Screen) -> s32 #c_call;

XHeightOfScreen: #type (unk0: *Screen) -> s32 #c_call;

XIfEvent: #type (unk0: *Display, unk1: *XEvent, unk2: #type (a0: *Display, a1: *XEvent, a2: XPointer) -> s32 #c_call, unk3: XPointer) -> s32 #c_call;

XImageByteOrder: #type (unk0: *Display) -> s32 #c_call;

XInstallColormap: #type (unk0: *Display, unk1: Colormap) -> s32 #c_call;

XKeysymToKeycode: #type (unk0: *Display, unk1: KeySym) -> KeyCode #c_call;

XKillClient: #type (unk0: *Display, unk1: XID) -> s32 #c_call;

XLookupColor: #type (unk0: *Display, unk1: Colormap, unk2: *u8, unk3: *XColor, unk4: *XColor) -> s32 #c_call;

XLowerWindow: #type (unk0: *Display, unk1: Window) -> s32 #c_call;

XMapRaised: #type (unk0: *Display, unk1: Window) -> s32 #c_call;

XMapSubwindows: #type (unk0: *Display, unk1: Window) -> s32 #c_call;

XMapWindow: #type (unk0: *Display, unk1: Window) -> s32 #c_call;

XMaskEvent: #type (unk0: *Display, unk1: s64, unk2: *XEvent) -> s32 #c_call;

XMaxCmapsOfScreen: #type (unk0: *Screen) -> s32 #c_call;

XMinCmapsOfScreen: #type (unk0: *Screen) -> s32 #c_call;

XMoveResizeWindow: #type (unk0: *Display, unk1: Window, unk2: s32, unk3: s32, unk4: u32, unk5: u32) -> s32 #c_call;

XMoveWindow: #type (unk0: *Display, unk1: Window, unk2: s32, unk3: s32) -> s32 #c_call;

XNextEvent: #type (unk0: *Display, unk1: *XEvent) -> s32 #c_call;

XNoOp: #type (unk0: *Display) -> s32 #c_call;

XParseColor: #type (unk0: *Display, unk1: Colormap, unk2: *u8, unk3: *XColor) -> s32 #c_call;

XParseGeometry: #type (unk0: *u8, unk1: *s32, unk2: *s32, unk3: *u32, unk4: *u32) -> s32 #c_call;

XPeekEvent: #type (unk0: *Display, unk1: *XEvent) -> s32 #c_call;

XPeekIfEvent: #type (unk0: *Display, unk1: *XEvent, unk2: #type (a0: *Display, a1: *XEvent, a2: XPointer) -> s32 #c_call, unk3: XPointer) -> s32 #c_call;

XPending: #type (unk0: *Display) -> s32 #c_call;

XPlanesOfScreen: #type (unk0: *Screen) -> s32 #c_call;

XProtocolRevision: #type (unk0: *Display) -> s32 #c_call;

XProtocolVersion: #type (unk0: *Display) -> s32 #c_call;

XPutBackEvent: #type (unk0: *Display, unk1: *XEvent) -> s32 #c_call;

XPutImage: #type (unk0: *Display, unk1: Drawable, unk2: GC, unk3: *XImage, unk4: s32, unk5: s32, unk6: s32, unk7: s32, unk8: u32, unk9: u32) -> s32 #c_call;

XQLength: #type (unk0: *Display) -> s32 #c_call;

XQueryBestCursor: #type (unk0: *Display, unk1: Drawable, unk2: u32, unk3: u32, unk4: *u32, unk5: *u32) -> s32 #c_call;

XQueryBestSize: #type (unk0: *Display, unk1: s32, unk2: Drawable, unk3: u32, unk4: u32, unk5: *u32, unk6: *u32) -> s32 #c_call;

XQueryBestStipple: #type (unk0: *Display, unk1: Drawable, unk2: u32, unk3: u32, unk4: *u32, unk5: *u32) -> s32 #c_call;

XQueryBestTile: #type (unk0: *Display, unk1: Drawable, unk2: u32, unk3: u32, unk4: *u32, unk5: *u32) -> s32 #c_call;

XQueryColor: #type (unk0: *Display, unk1: Colormap, unk2: *XColor) -> s32 #c_call;

XQueryColors: #type (unk0: *Display, unk1: Colormap, unk2: *XColor, unk3: s32) -> s32 #c_call;

XQueryExtension: #type (unk0: *Display, unk1: *u8, unk2: *s32, unk3: *s32, unk4: *s32) -> s32 #c_call;

XQueryKeymap: #type (unk0: *Display, unk1: *[32] u8) -> s32 #c_call;

XQueryPointer: #type (unk0: *Display, unk1: Window, unk2: *Window, unk3: *Window, unk4: *s32, unk5: *s32, unk6: *s32, unk7: *s32, unk8: *u32) -> s32 #c_call;

XQueryTextExtents: #type (unk0: *Display, unk1: XID, unk2: *u8, unk3: s32, unk4: *s32, unk5: *s32, unk6: *s32, unk7: *XCharStruct) -> s32 #c_call;

XQueryTextExtents16: #type (unk0: *Display, unk1: XID, unk2: *XChar2b, unk3: s32, unk4: *s32, unk5: *s32, unk6: *s32, unk7: *XCharStruct) -> s32 #c_call;

XQueryTree: #type (unk0: *Display, unk1: Window, unk2: *Window, unk3: *Window, unk4: **Window, unk5: *u32) -> s32 #c_call;

XRaiseWindow: #type (unk0: *Display, unk1: Window) -> s32 #c_call;

XReadBitmapFile: #type (unk0: *Display, unk1: Drawable, unk2: *u8, unk3: *u32, unk4: *u32, unk5: *Pixmap, unk6: *s32, unk7: *s32) -> s32 #c_call;

XReadBitmapFileData: #type (unk0: *u8, unk1: *u32, unk2: *u32, unk3: **u8, unk4: *s32, unk5: *s32) -> s32 #c_call;

XRebindKeysym: #type (unk0: *Display, unk1: KeySym, unk2: *KeySym, unk3: s32, unk4: *u8, unk5: s32) -> s32 #c_call;

XRecolorCursor: #type (unk0: *Display, unk1: Cursor, unk2: *XColor, unk3: *XColor) -> s32 #c_call;

XRefreshKeyboardMapping: #type (unk0: *XMappingEvent) -> s32 #c_call;

XRemoveFromSaveSet: #type (unk0: *Display, unk1: Window) -> s32 #c_call;

XRemoveHost: #type (unk0: *Display, unk1: *XHostAddress) -> s32 #c_call;

XRemoveHosts: #type (unk0: *Display, unk1: *XHostAddress, unk2: s32) -> s32 #c_call;

XReparentWindow: #type (unk0: *Display, unk1: Window, unk2: Window, unk3: s32, unk4: s32) -> s32 #c_call;

XResetScreenSaver: #type (unk0: *Display) -> s32 #c_call;

XResizeWindow: #type (unk0: *Display, unk1: Window, unk2: u32, unk3: u32) -> s32 #c_call;

XRestackWindows: #type (unk0: *Display, unk1: *Window, unk2: s32) -> s32 #c_call;

XRotateBuffers: #type (unk0: *Display, unk1: s32) -> s32 #c_call;

XRotateWindowProperties: #type (unk0: *Display, unk1: Window, unk2: *Atom, unk3: s32, unk4: s32) -> s32 #c_call;

XScreenCount: #type (unk0: *Display) -> s32 #c_call;

XSelectInput: #type (unk0: *Display, unk1: Window, unk2: s64) -> s32 #c_call;

XSendEvent: #type (unk0: *Display, unk1: Window, unk2: s32, unk3: s64, unk4: *XEvent) -> s32 #c_call;

XSetAccessControl: #type (unk0: *Display, unk1: s32) -> s32 #c_call;

XSetArcMode: #type (unk0: *Display, unk1: GC, unk2: s32) -> s32 #c_call;

XSetBackground: #type (unk0: *Display, unk1: GC, unk2: u64) -> s32 #c_call;

XSetClipMask: #type (unk0: *Display, unk1: GC, unk2: Pixmap) -> s32 #c_call;

XSetClipOrigin: #type (unk0: *Display, unk1: GC, unk2: s32, unk3: s32) -> s32 #c_call;

XSetClipRectangles: #type (unk0: *Display, unk1: GC, unk2: s32, unk3: s32, unk4: *XRectangle, unk5: s32, unk6: s32) -> s32 #c_call;

XSetCloseDownMode: #type (unk0: *Display, unk1: s32) -> s32 #c_call;

XSetCommand: #type (unk0: *Display, unk1: Window, unk2: **u8, unk3: s32) -> s32 #c_call;

XSetDashes: #type (unk0: *Display, unk1: GC, unk2: s32, unk3: *u8, unk4: s32) -> s32 #c_call;

XSetFillRule: #type (unk0: *Display, unk1: GC, unk2: s32) -> s32 #c_call;

XSetFillStyle: #type (unk0: *Display, unk1: GC, unk2: s32) -> s32 #c_call;

XSetFont: #type (unk0: *Display, unk1: GC, unk2: Font) -> s32 #c_call;

XSetFontPath: #type (unk0: *Display, unk1: **u8, unk2: s32) -> s32 #c_call;

XSetForeground: #type (unk0: *Display, unk1: GC, unk2: u64) -> s32 #c_call;

XSetFunction: #type (unk0: *Display, unk1: GC, unk2: s32) -> s32 #c_call;

XSetGraphicsExposures: #type (unk0: *Display, unk1: GC, unk2: s32) -> s32 #c_call;

XSetIconName: #type (unk0: *Display, unk1: Window, unk2: *u8) -> s32 #c_call;

XSetInputFocus: #type (unk0: *Display, unk1: Window, unk2: s32, unk3: Time) -> s32 #c_call;

XSetLineAttributes: #type (unk0: *Display, unk1: GC, unk2: u32, unk3: s32, unk4: s32, unk5: s32) -> s32 #c_call;

XSetModifierMapping: #type (unk0: *Display, unk1: *XModifierKeymap) -> s32 #c_call;

XSetPlaneMask: #type (unk0: *Display, unk1: GC, unk2: u64) -> s32 #c_call;

XSetPointerMapping: #type (unk0: *Display, unk1: *u8, unk2: s32) -> s32 #c_call;

XSetScreenSaver: #type (unk0: *Display, unk1: s32, unk2: s32, unk3: s32, unk4: s32) -> s32 #c_call;

XSetSelectionOwner: #type (unk0: *Display, unk1: Atom, unk2: Window, unk3: Time) -> s32 #c_call;

XSetState: #type (unk0: *Display, unk1: GC, unk2: u64, unk3: u64, unk4: s32, unk5: u64) -> s32 #c_call;

XSetStipple: #type (unk0: *Display, unk1: GC, unk2: Pixmap) -> s32 #c_call;

XSetSubwindowMode: #type (unk0: *Display, unk1: GC, unk2: s32) -> s32 #c_call;

XSetTSOrigin: #type (unk0: *Display, unk1: GC, unk2: s32, unk3: s32) -> s32 #c_call;

XSetTile: #type (unk0: *Display, unk1: GC, unk2: Pixmap) -> s32 #c_call;

XSetWindowBackground: #type (unk0: *Display, unk1: Window, unk2: u64) -> s32 #c_call;

XSetWindowBackgroundPixmap: #type (unk0: *Display, unk1: Window, unk2: Pixmap) -> s32 #c_call;

XSetWindowBorder: #type (unk0: *Display, unk1: Window, unk2: u64) -> s32 #c_call;

XSetWindowBorderPixmap: #type (unk0: *Display, unk1: Window, unk2: Pixmap) -> s32 #c_call;

XSetWindowBorderWidth: #type (unk0: *Display, unk1: Window, unk2: u32) -> s32 #c_call;

XSetWindowColormap: #type (unk0: *Display, unk1: Window, unk2: Colormap) -> s32 #c_call;

XStoreBuffer: #type (unk0: *Display, unk1: *u8, unk2: s32, unk3: s32) -> s32 #c_call;

XStoreBytes: #type (unk0: *Display, unk1: *u8, unk2: s32) -> s32 #c_call;

XStoreColor: #type (unk0: *Display, unk1: Colormap, unk2: *XColor) -> s32 #c_call;

XStoreColors: #type (unk0: *Display, unk1: Colormap, unk2: *XColor, unk3: s32) -> s32 #c_call;

XStoreName: #type (unk0: *Display, unk1: Window, unk2: *u8) -> s32 #c_call;

XStoreNamedColor: #type (unk0: *Display, unk1: Colormap, unk2: *u8, unk3: u64, unk4: s32) -> s32 #c_call;

XSync: #type (unk0: *Display, unk1: s32) -> s32 #c_call;

XTextExtents: #type (unk0: *XFontStruct, unk1: *u8, unk2: s32, unk3: *s32, unk4: *s32, unk5: *s32, unk6: *XCharStruct) -> s32 #c_call;

XTextExtents16: #type (unk0: *XFontStruct, unk1: *XChar2b, unk2: s32, unk3: *s32, unk4: *s32, unk5: *s32, unk6: *XCharStruct) -> s32 #c_call;

XTextWidth: #type (unk0: *XFontStruct, unk1: *u8, unk2: s32) -> s32 #c_call;

XTextWidth16: #type (unk0: *XFontStruct, unk1: *XChar2b, unk2: s32) -> s32 #c_call;

XTranslateCoordinates: #type (unk0: *Display, unk1: Window, unk2: Window, unk3: s32, unk4: s32, unk5: *s32, unk6: *s32, unk7: *Window) -> s32 #c_call;

XUndefineCursor: #type (unk0: *Display, unk1: Window) -> s32 #c_call;

XUngrabButton: #type (unk0: *Display, unk1: u32, unk2: u32, unk3: Window) -> s32 #c_call;

XUngrabKey: #type (unk0: *Display, unk1: s32, unk2: u32, unk3: Window) -> s32 #c_call;

XUngrabKeyboard: #type (unk0: *Display, unk1: Time) -> s32 #c_call;

XUngrabPointer: #type (unk0: *Display, unk1: Time) -> s32 #c_call;

XUngrabServer: #type (unk0: *Display) -> s32 #c_call;

XUninstallColormap: #type (unk0: *Display, unk1: Colormap) -> s32 #c_call;

XUnloadFont: #type (unk0: *Display, unk1: Font) -> s32 #c_call;

XUnmapSubwindows: #type (unk0: *Display, unk1: Window) -> s32 #c_call;

XUnmapWindow: #type (unk0: *Display, unk1: Window) -> s32 #c_call;

XVendorRelease: #type (unk0: *Display) -> s32 #c_call;

XWarpPointer: #type (unk0: *Display, unk1: Window, unk2: Window, unk3: s32, unk4: s32, unk5: u32, unk6: u32, unk7: s32, unk8: s32) -> s32 #c_call;

XWidthMMOfScreen: #type (unk0: *Screen) -> s32 #c_call;

XWidthOfScreen: #type (unk0: *Screen) -> s32 #c_call;

XWindowEvent: #type (unk0: *Display, unk1: Window, unk2: s64, unk3: *XEvent) -> s32 #c_call;

XWriteBitmapFile: #type (unk0: *Display, unk1: *u8, unk2: Pixmap, unk3: u32, unk4: u32, unk5: s32, unk6: s32) -> s32 #c_call;

XSupportsLocale: #type () -> s32 #c_call;

XSetLocaleModifiers: #type (unk0: *u8) -> *u8 #c_call;

XOpenOM: #type (unk0: *Display, unk1: *_XrmHashBucketRec, unk2: *u8, unk3: *u8) -> XOM #c_call;

XCloseOM: #type (unk0: XOM) -> s32 #c_call;

XSetOMValues: #type (unk0: XOM, __args: ..Any) -> *u8 #c_call;

XGetOMValues: #type (unk0: XOM, __args: ..Any) -> *u8 #c_call;

XDisplayOfOM: #type (unk0: XOM) -> *Display #c_call;

XLocaleOfOM: #type (unk0: XOM) -> *u8 #c_call;

XCreateOC: #type (unk0: XOM, __args: ..Any) -> XOC #c_call;

XDestroyOC: #type (unk0: XOC) -> void #c_call;

XOMOfOC: #type (unk0: XOC) -> XOM #c_call;

XSetOCValues: #type (unk0: XOC, __args: ..Any) -> *u8 #c_call;

XGetOCValues: #type (unk0: XOC, __args: ..Any) -> *u8 #c_call;

XCreateFontSet: #type (unk0: *Display, unk1: *u8, unk2: ***u8, unk3: *s32, unk4: **u8) -> XFontSet #c_call;

XFreeFontSet: #type (unk0: *Display, unk1: XFontSet) -> void #c_call;

XFontsOfFontSet: #type (unk0: XFontSet, unk1: ***XFontStruct, unk2: ***u8) -> s32 #c_call;

XBaseFontNameListOfFontSet: #type (unk0: XFontSet) -> *u8 #c_call;

XLocaleOfFontSet: #type (unk0: XFontSet) -> *u8 #c_call;

XContextDependentDrawing: #type (unk0: XFontSet) -> s32 #c_call;

XDirectionalDependentDrawing: #type (unk0: XFontSet) -> s32 #c_call;

XContextualDrawing: #type (unk0: XFontSet) -> s32 #c_call;

XExtentsOfFontSet: #type (unk0: XFontSet) -> *XFontSetExtents #c_call;

XmbTextEscapement: #type (unk0: XFontSet, unk1: *u8, unk2: s32) -> s32 #c_call;

XwcTextEscapement: #type (unk0: XFontSet, unk1: *wchar_t, unk2: s32) -> s32 #c_call;

Xutf8TextEscapement: #type (unk0: XFontSet, unk1: *u8, unk2: s32) -> s32 #c_call;

XmbTextExtents: #type (unk0: XFontSet, unk1: *u8, unk2: s32, unk3: *XRectangle, unk4: *XRectangle) -> s32 #c_call;

XwcTextExtents: #type (unk0: XFontSet, unk1: *wchar_t, unk2: s32, unk3: *XRectangle, unk4: *XRectangle) -> s32 #c_call;

Xutf8TextExtents: #type (unk0: XFontSet, unk1: *u8, unk2: s32, unk3: *XRectangle, unk4: *XRectangle) -> s32 #c_call;

XmbTextPerCharExtents: #type (unk0: XFontSet, unk1: *u8, unk2: s32, unk3: *XRectangle, unk4: *XRectangle, unk5: s32, unk6: *s32, unk7: *XRectangle, unk8: *XRectangle) -> s32 #c_call;

XwcTextPerCharExtents: #type (unk0: XFontSet, unk1: *wchar_t, unk2: s32, unk3: *XRectangle, unk4: *XRectangle, unk5: s32, unk6: *s32, unk7: *XRectangle, unk8: *XRectangle) -> s32 #c_call;

Xutf8TextPerCharExtents: #type (unk0: XFontSet, unk1: *u8, unk2: s32, unk3: *XRectangle, unk4: *XRectangle, unk5: s32, unk6: *s32, unk7: *XRectangle, unk8: *XRectangle) -> s32 #c_call;

XmbDrawText: #type (unk0: *Display, unk1: Drawable, unk2: GC, unk3: s32, unk4: s32, unk5: *XmbTextItem, unk6: s32) -> void #c_call;

XwcDrawText: #type (unk0: *Display, unk1: Drawable, unk2: GC, unk3: s32, unk4: s32, unk5: *XwcTextItem, unk6: s32) -> void #c_call;

Xutf8DrawText: #type (unk0: *Display, unk1: Drawable, unk2: GC, unk3: s32, unk4: s32, unk5: *XmbTextItem, unk6: s32) -> void #c_call;

XmbDrawString: #type (unk0: *Display, unk1: Drawable, unk2: XFontSet, unk3: GC, unk4: s32, unk5: s32, unk6: *u8, unk7: s32) -> void #c_call;

XwcDrawString: #type (unk0: *Display, unk1: Drawable, unk2: XFontSet, unk3: GC, unk4: s32, unk5: s32, unk6: *wchar_t, unk7: s32) -> void #c_call;

Xutf8DrawString: #type (unk0: *Display, unk1: Drawable, unk2: XFontSet, unk3: GC, unk4: s32, unk5: s32, unk6: *u8, unk7: s32) -> void #c_call;

XmbDrawImageString: #type (unk0: *Display, unk1: Drawable, unk2: XFontSet, unk3: GC, unk4: s32, unk5: s32, unk6: *u8, unk7: s32) -> void #c_call;

XwcDrawImageString: #type (unk0: *Display, unk1: Drawable, unk2: XFontSet, unk3: GC, unk4: s32, unk5: s32, unk6: *wchar_t, unk7: s32) -> void #c_call;

Xutf8DrawImageString: #type (unk0: *Display, unk1: Drawable, unk2: XFontSet, unk3: GC, unk4: s32, unk5: s32, unk6: *u8, unk7: s32) -> void #c_call;

XOpenIM: #type (unk0: *Display, unk1: *_XrmHashBucketRec, unk2: *u8, unk3: *u8) -> XIM #c_call;

XCloseIM: #type (unk0: XIM) -> s32 #c_call;

XGetIMValues: #type (unk0: XIM, __args: ..Any) -> *u8 #c_call;

XSetIMValues: #type (unk0: XIM, __args: ..Any) -> *u8 #c_call;

XDisplayOfIM: #type (unk0: XIM) -> *Display #c_call;

XLocaleOfIM: #type (unk0: XIM) -> *u8 #c_call;

XCreateIC: #type (unk0: XIM, __args: ..Any) -> XIC #c_call;

XDestroyIC: #type (unk0: XIC) -> void #c_call;

XSetICFocus: #type (unk0: XIC) -> void #c_call;

XUnsetICFocus: #type (unk0: XIC) -> void #c_call;

XwcResetIC: #type (unk0: XIC) -> *wchar_t #c_call;

XmbResetIC: #type (unk0: XIC) -> *u8 #c_call;

Xutf8ResetIC: #type (unk0: XIC) -> *u8 #c_call;

XSetICValues: #type (unk0: XIC, __args: ..Any) -> *u8 #c_call;

XGetICValues: #type (unk0: XIC, __args: ..Any) -> *u8 #c_call;

XIMOfIC: #type (unk0: XIC) -> XIM #c_call;

XFilterEvent: #type (unk0: *XEvent, unk1: Window) -> s32 #c_call;

XmbLookupString: #type (unk0: XIC, unk1: *XKeyPressedEvent, unk2: *u8, unk3: s32, unk4: *KeySym, unk5: *s32) -> s32 #c_call;

XwcLookupString: #type (unk0: XIC, unk1: *XKeyPressedEvent, unk2: *wchar_t, unk3: s32, unk4: *KeySym, unk5: *s32) -> s32 #c_call;

Xutf8LookupString: #type (unk0: XIC, unk1: *XKeyPressedEvent, unk2: *u8, unk3: s32, unk4: *KeySym, unk5: *s32) -> s32 #c_call;

XVaCreateNestedList: #type (unk0: s32, __args: ..Any) -> XVaNestedList #c_call;

XRegisterIMInstantiateCallback: #type (unk0: *Display, unk1: *_XrmHashBucketRec, unk2: *u8, unk3: *u8, unk4: XIDProc, unk5: XPointer) -> s32 #c_call;

XUnregisterIMInstantiateCallback: #type (unk0: *Display, unk1: *_XrmHashBucketRec, unk2: *u8, unk3: *u8, unk4: XIDProc, unk5: XPointer) -> s32 #c_call;

XConnectionWatchProc :: #type (a0: *Display, a1: XPointer, a2: s32, a3: s32, a4: *XPointer) -> void #c_call;

XInternalConnectionNumbers: #type (unk0: *Display, unk1: **s32, unk2: *s32) -> s32 #c_call;

XProcessInternalConnection: #type (unk0: *Display, unk1: s32) -> void #c_call;

XAddConnectionWatch: #type (unk0: *Display, unk1: XConnectionWatchProc, unk2: XPointer) -> s32 #c_call;

XRemoveConnectionWatch: #type (unk0: *Display, unk1: XConnectionWatchProc, unk2: XPointer) -> void #c_call;

XSetAuthorization: #type (unk0: *u8, unk1: s32, unk2: *u8, unk3: s32) -> void #c_call;

_Xmbtowc: #type (unk0: *wchar_t, unk1: *u8, unk2: s32) -> s32 #c_call;

_Xwctomb: #type (unk0: *u8, unk1: wchar_t) -> s32 #c_call;

XGetEventData: #type (unk0: *Display, unk1: *XGenericEventCookie) -> s32 #c_call;

XFreeEventData: #type (unk0: *Display, unk1: *XGenericEventCookie) -> void #c_call;

XSizeHints :: struct {
    flags: s64;
    x: s32;
    y: s32;
    width: s32;
    height: s32;
    min_width: s32;
    min_height: s32;
    max_width: s32;
    max_height: s32;
    width_inc: s32;
    height_inc: s32;
    min_aspect, max_aspect: struct {
        x: s32;
        y: s32;
    };
    base_width: s32;
    base_height: s32;
    win_gravity: s32;
}

XWMHints :: struct {
    flags: s64;
    input: s32;
    initial_state: s32;
    icon_pixmap: Pixmap;
    icon_window: Window;
    icon_x: s32;
    icon_y: s32;
    icon_mask: Pixmap;
    window_group: XID;
}

XTextProperty :: struct {
    value: *u8;
    encoding: Atom;
    format: s32;
    nitems: u64;
}

using XICCEncodingStyle :: enum u32 {
    XStringStyle :: 0;
    XCompoundTextStyle :: 1;
    XTextStyle :: 2;
    XStdICCTextStyle :: 3;
    XUTF8StringStyle :: 4;
}

XIconSize :: struct {
    min_width: s32;
    min_height: s32;
    max_width: s32;
    max_height: s32;
    width_inc: s32;
    height_inc: s32;
}

anon_struct_6 :: struct {
    res_name: *u8;
    res_class: *u8;
}

XClassHint :: anon_struct_6;

_XComposeStatus :: struct {
    compose_ptr: XPointer;
    chars_matched: s32;
}

XComposeStatus :: _XComposeStatus;

_XRegion :: struct {
}

Region :: *_XRegion;

XVisualInfo :: struct {
    visual: *Visual;
    visualid: VisualID;
    screen: s32;
    depth: s32;
    class: s32;
    red_mask: u64;
    green_mask: u64;
    blue_mask: u64;
    colormap_size: s32;
    bits_per_rgb: s32;
}

XStandardColormap :: struct {
    colormap: Colormap;
    red_max: u64;
    red_mult: u64;
    green_max: u64;
    green_mult: u64;
    blue_max: u64;
    blue_mult: u64;
    base_pixel: u64;
    visualid: VisualID;
    killid: XID;
}

XContext :: s32;

XAllocClassHint: #type () -> *XClassHint #c_call;

XAllocIconSize: #type () -> *XIconSize #c_call;

XAllocSizeHints: #type () -> *XSizeHints #c_call;

XAllocStandardColormap: #type () -> *XStandardColormap #c_call;

XAllocWMHints: #type () -> *XWMHints #c_call;

XClipBox: #type (unk0: Region, unk1: *XRectangle) -> s32 #c_call;

XCreateRegion: #type () -> Region #c_call;

XDefaultString: #type () -> *u8 #c_call;

XDeleteContext: #type (unk0: *Display, unk1: XID, unk2: XContext) -> s32 #c_call;

XDestroyRegion: #type (unk0: Region) -> s32 #c_call;

XEmptyRegion: #type (unk0: Region) -> s32 #c_call;

XEqualRegion: #type (unk0: Region, unk1: Region) -> s32 #c_call;

XFindContext: #type (unk0: *Display, unk1: XID, unk2: XContext, unk3: *XPointer) -> s32 #c_call;

XGetClassHint: #type (unk0: *Display, unk1: Window, unk2: *XClassHint) -> s32 #c_call;

XGetIconSizes: #type (unk0: *Display, unk1: Window, unk2: **XIconSize, unk3: *s32) -> s32 #c_call;

XGetNormalHints: #type (unk0: *Display, unk1: Window, unk2: *XSizeHints) -> s32 #c_call;

XGetRGBColormaps: #type (unk0: *Display, unk1: Window, unk2: **XStandardColormap, unk3: *s32, unk4: Atom) -> s32 #c_call;

XGetSizeHints: #type (unk0: *Display, unk1: Window, unk2: *XSizeHints, unk3: Atom) -> s32 #c_call;

XGetStandardColormap: #type (unk0: *Display, unk1: Window, unk2: *XStandardColormap, unk3: Atom) -> s32 #c_call;

XGetTextProperty: #type (unk0: *Display, unk1: Window, unk2: *XTextProperty, unk3: Atom) -> s32 #c_call;

XGetVisualInfo: #type (unk0: *Display, unk1: s64, unk2: *XVisualInfo, unk3: *s32) -> *XVisualInfo #c_call;

XGetWMClientMachine: #type (unk0: *Display, unk1: Window, unk2: *XTextProperty) -> s32 #c_call;

XGetWMHints: #type (unk0: *Display, unk1: Window) -> *XWMHints #c_call;

XGetWMIconName: #type (unk0: *Display, unk1: Window, unk2: *XTextProperty) -> s32 #c_call;

XGetWMName: #type (unk0: *Display, unk1: Window, unk2: *XTextProperty) -> s32 #c_call;

XGetWMNormalHints: #type (unk0: *Display, unk1: Window, unk2: *XSizeHints, unk3: *s64) -> s32 #c_call;

XGetWMSizeHints: #type (unk0: *Display, unk1: Window, unk2: *XSizeHints, unk3: *s64, unk4: Atom) -> s32 #c_call;

XGetZoomHints: #type (unk0: *Display, unk1: Window, unk2: *XSizeHints) -> s32 #c_call;

XIntersectRegion: #type (unk0: Region, unk1: Region, unk2: Region) -> s32 #c_call;

XConvertCase: #type (unk0: KeySym, unk1: *KeySym, unk2: *KeySym) -> void #c_call;

XLookupString: #type (unk0: *XKeyEvent, unk1: *u8, unk2: s32, unk3: *KeySym, unk4: *XComposeStatus) -> s32 #c_call;

XMatchVisualInfo: #type (unk0: *Display, unk1: s32, unk2: s32, unk3: s32, unk4: *XVisualInfo) -> s32 #c_call;

XOffsetRegion: #type (unk0: Region, unk1: s32, unk2: s32) -> s32 #c_call;

XPointInRegion: #type (unk0: Region, unk1: s32, unk2: s32) -> s32 #c_call;

XPolygonRegion: #type (unk0: *XPoint, unk1: s32, unk2: s32) -> Region #c_call;

XRectInRegion: #type (unk0: Region, unk1: s32, unk2: s32, unk3: u32, unk4: u32) -> s32 #c_call;

XSaveContext: #type (unk0: *Display, unk1: XID, unk2: XContext, unk3: *u8) -> s32 #c_call;

XSetClassHint: #type (unk0: *Display, unk1: Window, unk2: *XClassHint) -> s32 #c_call;

XSetIconSizes: #type (unk0: *Display, unk1: Window, unk2: *XIconSize, unk3: s32) -> s32 #c_call;

XSetNormalHints: #type (unk0: *Display, unk1: Window, unk2: *XSizeHints) -> s32 #c_call;

XSetRGBColormaps: #type (unk0: *Display, unk1: Window, unk2: *XStandardColormap, unk3: s32, unk4: Atom) -> void #c_call;

XSetSizeHints: #type (unk0: *Display, unk1: Window, unk2: *XSizeHints, unk3: Atom) -> s32 #c_call;

XSetStandardProperties: #type (unk0: *Display, unk1: Window, unk2: *u8, unk3: *u8, unk4: Pixmap, unk5: **u8, unk6: s32, unk7: *XSizeHints) -> s32 #c_call;

XSetTextProperty: #type (unk0: *Display, unk1: Window, unk2: *XTextProperty, unk3: Atom) -> void #c_call;

XSetWMClientMachine: #type (unk0: *Display, unk1: Window, unk2: *XTextProperty) -> void #c_call;

XSetWMHints: #type (unk0: *Display, unk1: Window, unk2: *XWMHints) -> s32 #c_call;

XSetWMIconName: #type (unk0: *Display, unk1: Window, unk2: *XTextProperty) -> void #c_call;

XSetWMName: #type (unk0: *Display, unk1: Window, unk2: *XTextProperty) -> void #c_call;

XSetWMNormalHints: #type (unk0: *Display, unk1: Window, unk2: *XSizeHints) -> void #c_call;

XSetWMProperties: #type (unk0: *Display, unk1: Window, unk2: *XTextProperty, unk3: *XTextProperty, unk4: **u8, unk5: s32, unk6: *XSizeHints, unk7: *XWMHints, unk8: *XClassHint) -> void #c_call;

XmbSetWMProperties: #type (unk0: *Display, unk1: Window, unk2: *u8, unk3: *u8, unk4: **u8, unk5: s32, unk6: *XSizeHints, unk7: *XWMHints, unk8: *XClassHint) -> void #c_call;

Xutf8SetWMProperties: #type (unk0: *Display, unk1: Window, unk2: *u8, unk3: *u8, unk4: **u8, unk5: s32, unk6: *XSizeHints, unk7: *XWMHints, unk8: *XClassHint) -> void #c_call;

XSetWMSizeHints: #type (unk0: *Display, unk1: Window, unk2: *XSizeHints, unk3: Atom) -> void #c_call;

XSetRegion: #type (unk0: *Display, unk1: GC, unk2: Region) -> s32 #c_call;

XSetStandardColormap: #type (unk0: *Display, unk1: Window, unk2: *XStandardColormap, unk3: Atom) -> void #c_call;

XSetZoomHints: #type (unk0: *Display, unk1: Window, unk2: *XSizeHints) -> s32 #c_call;

XShrinkRegion: #type (unk0: Region, unk1: s32, unk2: s32) -> s32 #c_call;

XStringListToTextProperty: #type (unk0: **u8, unk1: s32, unk2: *XTextProperty) -> s32 #c_call;

XSubtractRegion: #type (unk0: Region, unk1: Region, unk2: Region) -> s32 #c_call;

XmbTextListToTextProperty: #type (display: *Display, list: **u8, count: s32, style: XICCEncodingStyle, text_prop_return: *XTextProperty) -> s32 #c_call;

XwcTextListToTextProperty: #type (display: *Display, list: **wchar_t, count: s32, style: XICCEncodingStyle, text_prop_return: *XTextProperty) -> s32 #c_call;

Xutf8TextListToTextProperty: #type (display: *Display, list: **u8, count: s32, style: XICCEncodingStyle, text_prop_return: *XTextProperty) -> s32 #c_call;

XwcFreeStringList: #type (list: **wchar_t) -> void #c_call;

XTextPropertyToStringList: #type (unk0: *XTextProperty, unk1: ***u8, unk2: *s32) -> s32 #c_call;

XmbTextPropertyToTextList: #type (display: *Display, text_prop: *XTextProperty, list_return: ***u8, count_return: *s32) -> s32 #c_call;

XwcTextPropertyToTextList: #type (display: *Display, text_prop: *XTextProperty, list_return: ***wchar_t, count_return: *s32) -> s32 #c_call;

Xutf8TextPropertyToTextList: #type (display: *Display, text_prop: *XTextProperty, list_return: ***u8, count_return: *s32) -> s32 #c_call;

XUnionRectWithRegion: #type (unk0: *XRectangle, unk1: Region, unk2: Region) -> s32 #c_call;

XUnionRegion: #type (unk0: Region, unk1: Region, unk2: Region) -> s32 #c_call;

XWMGeometry: #type (unk0: *Display, unk1: s32, unk2: *u8, unk3: *u8, unk4: u32, unk5: *XSizeHints, unk6: *s32, unk7: *s32, unk8: *s32, unk9: *s32, unk10: *s32) -> s32 #c_call;

XXorRegion: #type (unk0: Region, unk1: Region, unk2: Region) -> s32 #c_call;


XrmValue :: struct {
    size: u32;
    addr: XPointer;
}

XrmValuePtr :: *XrmValue;


XrmDatabase :: *_XrmHashBucketRec;

XrmGetStringDatabase: #type (data: *u8) -> XrmDatabase #c_call;

XrmGetResource: #type (db: XrmDatabase, str_name: *u8, str_class: *u8, str_return_type: **u8, value: *XrmValue) -> Bool #c_call;

XrmDestroyDatabase: #type (db: XrmDatabase) #c_call;



// These are normally #defines in C, sigh
DefaultRootWindow :: inline (display: *Display) -> Window {
    return ScreenOfDisplay(display, DefaultScreen(display)).root;
}

DefaultScreen :: inline (display: *Display) -> s32 {
    return (cast(_XPrivDisplay) display).default_screen;
}

ScreenOfDisplay :: inline (display: *Display, scr: s32) -> *Screen {
    return *(cast(_XPrivDisplay) display).screens[scr];
}

DefaultScreenOfDisplay :: inline (display: *Display) -> *Screen {
    return ScreenOfDisplay(display, DefaultScreen(display));
}

DefaultGC :: inline (display: *Display, scr: s32) -> GC {
    return ScreenOfDisplay(display, scr).default_gc;
}

// Xkb "extension" API (it's technically an extension but comes standard and must be explicitly disabled if an X server doesnt want to use it...)
XkbKeycodeToKeysym: #type (dpy: *Display, kc: KeyCode, group: u32, level: u32) -> KeySym #c_call;

// glX API

GLX_RGBA            :: 4;
GLX_DOUBLEBUFFER    :: 5;
GLX_RED_SIZE        :: 8;
GLX_GREEN_SIZE      :: 9;
GLX_BLUE_SIZE       :: 10;
GLX_ALPHA_SIZE      :: 11;
GLX_DEPTH_SIZE      :: 12;
GLX_STENCIL_SIZE    :: 13;

GLX_X_VISUAL_TYPE               :: 0x0022;
GLX_CONTEXT_MAJOR_VERSION_ARB   :: 0x2091;
GLX_CONTEXT_MINOR_VERSION_ARB   :: 0x2092;
GLX_CONTEXT_FLAGS_ARB           :: 0x2094;
GLX_TRUE_COLOR                  :: 0x8002;
GLX_DRAWABLE_TYPE               :: 0x8010;
GLX_RENDER_TYPE                 :: 0x8011;
GLX_X_RENDERABLE                :: 0x8012;
GLX_CONTEXT_PROFILE_MASK_ARB    :: 0x9126;
GLX_SAMPLE_BUFFERS              :: 0x186a0;
GLX_SAMPLES                     :: 0x186a1;

GLX_WINDOW_BIT      :: 0x01;
GLX_RGBA_BIT        :: 0x01;

GLX_CONTEXT_CORE_PROFILE_BIT_ARB            :: 0x01;
GLX_CONTEXT_COMPATIBILITY_PROFILE_BIT_ARB   :: 0x02;
GLX_CONTEXT_DEBUG_BIT_ARB                   :: 0x01;
GLX_CONTEXT_FORWARD_COMPATIBLE_BIT_ARB      :: 0x02;


GLXContext  :: *void;
GLXDrawable :: u64;
GLXFBConfig :: *void;
GLXWindow   :: XID;

glXChooseVisual: #type (dpy: *Display, screen: s32, attrib_list: *s32) -> *XVisualInfo #c_call;
glXCreateContext: #type (dpy: *Display, visual: *XVisualInfo, share_list: GLXContext, direct: s32) -> GLXContext #c_call;
glXMakeCurrent: #type (dpy: *Display, drawable: GLXDrawable, ctx: GLXContext) -> s32 #c_call;
glXGetCurrentContext: #type () -> GLXContext #c_call;
glXSwapBuffers: #type (dpy: *Display, drawable: GLXDrawable) -> void #c_call;
glXDestroyContext: #type (dpy: *Display, ctx: GLXContext) #c_call;
glXGetProcAddress: #type (procName: *u8) -> *void #c_call;
glXChooseFBConfig: #type (disp: *Display, screen: s32, attrib_list: *s32, nelements: *s32) -> *GLXFBConfig #c_call;
glXGetFBConfigAttrib: #type (disp: *Display, config: GLXFBConfig, attribute: s32, value: *s32) -> s32 #c_call;
glXGetVisualFromFBConfig: #type (disp: *Display, config: GLXFBConfig) -> *XVisualInfo #c_call;
glXGetConfig: #type (disp: *Display, vis: *XVisualInfo, attrib: s32, value: *s32) -> s32 #c_call;
glXCreateWindow: #type (display: *Display, config: GLXFBConfig, window: Window, attrib_list: *s32 = null) -> GLXWindow #c_call;

#load "loader.jai";

#scope_file

String :: #import "String";
trim :: String.trim;

POSIX :: #import "POSIX";
getenv :: POSIX.getenv;

// Storing setlocale bindings right here, because hopefully X11 module is the only place they will ever be needed in.
// This whole setlocale API is very-very old and bad, and only ancient software (such as libX11) relies on it.
LC_ALL : s32 : 6;
setlocale :: (what: s32, loc: *u8) -> *u8 #foreign libc;


wchar_t :: u64; // #Cleanup The Xlib headers specify this as unsigned long if it is not defined in any headers, we should probably remove this when we figure out where types like this belong

libc   :: #library,system "libc";

/*

Copyright 2021, Thekla, Inc (portions of this code, dealing with Xdnd, are copyright Jens Frederich).

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

*/
