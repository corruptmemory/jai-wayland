
#run,stallable build();

// Set by the `compile_only` CLI flag. When true, build_and_run_* compile the
// target but skip running it — turns GUI targets into headless compile gates.
compile_only_flag := false;

build :: () {
    set_working_directory(#filepath);
    options := get_build_options();
    args := options.compile_time_command_line;

    if args.count == 0 {
        build_main(options);
        return;
    }

    for arg: args {
        if arg == {
          case "compile_only";
            // Build-only switch: compile the target workspace(s) but skip the
            // Autorun/run step. Must appear BEFORE the target in the arg list,
            // e.g. `./build.sh - compile_only invaders`. Lets GUI targets
            // (invaders, hello_*) serve as headless compile gates without
            // launching a window that never exits. CLI flag, not env var,
            // per project preference.
            compile_only_flag = true;
          case "test";
            build_tests(options);
          case "gen_test";
            build_gen_tests(options);
          case "generate";
            build_and_run_generate(options);
          case "compile_test";
            build_and_run_test("compile_tests", "compile_tests", "tests/compile_test.jai", "build_tests");
            set_build_options_dc(.{do_output=false});
          case "wire_test";
            build_and_run_test("wire_tests", "wire_tests", "tests/wire_test.jai", "build_tests");
            set_build_options_dc(.{do_output=false});
          case "marshal_test";
            build_and_run_test("marshal_tests", "marshal_tests", "tests/marshal_test.jai", "build_tests");
            set_build_options_dc(.{do_output=false});
          case "unmarshal_test";
            build_and_run_test("unmarshal_tests", "unmarshal_tests", "tests/unmarshal_test.jai", "build_tests");
            set_build_options_dc(.{do_output=false});
          case "hello_globals";
            build_and_run_test("hello_globals", "hello_globals", "examples/hello_globals.jai", "build");
            set_build_options_dc(.{do_output=false});
          case "hello_screens";
            build_and_run_test("hello_screens", "hello_screens", "examples/hello_screens.jai", "build");
            set_build_options_dc(.{do_output=false});
          case "hello_window";
            build_and_run_test("hello_window", "hello_window", "examples/hello_window.jai", "build");
            set_build_options_dc(.{do_output=false});
          case "dump_keymap";
            build_and_run_test("dump_keymap", "dump_keymap", "examples/dump_keymap.jai", "build");
            set_build_options_dc(.{do_output=false});
          case "headless_gl";
            build_and_run_test("headless_gl", "headless_gl", "examples/headless_gl.jai", "build");
            set_build_options_dc(.{do_output=false});
          case "hello_dmabuf";
            build_and_run_test("hello_dmabuf", "hello_dmabuf", "examples/hello_dmabuf.jai", "build");
            set_build_options_dc(.{do_output=false});
          case "hello_gl";
            build_and_run_test("hello_gl", "hello_gl", "examples/hello_gl.jai", "build");
            set_build_options_dc(.{do_output=false});
          case "headless_vulkan";
            build_and_run_test("headless_vulkan", "headless_vulkan", "examples/headless_vulkan.jai", "build");
            set_build_options_dc(.{do_output=false});
          case "headless_vulkan_dmabuf";
            build_and_run_test("headless_vulkan_dmabuf", "headless_vulkan_dmabuf", "examples/headless_vulkan_dmabuf.jai", "build");
            set_build_options_dc(.{do_output=false});
          case "hello_vulkan_dmabuf";
            if !compile_vulkan_example_shaders()  exit(1);
            build_and_run_test("hello_vulkan_dmabuf", "hello_vulkan_dmabuf", "examples/hello_vulkan_dmabuf.jai", "build");
            set_build_options_dc(.{do_output=false});
          case "x11_smoke";
            build_and_run_test("x11_smoke", "x11_smoke", "examples/x11_smoke.jai", "build");
            set_build_options_dc(.{do_output=false});
          case "hello_x11_gl";
            build_and_run_test("hello_x11_gl", "hello_x11_gl", "examples/hello_x11_gl.jai", "build");
            set_build_options_dc(.{do_output=false});
          case "hello_simp";
            // Our own example, but built like invaders: it pulls in the vendored
            // Simp + Window_Creation, whose name-based `wayland` imports must
            // resolve via modules/-first import_path to dedup into one instance.
            build_and_run_test("hello_simp", "hello_simp", "examples/hello_simp.jai", "build", upstream_import_path());
            set_build_options_dc(.{do_output=false});
          case "invaders";
            home := to_string(getenv("HOME"));
            build_and_run_upstream_example(
                workspace_name  = "invaders",
                executable_name = "invaders",
                upstream_dir    = tprint("%/jai/jai/examples/invaders", home),
                source_subpath  = "source/invaders.jai",
            );
            set_build_options_dc(.{do_output=false});
          case;
            compiler_report(tprint("Unknown argument '%'. Valid options: 'compile_only' (build-only modifier, precedes a target), 'test', 'gen_test', 'generate', 'compile_test', 'wire_test', 'marshal_test', 'unmarshal_test', 'hello_screens', 'hello_globals', 'hello_window', 'dump_keymap', 'headless_gl', 'headless_vulkan', 'headless_vulkan_dmabuf', 'hello_dmabuf', 'hello_gl', 'hello_vulkan_dmabuf', 'x11_smoke', 'hello_x11_gl', 'hello_simp', 'invaders'.\n", arg));
        }
    }
}

build_main :: (options: Build_Options) {
    w := compiler_create_workspace("main");
    if !w { print("Workspace creation failed.\n"); return; }

    opts := get_build_options(w);
    set_optimization(*opts, .DEBUG);
    opts.arithmetic_overflow_check = .FATAL;
    opts.output_executable_name = "main";
    opts.output_path = "build";
    make_directory_if_it_does_not_exist("build");
    set_build_options(opts, w);
    add_build_file("src/main.jai", w);

    set_build_options_dc(.{do_output=false});
}

build_and_run_test :: (workspace_name: string, executable_name: string, test_file: string, build_dir: string, import_path: [] string = .[]) {
    w := compiler_create_workspace(workspace_name);
    if !w { print("% workspace creation failed.\n", workspace_name); return; }

    opts := get_build_options(w);
    set_optimization(*opts, .DEBUG);
    opts.arithmetic_overflow_check = .FATAL;
    opts.output_executable_name = executable_name;
    opts.output_path = build_dir;
    // Targets that pull in the vendored Simp/Window_Creation stack (which import
    // `wayland` by NAME so the two share one instance) need `modules/` first on
    // the import path — same as the upstream-example build. Existing callers
    // pass nothing and keep the compiler's default path.
    if import_path.count  opts.import_path = import_path;
    make_directory_if_it_does_not_exist(build_dir);
    set_build_options(opts, w);

    compiler_begin_intercept(w);
    add_build_file(test_file, w);
    while true {
        message := compiler_wait_for_message();
        if message.kind == {
            case .COMPLETE;
            mc := cast(*Message_Complete) message;
            if mc.error_code != .NONE  exit(1);
            break;
        }
    }
    compiler_end_intercept(w);
    if !compile_only_flag  Autorun.run_build_result_of_workspace(w);
}

upstream_import_path :: () -> [] string {
    home := to_string(getenv("HOME"));
    return string.[
        "modules",                              // ours wins
        tprint("%/jai/jai/modules", home),      // stdlib for everything else
    ];
}

build_and_run_upstream_example :: (
    workspace_name: string,
    executable_name: string,
    upstream_dir: string,
    source_subpath: string,
) {
    w := compiler_create_workspace(workspace_name);
    if !w  { print("% workspace creation failed.\n", workspace_name); return; }

    opts := get_build_options(w);
    set_optimization(*opts, .DEBUG);
    opts.arithmetic_overflow_check = .FATAL;
    opts.output_executable_name = executable_name;
    opts.output_path = "build";
    opts.import_path = upstream_import_path();
    make_directory_if_it_does_not_exist("build");
    set_build_options(opts, w);

    compiler_begin_intercept(w);
    add_build_file(tprint("%/%", upstream_dir, source_subpath), w);
    while true {
        message := compiler_wait_for_message();
        if message.kind == {
            case .COMPLETE;
                mc := cast(*Message_Complete) message;
                if mc.error_code != .NONE  exit(1);
                break;
        }
    }
    compiler_end_intercept(w);

    // invaders (and similar upstream examples) compute their data path from
    // get_path_of_running_executable() — i.e. they look for `data/` next to
    // the binary, not next to the source. We build the binary into
    // jai-wayland/build/, so we need to plant a `data` symlink there that
    // points at the upstream example's real data folder. Idempotent.
    ensure_upstream_data_symlink(upstream_dir);

    if compile_only_flag  return;

    binary := tprint("%/build/%", #filepath, executable_name);
    result := run_command(binary, working_directory = upstream_dir);
    if result.exit_code != 0  exit(result.exit_code);
}

ensure_upstream_data_symlink :: (upstream_dir: string) {
    src := tprint("%/data", upstream_dir);
    if !file_exists(src) {
        // Nothing to symlink; upstream example has no data folder.
        return;
    }

    dst := tprint("%/build/data", #filepath);
    if file_exists(dst) {
        // Already present (symlink, directory, whatever) — assume good.
        return;
    }

    src_c := temp_c_string(src);
    dst_c := temp_c_string(dst);
    rc := symlink(src_c, dst_c);
    if rc != 0 {
        print("WARNING: could not create symlink % -> % (errno %)\n", dst, src, errno());
    }
}

build_tests :: (options: Build_Options) {
    build_and_run_test("xml_tests", "xml_tests", "tests/xml_test.jai", "build_tests");
    set_build_options_dc(.{do_output=false});
}

build_gen_tests :: (options: Build_Options) {
    build_and_run_test("gen_tests", "gen_tests", "tests/generator_test.jai", "build_tests");
    set_build_options_dc(.{do_output=false});
}

build_and_run_generate :: (options: Build_Options) {
    build_and_run_test("generator", "generator", "src/generate_main.jai", "build");
    set_build_options_dc(.{do_output=false});
}

compile_vulkan_example_shaders :: () -> bool {
    make_directory_if_it_does_not_exist("build/shaders", recursive = true);

    specs := Shader_Spec.[
        .{source = "examples/shaders/hello_vulkan_triangle.vert", output = "build/shaders/hello_vulkan_triangle.vert.spv"},
        .{source = "examples/shaders/hello_vulkan_triangle.frag", output = "build/shaders/hello_vulkan_triangle.frag.spv"},
    ];

    for specs {
        result := run_command("glslc", it.source, "-o", it.output);
        if result.exit_code != 0 {
            compiler_report(tprint("Shader compilation failed: glslc % -o %\n", it.source, it.output));
            return false;
        }
    }

    return true;
}

Shader_Spec :: struct {
    source: string;
    output: string;
}

#import "Basic";
#import "Compiler";
#import "File";
#import "File_Utilities";
#import "POSIX";
#import "Process";
Autorun :: #import "Autorun";
