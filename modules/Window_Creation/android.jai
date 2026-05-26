// Vendored from ~/jai/jai/modules/Window_Creation/android.jai.
// Verbatim copy.

Saved_Window_Info :: struct {}

//
// "Fullscreen" on android is weird... There are (at least) two things to care about:
// - Most phones now have "cut outs", eg if your camera is on the screen, so do you want to render all the way to the edge, or
//   limit to the area not covered by any cutouts.
// - There is the "status bar" (icons at top of the screen), the "navigation bar" (the back/home buttons, or the gesture
//   pill at bottom of screen). Should this be drawn?
//
// How your app behaves is initially controlled by the "theme" of your app. The NDK only exposes a very limted ability to
// modify this at runtime which is what we do in toggle_fullscreen, this is very rarely going to be what you want though.
//
// There are java apis that provide the functionality we want, but they are only intended to be run from the android "ui"
// thread. This is easy to do in java, but I am not aware of a way to do it via the jni.
//
// We provide android_set_fullscreen_for_real which uses these apis. In some cases it is useful, eg if you just call it
// once at startup it is usually ok, but it is not reliable so it is not the default. Calling it multiple times
// can lead to java exceptions being thrown, we handle these exceptions, but for some reason it then leaves
// Android_App.conctentRect in an incorrect state, so apps that use that (which Input uses for resize events)
// things will be messed up!
//
// This is a sorry situation! Showing/hiding software keyboard has the same issue :AndroidWindowInsetsIssues :AndroidMaybeWeHaveToUseJavaAfterallSadge
//

// Hides the status bar, and sets us the render area to not include any cut outs.
toggle_fullscreen :: (win: *Android.ANativeWindow, desire_fullscreen: bool, saved: *Saved_Window_Info) -> success: bool, width: s32, height: s32 {
    assert(android_app != null && android_app.activity != null);
    assert(saved == null, "Saved_Window_Info doesn't make sense on android");

    // Q: Where to do these kinds of window settings more generally?
    // window_flags: AWINDOW_FLAG = .FULLSCREEN | .LAYOUT_IN_SCREEN | .LAYOUT_NO_LIMITS | .LAYOUT_INSET_DECOR;
    window_flags: Android.AWINDOW_FLAG = .FULLSCREEN;
    if desire_fullscreen Android.ANativeActivity_setWindowFlags(android_app.activity, xx window_flags, 0);
    else                 Android.ANativeActivity_setWindowFlags(android_app.activity, 0, xx window_flags);

    _, _, width, height := get_dimensions(win, true);
    return true, width, height;
}

// @Experimental: An alternative to toggle_fullscreen that tries to properly make use fullscreen by setting the app to be
// edge to edge, and hide all system ui. At least the system ui part will need to be called everytime the app comes into
// focus (I think...). 
android_set_fullscreen_for_real :: () {
    assert(android_app != null && android_app.activity != null);

    //
    // Look up Classes, Methods, etc used
    //

    Activity := FindClass("android/app/Activity");
    getWindow := GetMethodID(Activity, "getWindow", "()Landroid/view/Window;");

    Window := FindClass("android/view/Window");
    getAttributes       := GetMethodID(Window, "getAttributes", "()Landroid/view/WindowManager$LayoutParams;");
    setAttributes       := GetMethodID(Window, "setAttributes", "(Landroid/view/WindowManager$LayoutParams;)V");
    getDecorView        := GetMethodID(Window, "getDecorView", "()Landroid/view/View;");
    getInsetsController := GetMethodID(Window, "getInsetsController", "()Landroid/view/WindowInsetsController;");

    WindowInsetsController := FindClass("android/view/WindowInsetsController");
    hide := GetMethodID(WindowInsetsController, "hide", "(I)V");

    View := FindClass("android/view/View");
    setSystemUiVisibility := GetMethodID(View, "setSystemUiVisibility", "(I)V");
    
    WindowManager_LayoutParams := FindClass("android/view/WindowManager$LayoutParams");
    layoutInDisplayCutoutMode := GetFieldID(WindowManager_LayoutParams, "layoutInDisplayCutoutMode", "I");

    window := CallObjectMethod(android_app.activity.clazz, getWindow);
    assert(window != null);

    //
    // Set us edge to edge
    //

    JAVA_CODE :: #string JAVA
        Window window = getWindow();
        WindowManager.LayoutParams layoutParams = window.getAttributes();
        layoutParams.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
        window.setAttributes(layoutParams);
    JAVA
    attributes := CallObjectMethod(window, getAttributes);
    env.*.SetIntField(env, attributes, layoutInDisplayCutoutMode, xx LAYOUT_IN_DISPLAY_CUTOUT_MODE.SHORT_EDGES);
    CallVoidMethod(window, setAttributes, attributes); // :ThrowsException
    log_exception(env);


    //
    // Hide the system UI
    //

    // We can hide the status bar easily with
    window_flags := AWINDOW_FLAG.FULLSCREEN;
    ANativeActivity_setWindowFlags(android_app.activity, xx window_flags, 0);

    // But we still need to hide the navigation controls and gesture pill which we can do with windowInsetsController.
    // windowInsetsController can also hide the status bar, so no real reason to use the window flags above.
    // Er, can it also set edge to edge?

    // NOTE(Charles): WindowInsetsController is only supported on sdk >= 30. There is WindowInsetsControllerCompat 
    // which can be used on older devices, but requires androidx. There is code in jni_tests that used androidx,
    // it is best avoided though, it requires android project config changes as well as extra native jni code. :AndroidXCompat
    sdk_level := android_app.activity.sdkVersion;
    assert(sdk_level >= 30, "sdk_level == %. A level of >= 30 is required to use this method");

    // From WindowInsets.java
    WindowInsets_Type :: enum_flags {
        FIRST :: 1 << 0;

        STATUS_BARS     :: FIRST;
        NAVIGATION_BARS :: 1 << 1;
        CAPTION_BAR     :: 1 << 2;

        IME :: 1 << 3;

        SYSTEM_GESTURES           :: 1 << 4;
        MANDATORY_SYSTEM_GESTURES :: 1 << 5;
        TAPPABLE_ELEMENT          :: 1 << 6;

        DISPLAY_CUTOUT :: 1 << 7;

        LAST :: 1 << 8;
        SIZE :: 9;
        WINDOW_DECOR :: LAST;
    }

    JAVA_CODE2 :: #string JAVA
        WindowInsetsController windowInsetsController = getWindow().getInsetsController();
        windowInsetsController.hide(WindowInsets.Type.navigationBars());
    JAVA

    insets_to_hide := WindowInsets_Type.NAVIGATION_BARS;
    windowInsetsController := CallObjectMethod(window, getInsetsController);
    CallVoidMethod(windowInsetsController, hide, cast(s32) insets_to_hide); // :ThrowsException
    log_exception(env);

    // NOTE(Charles): This seems to work, but the two calls marked :ThrowsException will trigger an exception: "Only the
    // original thread that created a view hierarchy can touch its views.". As long as we clear the exception everything
    // appears fine. For now I am still logging the exceptions.
    //
    // I could try running on the correct thread, ie the java code to do so (from activity) is:
    //   runOnUiThread(new Runnable() {
    //        public void run() {
    //            myView.setSystemUiVisibility(View.SYSTEM_UI_FLAG_LOW_PROFILE);
    //        }
    //    });
}

