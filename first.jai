
#run,stallable build();

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
          case;
            compiler_report(tprint("Unknown argument '%'. Valid options: 'test', 'gen_test', 'generate', 'compile_test', 'wire_test', 'marshal_test', 'unmarshal_test', 'hello_screens', 'hello_globals', 'hello_window', 'dump_keymap', 'headless_gl', 'headless_vulkan', 'headless_vulkan_dmabuf', 'hello_dmabuf', 'hello_gl', 'hello_vulkan_dmabuf', 'x11_smoke', 'hello_x11_gl'.\n", arg));
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

build_and_run_test :: (workspace_name: string, executable_name: string, test_file: string, build_dir: string) {
    w := compiler_create_workspace(workspace_name);
    if !w { print("% workspace creation failed.\n", workspace_name); return; }

    opts := get_build_options(w);
    set_optimization(*opts, .DEBUG);
    opts.arithmetic_overflow_check = .FATAL;
    opts.output_executable_name = executable_name;
    opts.output_path = build_dir;
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
    Autorun.run_build_result_of_workspace(w);
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

    binary := tprint("%/build/%", #filepath, executable_name);
    result := run_command(binary, working_directory = upstream_dir);
    if result.exit_code != 0  exit(result.exit_code);
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
#import "POSIX";
#import "Process";
Autorun :: #import "Autorun";
