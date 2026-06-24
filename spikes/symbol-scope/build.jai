// Metaprogram for the symbol-scope spike.
//
// What it answers for first.jai (eventually for game-bootstrap's first.jai):
//   what, if anything, must the build set so a Jai EXECUTABLE exports wl_*
//   symbols into .dynsym such that a dlopened ICD binds to OUR definitions?
//
// PASS 1 hypothesis: `#program_export` on the procedure is sufficient on its
// own (it explicitly marks the symbol for export, unlike -rdynamic which dumps
// everything). If `nm -D build/spike` does NOT list wl_proxy_get_version,
// uncomment the additional_linker_arguments line below (Jai links via bundled
// lld, so the flag is lld's `--export-dynamic`, not gcc's `-rdynamic`).

#import "Basic";
#import "Compiler";

DIR :: #filepath;

build :: () {
    w := compiler_create_workspace("symbol-scope-spike");

    options := get_build_options(w);
    options.output_executable_name = "spike";
    options.output_path            = tprint("%/build", DIR);
    set_optimization(*options, .DEBUG);

    // PASS 2 (only if nm -D shows the symbol missing):
    // options.additional_linker_arguments = string.["--export-dynamic"];

    set_build_options(options, w);

    add_build_file(tprint("%/spike.jai", DIR), w);

    set_build_options_dc(.{do_output=false});  // no executable for THIS workspace
}

#run build();
