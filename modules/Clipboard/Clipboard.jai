#if OS == .WINDOWS {
    #import "Windows";
    #import "Basic";  // For alloc.

    // Clipboard functions.

    os_clipboard_get_text :: () -> string {
        hwnd := GetActiveWindow();  // @Robustness: We probably want something better than this.
        return os_clipboard_get_text(hwnd);
    }

    os_clipboard_set_text :: (text: string) {
        hwnd := GetActiveWindow();  // @Robustness: We probably want something better than this.
        os_clipboard_set_text(hwnd, text);
    }

    os_clipboard_set_bitmap :: (width: s32, height: s32, pixels: *u8, channels: s32, flip := false) {
        hwnd := GetActiveWindow();  // @Robustness: We probably want something better than this.
        os_clipboard_set_bitmap(hwnd, width, height, pixels, channels, flip);
    }

    os_clipboard_empty :: () {
        hwnd := GetActiveWindow();  // @Robustness: We probably want something better than this.
        os_clipboard_empty(hwnd);
    }


    #scope_file

    os_clipboard_get_text :: (hwnd: HWND) -> string {  // Allocated via alloc; should be manually freed.
        text: string;

        if OpenClipboard(hwnd) {
            hData := GetClipboardData(CF_UNICODETEXT);

            buffer := cast(*u8)GlobalLock(hData);
            {
                CP :: CP_UTF8;
                WC :: 0;

                // Phase 1: Figure out how long this is.
                length := WideCharToMultiByte(CP, 0, cast(*u16)hData, -1, null, 0, null, null);

                utf8 := alloc(length);
                WideCharToMultiByte(CP, WC, cast(*u16)hData, -1, utf8, length, null, null);

                if length {
                    text.count = length-1;  // Terminating zero.
                    text.data  = utf8;
                    assert(text.data[length-1] == 0);
                } else {
                    text = "";
                }
            }

            GlobalUnlock(hData);
            CloseClipboard();
        }

        return text;
    }

    os_clipboard_set_text :: (hwnd: HWND, text: string) {
        if !OpenClipboard(hwnd) return;

        EmptyClipboard();

        CP :: CP_UTF8;
        WC :: 0;

        length := MultiByteToWideChar(CP, WC, text.data, xx text.count, null, 0);

        utf16 := cast(*u16)alloc(length * 2 + 2);   // @@ Use temporary memory?
        defer free(utf16);

        new_length := MultiByteToWideChar(CP, WC, text.data, xx text.count, utf16, length);
        assert(new_length <= length);
        utf16[new_length] = 0;

        clipbuffer := GlobalAlloc(0, xx (new_length*2+2));
        buffer := cast(*u8)GlobalLock(clipbuffer);
        memcpy(buffer, utf16, new_length*2+2);
        GlobalUnlock(clipbuffer);

        SetClipboardData(CF_UNICODETEXT, clipbuffer);
        CloseClipboard();
    }


    os_clipboard_empty :: (hwnd: HWND) {
        if OpenClipboard(hwnd) {
            EmptyClipboard();
            CloseClipboard();
        }
    }

    // This assumes input rows are 4-byte aligned.
    // @Cleanup: Log an error if this is not true, so that we don't make silently wrong output.
    os_clipboard_set_bitmap :: (hwnd: HWND, width: s32, height: s32, pixels: *u8, channels: s32, flip := false) {
        if !OpenClipboard(hwnd) return;

        assert((channels == 3) || (channels == 4));
        EmptyClipboard();

        pitch_src := width * channels;
		pitch_dst := (width * channels + 3) & -4;

        dst_size := cast(u64)(pitch_dst * height);

        // create HGLOBAL storage for image
        hMem := GlobalAlloc(GMEM_SHARE, size_of(BITMAPINFOHEADER) + dst_size);
        mem := cast(*u8)GlobalLock(hMem);

        // fill in image info
        bmh: BITMAPINFOHEADER;
        bmh.biSize = size_of(BITMAPINFOHEADER);
        bmh.biWidth = width;
        bmh.biHeight = height;
        bmh.biPlanes = 1;
        bmh.biBitCount = cast(u16)(channels * 8);
        bmh.biCompression = BI_RGB;

        memcpy(mem, *bmh, size_of(BITMAPINFOHEADER));

        dst := mem + size_of(BITMAPINFOHEADER);

        // Flip image, swap channels and make sure it's word-aligned.
        bytes_per_line := width * channels;
        for y: 0..height-1 {
            src: type_of(pixels);
            if flip { // @Speed: Could update pitch incrementally by adding a dpitch each line.
                src = pixels + (height - 1 - y) * pitch_src;
            } else {
                src = pixels + y * pitch_src;
            }

            // We can't memcpy because Windows BMPs are BGR instead of RGB, yay.
            for x: 0..width-1 {
                dst[channels*x+0] = src[channels*x+2];
                dst[channels*x+1] = src[channels*x+1];
                dst[channels*x+2] = src[channels*x+0];
                if channels == 3  dst[channels*x+3] = src[channels*x+3];
            }

            dst += pitch_dst;
        }

        GlobalUnlock(hMem);

        // Set clipboard data.
        SetClipboardData(CF_DIB, hMem);

        CloseClipboard();
    }
}