create_window :: (width: int, height: int, window_name: string, window_x := 0, window_y := 0, parent: Window_Type = null, background_color_rgb := DEFAULT_WINDOW_CREATION_COLOR, wanted_msaa := DEFAULT_MSAA) -> *Android.ANativeWindow {
    assert(android_app != null, "android_app is null!");
    return android_app.window;
}

// This is the full window size
get_dimensions :: (win: *Android.ANativeWindow, right_handed: bool) -> (x: s32, y: s32, width: s32, height: s32, success := true) {
    width  := Android.ANativeWindow_getWidth(win);
    height := Android.ANativeWindow_getHeight(win);
    return 0, 0, width, height;
}

get_mouse_pointer_position :: (win: *Android.ANativeWindow, right_handed: bool) -> x: int, y: int, success: bool {
    Input :: #import "Input"; // For the simulation of touch input as mouse input. But also, even without that, when Input handles android mouse input the only way to get the mouse position is from the events, no way to directly query like in windows...
    
    if !Input.android_generate_mouse_clicks_for_touch_events  return -1, -1, false;

    touch_x := cast(int) Input.android_last_touch_x;
    touch_y := cast(int) Input.android_last_touch_y;

    // When not touching screen Input sets these to -1, -1. This is counted as a success case, it is like how the Windows
    // version can return x/y from outside the programs window.
    if touch_x == -1 {
        assert(touch_y == -1);
        return touch_x, touch_y, true;
    }

    y := touch_y;
    if right_handed {
        height := Android.ANativeWindow_getHeight(win);
        y = height - touch_y;
    }

    return touch_x, y, true;
}

get_mouse_pointer_position :: inline (right_handed := false) -> x: int, y: int, success: bool {
    assert(android_app != null, "No app!");
    if !android_app.window  return -1, -1, false;
    
    x, y, success := get_mouse_pointer_position(android_app.window, right_handed);
    return x, y, success;
}

#scope_file 

using Android :: #import "Android";
#import "Android/Jni";

// From View.java
SYSTEM_UI_FLAG :: enum_flags {
    VISIBLE                :: 0x0;
    LOW_PROFILE            :: 0x00000001;
    HIDE_NAVIGATION        :: 0x00000002;
    FULLSCREEN             :: 0x00000004;
    LAYOUT_STABLE          :: 0x00000100;
    LAYOUT_HIDE_NAVIGATION :: 0x00000200;
    LAYOUT_FULLSCREEN      :: 0x00000400;
    IMMERSIVE              :: 0x00000800;
    IMMERSIVE_STICKY       :: 0x00001000;
    LIGHT_STATUS_BAR       :: 0x00002000;
    // RESERVED_LEGACY1 :: 0x00004000;
    // RESERVED_LEGACY2 :: 0x00010000;
    LIGHT_NAVIGATION_BAR   :: 0x00000010;
}

// From WindowManager.java
LAYOUT_IN_DISPLAY_CUTOUT_MODE :: enum {
    DEFAULT     :: 0;
    SHORT_EDGES :: 1;
    NEVER       :: 2;
    ALWAYS      :: 3;
}
