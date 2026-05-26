// hello_x11_gl — X11 + GLX + runtime-loaded GL spinning triangle smoke.
//
// This is intentionally separate from the Wayland path. It proves the vendored
// dynamic X11 binding can create an X window, create a GLX context, load GL
// entry points through glXGetProcAddress, and render without link-time X11/GLX.

X11 :: #import,dir "../modules/X11";
GL  :: #import,dir "../modules/GL";

#import "Basic";
#import "POSIX";

DEFAULT_WIDTH  :: 640;
DEFAULT_HEIGHT :: 480;

GLX_Create_Context_Attribs_ARB :: #type (
    display: *X11.Display,
    config: X11.GLXFBConfig,
    share_context: X11.GLXContext,
    direct: s32,
    attrib_list: *s32
) -> X11.GLXContext #c_call;

main :: () {
    assert(X11.init_x11(), "Could not load libX11 at runtime");
    assert(X11.init_glx(), "Could not load GLX at runtime");

    X11.XInitThreads();

    display := X11.XOpenDisplay(null);
    if !display {
        print("Could not open X11 display. Is DISPLAY set?\n");
        return;
    }
    defer X11.XCloseDisplay(display);

    window, visual_info, fb_config, colormap, ok := create_x11_gl_window(display, DEFAULT_WIDTH, DEFAULT_HEIGHT, "hello_x11_gl");
    if !ok {
        print("Could not create X11 GL window\n");
        return;
    }
    defer {
        X11.XDestroyWindow(display, window);
        X11.XFreeColormap(display, colormap);
        X11.XFree(visual_info);
    }

    wm_delete := X11.XInternAtom(display, "WM_DELETE_WINDOW", X11.False);
    X11.XSetWMProtocols(display, window, *wm_delete, 1);
    X11.XMapWindow(display, window);
    X11.XFlush(display);

    gl_context := create_glx_context(display, fb_config, visual_info);
    if !gl_context {
        print("Could not create GLX context\n");
        return;
    }
    defer X11.glXDestroyContext(display, gl_context);

    if X11.glXMakeCurrent(display, cast(X11.GLXDrawable) window, gl_context) == X11.False {
        print("glXMakeCurrent failed\n");
        return;
    }
    defer X11.glXMakeCurrent(display, 0, null);

    if !GL.gl_load(X11.glXGetProcAddress) {
        print("Could not load required GL entry points through GLX\n");
        return;
    }

    major, minor := GL.gl_get_version();
    print("GL %.% via X11/GLX\n", major, minor);

    tri: Triangle;
    if !init_triangle(*tri) {
        print("Triangle setup failed\n");
        return;
    }
    defer destroy_triangle(*tri);

    width:  s32 = DEFAULT_WIDTH;
    height: s32 = DEFAULT_HEIGHT;
    rotation_start := monotonic_seconds();
    frame_limit := frame_limit_from_env();
    frames_drawn: u32 = 0;
    quit := false;

    if frame_limit > 0 {
        print("hello_x11_gl: bounded X11/GLX triangle smoke (% frames).\n", frame_limit);
    } else {
        print("hello_x11_gl: animating. Keys: r/g/b color schemes, q/Escape quit. Click cycles scheme.\n");
    }

    while !quit {
        while X11.XPending(display) > 0 {
            event: X11.XEvent;
            X11.XNextEvent(display, *event);

            if event.type == X11.ClientMessage {
                if cast(X11.Atom) event.xclient.data.l[0] == wm_delete {
                    quit = true;
                }
            } else if event.type == X11.ConfigureNotify {
                width = ifx event.xconfigure.width > 0 then event.xconfigure.width else 1;
                height = ifx event.xconfigure.height > 0 then event.xconfigure.height else 1;
            } else if event.type == X11.KeyPress {
                keysym := X11.XLookupKeysym(*event.xkey, 0);
                if keysym == X11.XK_q || keysym == X11.XK_Escape {
                    quit = true;
                } else if keysym == X11.XK_r {
                    apply_color_scheme(*tri, 1);
                    print("Color scheme: red\n");
                } else if keysym == X11.XK_g {
                    apply_color_scheme(*tri, 2);
                    print("Color scheme: green\n");
                } else if keysym == X11.XK_b {
                    apply_color_scheme(*tri, 3);
                    print("Color scheme: blue\n");
                }
            } else if event.type == X11.ButtonPress {
                if event.xbutton.button == X11.Button1 {
                    next_scheme := (tri.scheme + 1) % SCHEME_COUNT;
                    apply_color_scheme(*tri, next_scheme);
                    print("Click at %, %; color scheme %\n", event.xbutton.x, event.xbutton.y, next_scheme);
                }
            }
        }

        paint_gl_frame(tri, width, height, rotation_angle(rotation_start));
        X11.glXSwapBuffers(display, cast(X11.GLXDrawable) window);
        frames_drawn += 1;
        if frame_limit > 0 && frames_drawn >= frame_limit {
            print("Frame limit reached (% frames drawn).\n", frames_drawn);
            quit = true;
        }
    }
}

