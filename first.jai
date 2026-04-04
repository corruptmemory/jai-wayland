
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
          case;
            compiler_report(tprint("Unknown argument '%'. Valid options: 'test', 'gen_test', 'generate', 'compile_test', 'wire_test', 'marshal_test'.\n", arg));
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

#import "Basic";
#import "Compiler";
#import "File";
Autorun :: #import "Autorun";