#if OS == .LINUX {
    #import "Basic";
    #import "X11";
    // VENDORED CHANGE (jai-wayland): route the no-arg clipboard entry points to
    // Wayland_Support when running under Wayland; the X11 bodies below are unchanged
    // and used under X11. The (win: Window) overloads stay X11-only — the no-arg
    // versions short-circuit to Wayland before they would ever call them.
    WS :: #import "Wayland_Support";

    os_clipboard_get_text :: (win: Window) -> string {  // Allocated via alloc; should be manually freed.
        text: string;
        display := x_global_display;
        selection_owner := XGetSelectionOwner(display, x_global_xa_clipboard);

        // if we created the window then we pull directly from our own locat clipbuffer
        if x_window_is_ours(display, selection_owner) {
            return copy_string(x_global_clipboard_buffer.text_data);
        } else if selection_owner != None {
            property := XInternAtom(display, "JAI_SELECTION", False);
            XConvertSelection(display, x_global_xa_clipboard, x_global_xa_utf8, property, win, CurrentTime);
            xev: XEvent;

            sleep_milliseconds(1);

            // @Warning: This will block until we recive a notification back from the selection owner.
            // This seems bad? Ugh.
            XIfEvent(display, xx *xev, x_selection_notify_predicate, *win);


            if (cast(*XSelectionEvent) *xev).property == None then return text;

            nitems, rem: u64;
            format: s32;
            data: *u8;
            type: Atom;
            if XGetWindowProperty(display, win, property, 0, ~0, True, AnyPropertyType, *type, *format, *nitems, *rem, *data) == 0 {
                if rem != 0  log_error("This X11 clipboard handling code is not complete and does not handle multi-chunk input, but we got a remainder of % bytes. This data is unhandled.\n", rem);
                if (type == x_global_xa_utf8) && (format == 8) { // Normal utf-8 text.
                    temp: string;
                    temp.data = data;
                    temp.count = xx nitems;
                    text = copy_string(temp);
                    XFree(data);
                    return text;
                } else {
                    // @Incomplete: Data sent in unsupported formats.
                }
            }
        }

        return text;
    }

    os_clipboard_get_text :: () -> string {
        if WS.running_wayland()  return WS.wl_clipboard_get_text();
        display := x_global_display;
        if !display return "";
        win: Window;
        revert: s32;
        XGetInputFocus(display, *win, *revert);
        return os_clipboard_get_text(win);
    }

    os_clipboard_set_text :: (win: Window, text: string) {
        XSetSelectionOwner(x_global_display, x_global_xa_clipboard, win, CurrentTime);
        owner := XGetSelectionOwner(x_global_display, x_global_xa_clipboard);
        if owner != win return;

        x_release_clipboard_data();
        x_global_clipboard_buffer.text_data = copy_string(text);
    }

    os_clipboard_set_text :: (text: string) {
        if WS.running_wayland() { WS.wl_clipboard_set_text(text); return; }
        display := x_global_display;
        if !display return;
        win: Window;
        revert: s32;
        XGetInputFocus(display, *win, *revert);
        os_clipboard_set_text(win, text);
    }

    os_clipboard_set_bitmap :: (win: Window, width: s32, height: s32, pixels: *u8, channels: s32, flip := false) {
        XSetSelectionOwner(x_global_display, x_global_xa_clipboard, win, CurrentTime);
        owner := XGetSelectionOwner(x_global_display, x_global_xa_clipboard);
        if owner != win return;

        XLockDisplay(x_global_display);

        src := pixels;
        dst := cast(*u8) alloc(width * height * channels);

        pitch_src := width * channels;

        if flip {
            bytes_per_line := width * channels;
            for y: 0..height-1 {
                src := pixels + (height - 1 - y) * pitch_src;
                memcpy(dst, src, bytes_per_line);
            }
        } else {
            memcpy(dst, src, width * height * channels);
        }

        x_release_clipboard_data();
        x_global_clipboard_buffer.rgb_data = dst;
        x_global_clipboard_buffer.width    = width;
        x_global_clipboard_buffer.height   = height;
        x_global_clipboard_buffer.pitch    = width * channels;

        XUnlockDisplay(x_global_display);
    }

    os_clipboard_set_bitmap :: (width: s32, height: s32, pixels: *u8, channels: s32, flip := false) {
        if WS.running_wayland() {
            log("Clipboard bitmaps are not supported on the Wayland backend yet; ignoring os_clipboard_set_bitmap.", flags=.WARNING);
            return;
        }
        display := x_global_display;
        if !display return;
        win: Window;
        revert: s32;
        XGetInputFocus(display, *win, *revert);
        os_clipboard_set_bitmap(win, width, height, pixels, channels, flip);
    }
}