create_x11_gl_window :: (display: *X11.Display, width: s32, height: s32, title: string) -> X11.Window, *X11.XVisualInfo, X11.GLXFBConfig, X11.Colormap, bool {
    screen := X11.DefaultScreen(display);
    root := X11.DefaultRootWindow(display);

    fb_attribs := s32.[
        X11.GLX_X_RENDERABLE,   X11.True,
        X11.GLX_DRAWABLE_TYPE,  X11.GLX_WINDOW_BIT,
        X11.GLX_RENDER_TYPE,    X11.GLX_RGBA_BIT,
        X11.GLX_X_VISUAL_TYPE,  X11.GLX_TRUE_COLOR,
        X11.GLX_RED_SIZE,       8,
        X11.GLX_GREEN_SIZE,     8,
        X11.GLX_BLUE_SIZE,      8,
        X11.GLX_ALPHA_SIZE,     8,
        X11.GLX_DEPTH_SIZE,     24,
        X11.GLX_STENCIL_SIZE,   8,
        X11.GLX_DOUBLEBUFFER,   X11.True,
        X11.None,
    ];

    fb_count: s32;
    configs := X11.glXChooseFBConfig(display, screen, fb_attribs.data, *fb_count);
    if !configs || fb_count <= 0  return 0, null, null, 0, false;
    defer X11.XFree(configs);

    chosen_fb_config := configs[0];
    visual_info := X11.glXGetVisualFromFBConfig(display, chosen_fb_config);
    if !visual_info  return 0, null, null, 0, false;

    colormap := X11.XCreateColormap(display, root, visual_info.visual, X11.AllocNone);
    if colormap == X11.None {
        X11.XFree(visual_info);
        return 0, null, null, 0, false;
    }

    swa: X11.XSetWindowAttributes;
    swa.colormap = colormap;
    swa.event_mask = X11.ExposureMask
                   | X11.StructureNotifyMask
                   | X11.KeyPressMask
                   | X11.ButtonPressMask;

    window := X11.XCreateWindow(
        display,
        root,
        100,
        100,
        cast(u32) width,
        cast(u32) height,
        0,
        visual_info.depth,
        X11.InputOutput,
        visual_info.visual,
        cast(u64) (X11.CWColormap | X11.CWEventMask),
        *swa
    );
    if window == X11.None {
        X11.XFreeColormap(display, colormap);
        X11.XFree(visual_info);
        return 0, null, null, 0, false;
    }

    X11.XStoreName(display, window, temp_c_string(title));
    return window, visual_info, chosen_fb_config, colormap, true;
}

