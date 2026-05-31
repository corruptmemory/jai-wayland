// Vendored from ~/jai/jai/modules/Clipboard/. The only change is in the Linux
// branch of Clipboard.jai: the no-arg os_clipboard_get_text / set_text / set_bitmap
// route to Wayland_Support (wl_clipboard_*) when running_wayland(), so copy/paste
// works on the Wayland backend. The X11 bodies are untouched.

/*

A set of OS clipboard functions, such as getting text out of the clipboard, setting a bitmap, etc.

API
--------------------------------------------------------------
```
os_clipboard_get_text   :: () -> string                        - Retrieves a copy of the string that is currently in the clipboard.
os_clipboard_set_text   :: (text: string)                      - Copies a string into the clipboard.
os_clipboard_set_bitmap :: (width: s32, height: s32, rgb: *u8) - Copies a bitmap in RGB8 format into the clipboard.
os_clipboard_empty      :: ()                                  - Clears any and all data currently in the clipboard.
```
*/

#load "Clipboard.jai";