#if OS == .MACOS {
    // @Cleanup: Don't export these?!
    #import "Basic";
    #import "Objective_C";
    #import "Objective_C/AppKit";

    os_clipboard_get_text :: () -> string {
        general := NSPasteboard.generalPasteboard();

        nsstring := general.stringForType(general, NSPasteboardTypeString);
        if !nsstring return "";

        out := copy_string(to_string(nsstring));
        return out;
    }

    os_clipboard_set_text :: (text: string) {
        general := NSPasteboard.generalPasteboard();

        nsstring := NSString.initWithString(objc_alloc(NSString), text);
        defer release(nsstring);

        general.clearContents(general);
        general.setString(general, nsstring, NSPasteboardTypeString);
    }

    os_clipboard_empty :: () {
        general := NSPasteboard.generalPasteboard();
        general.clearContents(general);
    }

    os_clipboard_set_bitmap :: (width: s32, height: s32, pixels: *u8, channels: s32, flip := false) {
        general := NSPasteboard.generalPasteboard();
        general.clearContents(general);

        image_rep := NSBitmapImageRep.initWithBitmapDataPlanes(objc_alloc(NSBitmapImageRep), null, width, height, 8, channels, NO, NO, NSDeviceRGBColorSpace, 0, 0);
        defer release(image_rep);

        dst := image_rep.bitmapData(image_rep);

        dst_pitch := 2 * ((width * channels + 1) >> 1);
        dst_size := cast(u64)(dst_pitch * height);

        bytes_per_line := width * channels;
        for y: 0..height-1 {
            src := pixels + y * bytes_per_line;
            memcpy(dst, src, bytes_per_line);

            dst += dst_pitch;
        }

        image := NSImage.initWithSize(objc_alloc(NSImage), image_rep.size(image_rep));
        image.addRepresentation(image, image_rep);
        defer release(image);

        nsarray := NSArray(id).arrayWithObjects(xx *image, 1);
        general.writeObjects(general, nsarray);
    }
}

#if OS == .PS5 || OS == .NN_SWITCH2 {
    // Clipboard functions are not supported on PS5 or Switch2.
    os_clipboard_set_text :: (text: string) { }
    os_clipboard_set_bitmap :: (width: s32, height: s32, pixels: *u8, channels: s32, flip := false) { }
    os_clipboard_get_text   :: () -> string { return ""; }
    os_clipboard_empty :: () { }
}

// @Incomplete: Not yet implemented on Android.
#if OS == .ANDROID {
    os_clipboard_set_text :: (text: string) { }
    os_clipboard_set_bitmap :: (width: s32, height: s32, pixels: *u8, channels: s32, flip := false) { }
    os_clipboard_get_text   :: () -> string { return ""; }
    os_clipboard_empty :: () { }
}