create_glx_context :: (display: *X11.Display, fb_config: X11.GLXFBConfig, visual_info: *X11.XVisualInfo) -> X11.GLXContext {
    create_context_attribs: GLX_Create_Context_Attribs_ARB = xx X11.glXGetProcAddress("glXCreateContextAttribsARB");
    if create_context_attribs {
        attribs := s32.[
            X11.GLX_CONTEXT_MAJOR_VERSION_ARB, 3,
            X11.GLX_CONTEXT_MINOR_VERSION_ARB, 3,
            X11.GLX_CONTEXT_PROFILE_MASK_ARB,  X11.GLX_CONTEXT_CORE_PROFILE_BIT_ARB,
            0,
        ];
        gl_context := create_context_attribs(display, fb_config, null, X11.True, attribs.data);
        if gl_context  return gl_context;
    }

    return X11.glXCreateContext(display, visual_info, null, X11.True);
}

ROTATION_RADIANS_PER_SECOND :: 1.2;

monotonic_seconds :: () -> float64 {
    ts: timespec;
    if clock_gettime(.MONOTONIC, *ts) != 0  return 0;
    return cast(float64) ts.tv_sec + cast(float64) ts.tv_nsec / 1000000000.0;
}

rotation_angle :: (start_time: float64) -> float {
    return cast(float) ((monotonic_seconds() - start_time) * ROTATION_RADIANS_PER_SECOND);
}

frame_limit_from_env :: () -> u32 {
    value_ptr := getenv("JAI_WAYLAND_X11_GL_FRAMES");
    if value_ptr == null  return 0;

    text := to_string(value_ptr);
    if text.count == 0  return 0;

    value: u32 = 0;
    for text {
        if it < #char "0" || it > #char "9"  break;
        value = value * 10 + cast(u32)(it - #char "0");
    }

    return value;
}

VS_SRC :: #string GLSL
#version 330 core
layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec3 a_col;
uniform float u_angle;
out vec3 v_col;
void main() {
    float c = cos(u_angle);
    float s = sin(u_angle);
    vec2 r = vec2(c * a_pos.x - s * a_pos.y,
                  s * a_pos.x + c * a_pos.y);
    gl_Position = vec4(r, 0.0, 1.0);
    v_col = a_col;
}
GLSL

FS_SRC :: #string GLSL
#version 330 core
in vec3 v_col;
out vec4 frag;
void main() {
    frag = vec4(v_col, 1.0);
}
GLSL

Triangle :: struct {
    program: u32;
    vao:     u32;
    vbo:     u32;
    u_angle: GL.GLint;
    scheme:  int = 0;
}

COLOR_SCHEMES :: float.[
    1.0, 0.2, 0.2,    0.2, 1.0, 0.2,    0.2, 0.2, 1.0,
    1.0, 0.3, 0.1,    0.9, 0.6, 0.2,    0.8, 0.2, 0.2,
    0.1, 1.0, 0.4,    0.2, 0.8, 0.6,    0.4, 1.0, 0.7,
    0.3, 0.4, 1.0,    0.6, 0.3, 0.9,    0.2, 0.2, 0.8,
];

SCHEME_COUNT      :: 4;
VERTICES_PER_TRI  :: 3;
FLOATS_PER_SCHEME :: VERTICES_PER_TRI * 3;

init_triangle :: (tri: *Triangle) -> bool {
    vs, vs_ok := compile_shader(GL.GL_VERTEX_SHADER, VS_SRC);
    if !vs_ok  return false;
    defer GL.glDeleteShader(vs);

    fs, fs_ok := compile_shader(GL.GL_FRAGMENT_SHADER, FS_SRC);
    if !fs_ok  return false;
    defer GL.glDeleteShader(fs);

    tri.program = GL.glCreateProgram();
    GL.glAttachShader(tri.program, vs);
    GL.glAttachShader(tri.program, fs);
    GL.glLinkProgram(tri.program);

    linked: GL.GLint;
    GL.glGetProgramiv(tri.program, GL.GL_LINK_STATUS, *linked);
    if linked != GL.GL_TRUE {
        log_buf: [1024] u8;
        GL.glGetProgramInfoLog(tri.program, log_buf.count, null, log_buf.data);
        print("Program link failed: %\n", cast(string) log_buf);
        return false;
    }

    tri.u_angle = GL.glGetUniformLocation(tri.program, "u_angle".data);

    GL.glGenVertexArrays(1, *tri.vao);
    GL.glBindVertexArray(tri.vao);

    GL.glGenBuffers(1, *tri.vbo);
    GL.glBindBuffer(GL.GL_ARRAY_BUFFER, tri.vbo);
    upload_triangle_verts(tri, 0);

    stride: GL.GLsizei = 5 * size_of(float);
    GL.glVertexAttribPointer(0, 2, GL.GL_FLOAT, GL.GL_FALSE, stride, cast(*void) 0);
    GL.glEnableVertexAttribArray(0);
    GL.glVertexAttribPointer(1, 3, GL.GL_FLOAT, GL.GL_FALSE, stride, cast(*void) (2 * size_of(float)));
    GL.glEnableVertexAttribArray(1);

    GL.glBindVertexArray(0);
    GL.glBindBuffer(GL.GL_ARRAY_BUFFER, 0);
    return true;
}

destroy_triangle :: (tri: *Triangle) {
    if tri.vbo      GL.glDeleteBuffers(1, *tri.vbo);
    if tri.vao      GL.glDeleteVertexArrays(1, *tri.vao);
    if tri.program  GL.glDeleteProgram(tri.program);
}

upload_triangle_verts :: (tri: *Triangle, scheme: int) {
    SQRT3_OVER_2: float : 0.8660254;
    cols := COLOR_SCHEMES.data + scheme * FLOATS_PER_SCHEME;
    verts := float.[
         0.0,                  0.7,   cols[0], cols[1], cols[2],
        -SQRT3_OVER_2 * 0.7,  -0.35,  cols[3], cols[4], cols[5],
         SQRT3_OVER_2 * 0.7,  -0.35,  cols[6], cols[7], cols[8],
    ];

    GL.glBindBuffer(GL.GL_ARRAY_BUFFER, tri.vbo);
    GL.glBufferData(GL.GL_ARRAY_BUFFER, verts.count * size_of(float), verts.data, GL.GL_STATIC_DRAW);
}

apply_color_scheme :: (tri: *Triangle, scheme: int) {
    tri.scheme = scheme;
    upload_triangle_verts(tri, scheme);
}

compile_shader :: (kind: GL.GLenum, src: string) -> sh: u32, ok: bool {
    sh := GL.glCreateShader(kind);
    src_data := src.data;
    src_len: GL.GLint = cast(GL.GLint) src.count;
    GL.glShaderSource(sh, 1, *src_data, *src_len);
    GL.glCompileShader(sh);

    status: GL.GLint;
    GL.glGetShaderiv(sh, GL.GL_COMPILE_STATUS, *status);
    if status != GL.GL_TRUE {
        log_buf: [1024] u8;
        GL.glGetShaderInfoLog(sh, log_buf.count, null, log_buf.data);
        print("Shader compile failed: %\n", cast(string) log_buf);
        GL.glDeleteShader(sh);
        return 0, false;
    }

    return sh, true;
}

paint_gl_frame :: (tri: Triangle, width: s32, height: s32, angle: float) {
    GL.glBindFramebuffer(GL.GL_FRAMEBUFFER, 0);
    GL.glViewport(0, 0, width, height);
    GL.glClearColor(0.05, 0.05, 0.08, 1.0);
    GL.glClear(GL.GL_COLOR_BUFFER_BIT);

    GL.glUseProgram(tri.program);
    GL.glUniform1f(tri.u_angle, angle);
    GL.glBindVertexArray(tri.vao);
    GL.glDrawArrays(GL.GL_TRIANGLES, 0, 3);
    GL.glBindVertexArray(0);
    GL.glUseProgram(0);
}
