# Code Generator Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** A standalone Jai tool that reads Wayland protocol XML and emits idiomatic Jai source files with typed interfaces, opcode constants, event tagged unions, and stub request functions.

**Architecture:** The generator (`src/generator.jai`) reuses the Phase 1 parser (`parse_protocol()`) to get `Protocol` structs, then walks them emitting `.jai` files into `modules/wayland/`. Each protocol gets a directory, each interface gets a file. A `#load` chain stitches everything into one importable module.

**Tech Stack:** Jai (Basic, File, String, File_Utilities), existing `xml.jai` + `protocol.jai` from Phase 1.

---

## Context for Implementer

### Project Layout

```
jai-wayland/
  first.jai           — build metaprogram (creates workspaces for main, tests)
  build.sh            — delegates to: ~/jai/jai/bin/jai-linux first.jai "$@"
  src/
    xml.jai            — zero-copy XML pull parser
    protocol.jai       — Protocol/Interface/Message/Arg/Enum_Def data model + parser
    main.jai           — validation harness
  tests/
    xml_test.jai       — 22 tests
  vendor/
    wayland-protocols/ — 59 XML files (core/, stable/, staging/, unstable/)
```

### Build & Test

```bash
./build.sh            # builds src/main.jai → build/main
./build.sh - test     # builds+runs tests/xml_test.jai → build_tests/xml_tests
```

### Key APIs You'll Use

**Parse XML:** `parse_protocol(xml_source: string) -> Protocol` (from `src/protocol.jai`)
**Read file:** `read_entire_file(path: string) -> string, bool` (from `#import "File"`)
**Write file:** `write_entire_file(name: string, builder: *String_Builder) -> bool` (from `#import "File"`)
**Build string:** `print_to_builder(*sb, format, args..)` then `write_entire_file(path, *sb)` (from `#import "Basic"`)
**Make directory:** `make_directory_if_it_does_not_exist(path: string)` (from `#import "File"`)
**Walk files:** `visit_files(dir, recursive, userdata, callback)` (from `#import "File_Utilities"`)

### Naming Convention Transforms

| XML | Jai | Example |
|-----|-----|---------|
| `wl_surface` (interface) | `Wl_Surface` (struct) | capitalize each segment |
| `wl_surface` + `attach` (request) | `WL_SURFACE_ATTACH` (opcode constant) | uppercase interface + request |
| `wl_surface` + `attach` (function) | `wl_surface_attach` (function) | prefix interface name |
| `wl_surface` + `error` (enum) | `Wl_Surface_Error` (enum type) | capitalize interface + enum |
| `invalid_scale` (entry) | `INVALID_SCALE` (enum value) | uppercase |
| `wl_surface` + `enter` (event) | `.ENTER` in tagged union | uppercase in event kind enum |

### Jai Language Patterns

**MANDATORY:** Invoke the `jai-language` skill before writing any Jai code.

**String_Builder for output:**
```jai
sb: String_Builder;
print_to_builder(*sb, "// Generated file\n");
print_to_builder(*sb, "Foo :: struct { id: u32; }\n");
write_entire_file("output.jai", *sb);
```

**Tagged union (beta 0.2.025):**
```jai
My_Kind :: enum u8 { A :: 0; B :: 1; }
My_Union :: union kind: My_Kind {
    .A ,, x: s32;
    .B ,, y: string;
}
```

**enum_flags for bitfields:**
```jai
Flags :: enum_flags u32 { READ :: 1; WRITE :: 2; EXEC :: 4; }
```

### Test Pattern (from this project)

Named test procedures with `assert()` + `print("  PASS: ...\n")`, called from `main()`:
```jai
test_foo :: () {
    // ... test logic ...
    assert(condition, "message");
    print("  PASS: test_foo\n");
}

main :: () {
    print("Running tests...\n\n");
    print("group name:\n");
    test_foo();
    print("\nAll tests passed.\n");
}
```

---

## Task 1: Naming Utilities

String transformation functions needed by all later tasks.

**Files:**
- Create: `src/generator.jai`
- Create: `tests/generator_test.jai`
- Modify: `first.jai` (add generator test workspace)

### Step 1: Write failing tests for naming utilities

Create `tests/generator_test.jai`:

```jai

#import "Basic";
#import "String";
#load "../src/generator.jai";

// ── Naming utility tests ──

test_to_jai_type_name :: () {
    assert(to_jai_type_name("wl_surface") == "Wl_Surface");
    assert(to_jai_type_name("xdg_toplevel") == "Xdg_Toplevel");
    assert(to_jai_type_name("wl_shm") == "Wl_Shm");
    assert(to_jai_type_name("zwp_linux_dmabuf_v1") == "Zwp_Linux_Dmabuf_V1");
    print("  PASS: test_to_jai_type_name\n");
}

test_to_upper_snake :: () {
    assert(to_upper_snake("wl_surface") == "WL_SURFACE");
    assert(to_upper_snake("xdg_toplevel") == "XDG_TOPLEVEL");
    assert(to_upper_snake("damage_buffer") == "DAMAGE_BUFFER");
    print("  PASS: test_to_upper_snake\n");
}

test_opcode_name :: () {
    assert(opcode_name("wl_surface", "attach") == "WL_SURFACE_ATTACH");
    assert(opcode_name("xdg_toplevel", "set_title") == "XDG_TOPLEVEL_SET_TITLE");
    print("  PASS: test_opcode_name\n");
}

test_to_jai_enum_name :: () {
    assert(to_jai_enum_name("wl_surface", "error") == "Wl_Surface_Error");
    assert(to_jai_enum_name("wl_shm", "format") == "Wl_Shm_Format");
    assert(to_jai_enum_name("wl_output", "subpixel") == "Wl_Output_Subpixel");
    print("  PASS: test_to_jai_enum_name\n");
}

test_resolve_cross_interface_enum :: () {
    // "wl_shm.format" -> "Wl_Shm_Format"
    assert(resolve_enum_type("wl_shm.format", "wl_shm_pool") == "Wl_Shm_Format");
    // "error" (no dot) within wl_display -> "Wl_Display_Error"
    assert(resolve_enum_type("error", "wl_display") == "Wl_Display_Error");
    print("  PASS: test_resolve_cross_interface_enum\n");
}

main :: () {
    print("Running generator tests...\n\n");

    print("naming utilities:\n");
    test_to_jai_type_name();
    test_to_upper_snake();
    test_opcode_name();
    test_to_jai_enum_name();
    test_resolve_cross_interface_enum();

    print("\nAll tests passed.\n");
}
```

### Step 2: Run tests to verify they fail

```bash
./build.sh - gen_test
```

This will fail because `first.jai` doesn't know about `gen_test` yet, and `src/generator.jai` doesn't exist. That's expected.

### Step 3: Add gen_test to first.jai and create stub generator.jai

Modify `first.jai` — add `"gen_test"` case in the arg loop:

```jai
case "gen_test";
    build_and_run_test("gen_tests", "gen_tests", "tests/generator_test.jai", "build_tests");
```

Create `src/generator.jai` with the naming functions:

```jai
// ── Code generator for Wayland protocol bindings ──

// ── Naming utilities ──

// "wl_surface" -> "Wl_Surface"
to_jai_type_name :: (name: string) -> string {
    sb: String_Builder;
    sb.allocator = temp;
    capitalize_next := true;
    for 0..name.count-1 {
        c := name[it];
        if c == #char "_" {
            append(*sb, "_");
            capitalize_next = true;
        } else if capitalize_next {
            if c >= #char "a" && c <= #char "z"
                append(*sb, cast(u8)(c - 32));
            else
                append(*sb, c);
            capitalize_next = false;
        } else {
            append(*sb, c);
        }
    }
    return builder_to_string(*sb,, allocator = temp);
}

// "wl_surface" -> "WL_SURFACE"
to_upper_snake :: (name: string) -> string {
    sb: String_Builder;
    sb.allocator = temp;
    for 0..name.count-1 {
        c := name[it];
        if c >= #char "a" && c <= #char "z"
            append(*sb, cast(u8)(c - 32));
        else
            append(*sb, c);
    }
    return builder_to_string(*sb,, allocator = temp);
}

// "wl_surface", "attach" -> "WL_SURFACE_ATTACH"
opcode_name :: (interface_name: string, message_name: string) -> string {
    return tprint("%_%", to_upper_snake(interface_name), to_upper_snake(message_name));
}

// "wl_surface", "error" -> "Wl_Surface_Error"
to_jai_enum_name :: (interface_name: string, enum_name: string) -> string {
    return tprint("%_%", to_jai_type_name(interface_name), to_jai_type_name(enum_name));
}

// "wl_shm.format" (cross-interface) -> "Wl_Shm_Format"
// "error" (local) within "wl_display" -> "Wl_Display_Error"
resolve_enum_type :: (enum_ref: string, current_interface: string) -> string {
    dot := -1;
    for 0..enum_ref.count-1 {
        if enum_ref[it] == #char "." { dot = it; break; }
    }
    if dot >= 0 {
        iface_part: string;
        iface_part.data = enum_ref.data;
        iface_part.count = dot;
        enum_part: string;
        enum_part.data = enum_ref.data + dot + 1;
        enum_part.count = enum_ref.count - dot - 1;
        return to_jai_enum_name(iface_part, enum_part);
    }
    return to_jai_enum_name(current_interface, enum_ref);
}
```

### Step 4: Run tests to verify they pass

```bash
./build.sh - gen_test
```

Expected: All 5 tests pass.

### Step 5: Commit

```bash
git add src/generator.jai tests/generator_test.jai first.jai
git commit -m "feat: naming utilities for code generator (to_jai_type_name, to_upper_snake, etc.)"
```

---

## Task 2: Shared Types File Generation

Generate `modules/wayland/types.jai` with shared type definitions.

**Files:**
- Modify: `src/generator.jai`
- Modify: `tests/generator_test.jai`

### Step 1: Write failing test

Add to `tests/generator_test.jai`:

```jai
#import "File";

test_generate_types_file :: () {
    result := generate_types_file();
    // Check key type definitions are present
    assert(contains(result, "Interface_Descriptor :: struct"), "Missing Interface_Descriptor");
    assert(contains(result, "Wire_Arg_Type :: enum u8"), "Missing Wire_Arg_Type");
    assert(contains(result, "Fixed :: struct"), "Missing Fixed");
    assert(contains(result, "fixed_from_float"), "Missing fixed_from_float");
    assert(contains(result, "fixed_to_float"), "Missing fixed_to_float");
    print("  PASS: test_generate_types_file\n");
}
```

Add the call in `main()` under a new group:

```jai
print("\nshared types:\n");
test_generate_types_file();
```

### Step 2: Run tests to verify failure

```bash
./build.sh - gen_test
```

Expected: FAIL — `generate_types_file` not found.

### Step 3: Implement generate_types_file

Add to `src/generator.jai`:

```jai
generate_types_file :: () -> string {
    sb: String_Builder;
    sb.allocator = temp;

    print_to_builder(*sb, "// Auto-generated by jai-wayland code generator. Do not edit.\n\n");

    print_to_builder(*sb, #string DONE
// Interface metadata for runtime dispatch
Interface_Descriptor :: struct {
    name: string;
    version: u32;
    request_count: u32;
    event_count: u32;
}

// Wire protocol argument types
Wire_Arg_Type :: enum u8 {
    INT;
    UINT;
    FIXED;
    STRING;
    OBJECT;
    NEW_ID;
    ARRAY;
    FD;
}

// Fixed-point 24.8 type used by the Wayland wire protocol
Fixed :: struct {
    raw: s32;
}

fixed_from_float :: (v: float64) -> Fixed {
    return .{ raw = cast(s32)(v * 256.0) };
}

fixed_to_float :: (f: Fixed) -> float64 {
    return cast(float64) f.raw / 256.0;
}
DONE);

    return builder_to_string(*sb,, allocator = temp);
}
```

### Step 4: Run tests to verify they pass

```bash
./build.sh - gen_test
```

Expected: All tests pass.

### Step 5: Commit

```bash
git add src/generator.jai tests/generator_test.jai
git commit -m "feat: generate shared types file (Interface_Descriptor, Fixed, Wire_Arg_Type)"
```

---

## Task 3: Enum Generation

Generate Jai enum definitions from `Enum_Def` structs, handling both regular and bitfield enums.

**Files:**
- Modify: `src/generator.jai`
- Modify: `tests/generator_test.jai`

### Step 1: Write failing tests

Add to `tests/generator_test.jai`:

```jai
#load "../src/xml.jai";
#load "../src/protocol.jai";

test_generate_enum_regular :: () {
    e: Enum_Def;
    e.name = "error";
    e.description.summary = "surface errors";
    entry1: Entry; entry1.name = "invalid_scale"; entry1.value = 0; entry1.summary = "buffer scale is not positive";
    entry2: Entry; entry2.name = "invalid_transform"; entry2.value = 1; entry2.summary = "buffer transform is not valid";
    array_add(*e.entries, entry1);
    array_add(*e.entries, entry2);

    result := generate_enum(*e, "wl_surface");
    assert(contains(result, "Wl_Surface_Error :: enum u32"), "Missing enum declaration, got:\n%", result);
    assert(contains(result, "INVALID_SCALE"), "Missing INVALID_SCALE");
    assert(contains(result, "INVALID_TRANSFORM"), "Missing INVALID_TRANSFORM");
    assert(contains(result, ":: 0"), "Missing value 0");
    assert(contains(result, ":: 1"), "Missing value 1");
    assert(contains(result, "surface errors"), "Missing summary comment");
    print("  PASS: test_generate_enum_regular\n");
}

test_generate_enum_bitfield :: () {
    e: Enum_Def;
    e.name = "capability";
    e.bitfield = true;
    entry1: Entry; entry1.name = "pointer"; entry1.value = 1;
    entry2: Entry; entry2.name = "keyboard"; entry2.value = 2;
    entry3: Entry; entry3.name = "touch"; entry3.value = 4;
    array_add(*e.entries, entry1);
    array_add(*e.entries, entry2);
    array_add(*e.entries, entry3);

    result := generate_enum(*e, "wl_seat");
    assert(contains(result, "enum_flags u32"), "Bitfield should use enum_flags, got:\n%", result);
    assert(contains(result, "POINTER"), "Missing POINTER");
    assert(contains(result, ":: 1"), "Missing value 1");
    print("  PASS: test_generate_enum_bitfield\n");
}

test_generate_enum_hex_values :: () {
    e: Enum_Def;
    e.name = "format";
    entry1: Entry; entry1.name = "argb8888"; entry1.value = 0;
    entry2: Entry; entry2.name = "c8"; entry2.value = 0x20203843;
    array_add(*e.entries, entry1);
    array_add(*e.entries, entry2);

    result := generate_enum(*e, "wl_shm");
    // Large values should be emitted as hex for readability
    assert(contains(result, "0x20203843"), "Large value should be hex, got:\n%", result);
    print("  PASS: test_generate_enum_hex_values\n");
}
```

Add calls in `main()`:

```jai
print("\nenum generation:\n");
test_generate_enum_regular();
test_generate_enum_bitfield();
test_generate_enum_hex_values();
```

### Step 2: Run tests to verify failure

```bash
./build.sh - gen_test
```

Expected: FAIL — `generate_enum` not found.

### Step 3: Implement generate_enum

Add to `src/generator.jai`:

```jai
// Generate a Jai enum from a protocol Enum_Def.
// interface_name is needed for the qualified type name (e.g., "wl_surface" + "error" -> Wl_Surface_Error).
generate_enum :: (e: *Enum_Def, interface_name: string) -> string {
    sb: String_Builder;
    sb.allocator = temp;

    // Doc comment
    if e.description.summary.count > 0
        print_to_builder(*sb, "// %\n", e.description.summary);
    if e.description.body.count > 0 {
        print_to_builder(*sb, "//\n");
        emit_description_body(*sb, e.description.body);
    }

    type_name := to_jai_enum_name(interface_name, e.name);

    if e.bitfield
        print_to_builder(*sb, "% :: enum_flags u32 {\n", type_name);
    else
        print_to_builder(*sb, "% :: enum u32 {\n", type_name);

    for entry: e.entries {
        if entry.summary.count > 0
            print_to_builder(*sb, "    // %\n", entry.summary);
        if entry.value > 0xFFFF
            print_to_builder(*sb, "    % :: 0x%;\n", to_upper_snake(entry.name), formatInt(entry.value, base=16));
        else
            print_to_builder(*sb, "    % :: %;\n", to_upper_snake(entry.name), entry.value);
    }

    print_to_builder(*sb, "}\n");
    return builder_to_string(*sb,, allocator = temp);
}

// Emit a multi-line description body as // prefixed comment lines.
emit_description_body :: (sb: *String_Builder, body: string) {
    remainder := body;
    while remainder.count > 0 {
        newline := -1;
        for 0..remainder.count-1 {
            if remainder[it] == #char "\n" { newline = it; break; }
        }
        if newline < 0 {
            line := trim(remainder);
            if line.count > 0 print_to_builder(sb, "// %\n", line);
            break;
        }
        line: string;
        line.data = remainder.data;
        line.count = newline;
        line = trim(line);
        if line.count > 0
            print_to_builder(sb, "// %\n", line);
        else
            print_to_builder(sb, "//\n");
        remainder.data += newline + 1;
        remainder.count -= newline + 1;
    }
}
```

Note: `formatInt` with `base=16` is from `#import "Basic"`. Check `~/jai/jai/modules/Basic/module.jai` for exact API. If `formatInt` isn't available, use `tprint("%", formatInt(value, base=16))` or a manual hex formatter.

### Step 4: Run tests to verify they pass

```bash
./build.sh - gen_test
```

Expected: All tests pass.

### Step 5: Commit

```bash
git add src/generator.jai tests/generator_test.jai
git commit -m "feat: enum generation with bitfield and hex value support"
```

---

## Task 4: Event Tagged Union Generation

Generate event kind enum and tagged union from an interface's events.

**Files:**
- Modify: `src/generator.jai`
- Modify: `tests/generator_test.jai`

### Step 1: Write failing tests

Add to `tests/generator_test.jai`:

```jai
test_generate_events_basic :: () {
    iface: Interface;
    iface.name = "wl_surface";

    ev1: Message; ev1.name = "enter";
    arg1: Arg; arg1.name = "output"; arg1.arg_type = .UINT;
    array_add(*ev1.args, arg1);

    ev2: Message; ev2.name = "leave";
    arg2: Arg; arg2.name = "output"; arg2.arg_type = .UINT;
    array_add(*ev2.args, arg2);

    array_add(*iface.events, ev1);
    array_add(*iface.events, ev2);

    result := generate_events(*iface);
    assert(contains(result, "Wl_Surface_Event_Kind :: enum u8"), "Missing event kind enum, got:\n%", result);
    assert(contains(result, "ENTER :: 0"), "Missing ENTER");
    assert(contains(result, "LEAVE :: 1"), "Missing LEAVE");
    assert(contains(result, "Wl_Surface_Event :: union kind: Wl_Surface_Event_Kind"), "Missing tagged union, got:\n%", result);
    assert(contains(result, ".ENTER"), "Missing .ENTER binding");
    assert(contains(result, ".LEAVE"), "Missing .LEAVE binding");
    print("  PASS: test_generate_events_basic\n");
}

test_generate_events_no_events :: () {
    iface: Interface;
    iface.name = "wl_callback";
    // No events — should return empty string
    result := generate_events(*iface);
    assert(result.count == 0, "No events should produce empty output");
    print("  PASS: test_generate_events_no_events\n");
}

test_generate_events_arg_types :: () {
    iface: Interface;
    iface.name = "wl_pointer";

    ev: Message; ev.name = "motion";
    arg1: Arg; arg1.name = "time"; arg1.arg_type = .UINT;
    arg2: Arg; arg2.name = "surface_x"; arg2.arg_type = .FIXED;
    arg3: Arg; arg3.name = "surface_y"; arg3.arg_type = .FIXED;
    array_add(*ev.args, arg1);
    array_add(*ev.args, arg2);
    array_add(*ev.args, arg3);
    array_add(*iface.events, ev);

    result := generate_events(*iface);
    assert(contains(result, "time: u32"), "UINT should map to u32");
    assert(contains(result, "surface_x: Fixed"), "FIXED should map to Fixed");
    print("  PASS: test_generate_events_arg_types\n");
}
```

Add calls in `main()`:

```jai
print("\nevent generation:\n");
test_generate_events_basic();
test_generate_events_no_events();
test_generate_events_arg_types();
```

### Step 2: Run tests to verify failure

```bash
./build.sh - gen_test
```

### Step 3: Implement generate_events and arg_type_to_jai

Add to `src/generator.jai`:

```jai
// Map protocol arg types to Jai type strings.
arg_type_to_jai :: (arg: *Arg) -> string {
    if arg.arg_type == {
        case .INT;    return "s32";
        case .UINT;   return "u32";
        case .FIXED;  return "Fixed";
        case .STRING; return "string";
        case .OBJECT;
            if arg.interface_name.count > 0
                return tprint("*%", to_jai_type_name(arg.interface_name));
            return "*void";
        case .NEW_ID;
            if arg.interface_name.count > 0
                return tprint("*%", to_jai_type_name(arg.interface_name));
            return "*void";
        case .ARRAY;  return "[] u8";
        case .FD;     return "s32";
    }
    return "void";
}

// Generate event kind enum + tagged union for an interface.
// Returns empty string if the interface has no events.
generate_events :: (iface: *Interface) -> string {
    if iface.events.count == 0 return "";

    sb: String_Builder;
    sb.allocator = temp;

    type_name := to_jai_type_name(iface.name);
    kind_name := tprint("%_Event_Kind", type_name);
    union_name := tprint("%_Event", type_name);

    // Event kind enum
    print_to_builder(*sb, "% :: enum u8 {\n", kind_name);
    for ev, idx: iface.events {
        print_to_builder(*sb, "    % :: %;\n", to_upper_snake(ev.name), idx);
    }
    print_to_builder(*sb, "}\n\n");

    // Tagged union
    print_to_builder(*sb, "% :: union kind: % {\n", union_name, kind_name);
    for ev: iface.events {
        tag := to_upper_snake(ev.name);
        if ev.args.count == 0 {
            print_to_builder(*sb, "    .%;\n", tag);
        } else if ev.args.count == 1 {
            print_to_builder(*sb, "    .% ,, %: %;\n", tag, ev.args[0].name, arg_type_to_jai(*ev.args[0]));
        } else {
            // Multiple args: use anonymous struct via multiple fields
            // Since tagged union bindings only support one field per variant,
            // wrap multiple args in a struct.
            struct_name := tprint("%_%_Args", type_name, to_jai_type_name(ev.name));
            // We'll emit the struct before the union — need to restructure.
            // For now, use the first arg and note this needs refinement.
            // Actually, let's emit arg structs before the union.
        }
    }
    print_to_builder(*sb, "}\n");

    return builder_to_string(*sb,, allocator = temp);
}
```

**Important design note:** Tagged union bindings (`.TAG ,, field: Type`) only bind one field per variant. Events with multiple args need a wrapper struct. The implementation should emit a struct per multi-arg event before the union:

```jai
Wl_Pointer_Motion_Args :: struct {
    time: u32;
    surface_x: Fixed;
    surface_y: Fixed;
}

Wl_Pointer_Event :: union kind: Wl_Pointer_Event_Kind {
    .MOTION ,, args: Wl_Pointer_Motion_Args;
    .ENTER ,, args: Wl_Pointer_Enter_Args;
    ...
}
```

Adjust the implementation to emit arg structs for multi-arg events, then reference them in the union. The test for `test_generate_events_arg_types` should check for this pattern.

### Step 4: Run tests to verify they pass

```bash
./build.sh - gen_test
```

### Step 5: Commit

```bash
git add src/generator.jai tests/generator_test.jai
git commit -m "feat: event tagged union generation with arg type mapping"
```

---

## Task 5: Request Function Generation

Generate typed stub request functions for each interface request.

**Files:**
- Modify: `src/generator.jai`
- Modify: `tests/generator_test.jai`

### Step 1: Write failing tests

Add to `tests/generator_test.jai`:

```jai
test_generate_request_simple :: () {
    iface: Interface;
    iface.name = "wl_surface";

    req: Message; req.name = "damage";
    arg1: Arg; arg1.name = "x"; arg1.arg_type = .INT;
    arg2: Arg; arg2.name = "y"; arg2.arg_type = .INT;
    arg3: Arg; arg3.name = "width"; arg3.arg_type = .INT;
    arg4: Arg; arg4.name = "height"; arg4.arg_type = .INT;
    array_add(*req.args, arg1);
    array_add(*req.args, arg2);
    array_add(*req.args, arg3);
    array_add(*req.args, arg4);

    result := generate_request(*iface, *req, 2);
    assert(contains(result, "wl_surface_damage"), "Missing function name");
    assert(contains(result, "self: *Wl_Surface"), "Missing self parameter");
    assert(contains(result, "x: s32"), "Missing x param");
    assert(contains(result, "width: s32"), "Missing width param");
    assert(contains(result, "TODO(Phase 3)"), "Missing stub marker");
    print("  PASS: test_generate_request_simple\n");
}

test_generate_request_constructor :: () {
    iface: Interface;
    iface.name = "wl_surface";

    req: Message; req.name = "frame";
    arg1: Arg; arg1.name = "callback"; arg1.arg_type = .NEW_ID; arg1.interface_name = "wl_callback";
    array_add(*req.args, arg1);

    result := generate_request(*iface, *req, 3);
    assert(contains(result, "-> *Wl_Callback"), "Constructor should return new type, got:\n%", result);
    print("  PASS: test_generate_request_constructor\n");
}

test_generate_request_destructor :: () {
    iface: Interface;
    iface.name = "wl_surface";

    req: Message; req.name = "destroy"; req.is_destructor = true;

    result := generate_request(*iface, *req, 0);
    assert(contains(result, "destructor"), "Should note destructor");
    print("  PASS: test_generate_request_destructor\n");
}

test_generate_request_untyped_new_id :: () {
    // wl_registry.bind special case: new_id without interface
    iface: Interface;
    iface.name = "wl_registry";

    req: Message; req.name = "bind";
    arg1: Arg; arg1.name = "name"; arg1.arg_type = .UINT;
    arg2: Arg; arg2.name = "id"; arg2.arg_type = .NEW_ID;  // no interface_name!
    array_add(*req.args, arg1);
    array_add(*req.args, arg2);

    result := generate_request(*iface, *req, 0);
    assert(contains(result, "$T"), "Untyped new_id should use polymorphic type, got:\n%", result);
    print("  PASS: test_generate_request_untyped_new_id\n");
}
```

Add calls in `main()`:

```jai
print("\nrequest generation:\n");
test_generate_request_simple();
test_generate_request_constructor();
test_generate_request_destructor();
test_generate_request_untyped_new_id();
```

### Step 2: Run tests to verify failure

```bash
./build.sh - gen_test
```

### Step 3: Implement generate_request

Add to `src/generator.jai`:

```jai
// Generate a typed stub request function.
// opcode is the 0-based index of this request in the interface.
generate_request :: (iface: *Interface, req: *Message, opcode: int) -> string {
    sb: String_Builder;
    sb.allocator = temp;

    type_name := to_jai_type_name(iface.name);
    func_name := tprint("%_%", iface.name, req.name);

    // Doc comment
    if req.description.summary.count > 0
        print_to_builder(*sb, "// %\n", req.description.summary);
    if req.description.body.count > 0 {
        print_to_builder(*sb, "//\n");
        emit_description_body(*sb, req.description.body);
    }
    if req.is_destructor
        print_to_builder(*sb, "// (destructor)\n");

    // Check for new_id return type
    has_new_id := false;
    new_id_typed := false;
    new_id_interface := "";
    untyped_new_id := false;
    for arg: req.args {
        if arg.arg_type == .NEW_ID {
            has_new_id = true;
            if arg.interface_name.count > 0 {
                new_id_typed = true;
                new_id_interface = arg.interface_name;
            } else {
                untyped_new_id = true;
            }
        }
    }

    // Function signature
    print_to_builder(*sb, "% :: (self: *%", func_name, type_name);

    // Parameters (skip new_id args that are return values)
    for arg: req.args {
        if arg.arg_type == .NEW_ID && arg.interface_name.count > 0 continue;
        if arg.arg_type == .NEW_ID && arg.interface_name.count == 0 {
            // Untyped bind: emit $T: Type and version
            print_to_builder(*sb, ", $T: Type, version: u32");
            continue;
        }
        jai_type := arg_type_to_jai(*arg);
        print_to_builder(*sb, ", %: %", arg.name, jai_type);
    }

    print_to_builder(*sb, ")");

    // Return type
    if has_new_id {
        if untyped_new_id
            print_to_builder(*sb, " -> *T");
        else if new_id_typed
            print_to_builder(*sb, " -> *%", to_jai_type_name(new_id_interface));
    }

    // Stub body
    print_to_builder(*sb, " {\n");
    print_to_builder(*sb, "    // TODO(Phase 3): marshal(self, %, ...);\n",
                     opcode_name(iface.name, req.name));
    if has_new_id
        print_to_builder(*sb, "    return null;\n");
    print_to_builder(*sb, "}\n");

    return builder_to_string(*sb,, allocator = temp);
}
```

### Step 4: Run tests to verify they pass

```bash
./build.sh - gen_test
```

### Step 5: Commit

```bash
git add src/generator.jai tests/generator_test.jai
git commit -m "feat: request function generation with constructor and destructor handling"
```

---

## Task 6: Interface Struct, Opcodes, and Descriptor Generation

Generate the interface struct, opcode constants, and interface descriptor.

**Files:**
- Modify: `src/generator.jai`
- Modify: `tests/generator_test.jai`

### Step 1: Write failing tests

Add to `tests/generator_test.jai`:

```jai
test_generate_interface_struct :: () {
    iface: Interface;
    iface.name = "wl_surface";
    iface.version = 6;
    iface.description.summary = "a compositable surface";

    result := generate_interface_struct(*iface);
    assert(contains(result, "Wl_Surface :: struct"), "Missing struct");
    assert(contains(result, "id: u32"), "Missing id field");
    assert(contains(result, "version: u32"), "Missing version field");
    assert(contains(result, "a compositable surface"), "Missing summary comment");
    print("  PASS: test_generate_interface_struct\n");
}

test_generate_opcodes :: () {
    iface: Interface;
    iface.name = "wl_surface";

    req1: Message; req1.name = "destroy";
    req2: Message; req2.name = "attach";
    req3: Message; req3.name = "damage";
    array_add(*iface.requests, req1);
    array_add(*iface.requests, req2);
    array_add(*iface.requests, req3);

    ev1: Message; ev1.name = "enter";
    ev2: Message; ev2.name = "leave";
    array_add(*iface.events, ev1);
    array_add(*iface.events, ev2);

    result := generate_opcodes(*iface);
    assert(contains(result, "WL_SURFACE_DESTROY :: 0"), "Missing destroy opcode");
    assert(contains(result, "WL_SURFACE_ATTACH :: 1"), "Missing attach opcode");
    assert(contains(result, "WL_SURFACE_DAMAGE :: 2"), "Missing damage opcode");
    assert(contains(result, "WL_SURFACE_ENTER :: 0"), "Missing enter event opcode");
    assert(contains(result, "WL_SURFACE_LEAVE :: 1"), "Missing leave event opcode");
    print("  PASS: test_generate_opcodes\n");
}

test_generate_interface_descriptor :: () {
    iface: Interface;
    iface.name = "wl_surface";
    iface.version = 6;
    req1: Message; req1.name = "a";
    req2: Message; req2.name = "b";
    array_add(*iface.requests, req1);
    array_add(*iface.requests, req2);
    ev1: Message; ev1.name = "c";
    array_add(*iface.events, ev1);

    result := generate_interface_descriptor(*iface);
    assert(contains(result, "WL_SURFACE_INTERFACE"), "Missing descriptor name");
    assert(contains(result, "Interface_Descriptor"), "Missing type");
    assert(contains(result, "\"wl_surface\""), "Missing name string");
    assert(contains(result, "version = 6"), "Missing version");
    assert(contains(result, "request_count = 2"), "Missing request count");
    assert(contains(result, "event_count = 1"), "Missing event count");
    print("  PASS: test_generate_interface_descriptor\n");
}
```

Add calls in `main()`:

```jai
print("\ninterface components:\n");
test_generate_interface_struct();
test_generate_opcodes();
test_generate_interface_descriptor();
```

### Step 2: Run tests to verify failure

```bash
./build.sh - gen_test
```

### Step 3: Implement

Add to `src/generator.jai`:

```jai
generate_interface_struct :: (iface: *Interface) -> string {
    sb: String_Builder;
    sb.allocator = temp;
    type_name := to_jai_type_name(iface.name);

    // Doc comment
    print_to_builder(*sb, "//\n");
    print_to_builder(*sb, "// % — %\n", iface.name, iface.description.summary);
    print_to_builder(*sb, "//\n");
    if iface.description.body.count > 0 {
        emit_description_body(*sb, iface.description.body);
        print_to_builder(*sb, "//\n");
    }

    print_to_builder(*sb, "% :: struct {\n", type_name);
    print_to_builder(*sb, "    id: u32;\n");
    print_to_builder(*sb, "    version: u32;\n");
    print_to_builder(*sb, "}\n");

    return builder_to_string(*sb,, allocator = temp);
}

generate_opcodes :: (iface: *Interface) -> string {
    sb: String_Builder;
    sb.allocator = temp;

    if iface.requests.count > 0 {
        print_to_builder(*sb, "// Request opcodes\n");
        for req, idx: iface.requests {
            print_to_builder(*sb, "% :: %;\n", opcode_name(iface.name, req.name), idx);
        }
    }

    if iface.events.count > 0 {
        if iface.requests.count > 0 print_to_builder(*sb, "\n");
        print_to_builder(*sb, "// Event opcodes\n");
        for ev, idx: iface.events {
            print_to_builder(*sb, "% :: %;\n", opcode_name(iface.name, ev.name), idx);
        }
    }

    return builder_to_string(*sb,, allocator = temp);
}

generate_interface_descriptor :: (iface: *Interface) -> string {
    sb: String_Builder;
    sb.allocator = temp;

    desc_name := tprint("%_INTERFACE", to_upper_snake(iface.name));
    print_to_builder(*sb, "% :: Interface_Descriptor.{\n", desc_name);
    print_to_builder(*sb, "    name = \"%\",\n", iface.name);
    print_to_builder(*sb, "    version = %,\n", iface.version);
    print_to_builder(*sb, "    request_count = %,\n", iface.requests.count);
    print_to_builder(*sb, "    event_count = %,\n", iface.events.count);
    print_to_builder(*sb, "};\n");

    return builder_to_string(*sb,, allocator = temp);
}
```

### Step 4: Run tests to verify they pass

```bash
./build.sh - gen_test
```

### Step 5: Commit

```bash
git add src/generator.jai tests/generator_test.jai
git commit -m "feat: interface struct, opcode, and descriptor generation"
```

---

## Task 7: Full Interface File Assembly

Combine all components into a complete per-interface file.

**Files:**
- Modify: `src/generator.jai`
- Modify: `tests/generator_test.jai`

### Step 1: Write failing test

Add to `tests/generator_test.jai`:

```jai
test_generate_interface_file :: () {
    // Build a minimal interface with all features
    iface: Interface;
    iface.name = "wl_surface";
    iface.version = 6;
    iface.description.summary = "a compositable surface";

    // One enum
    e: Enum_Def; e.name = "error";
    entry: Entry; entry.name = "invalid_scale"; entry.value = 0; entry.summary = "bad scale";
    array_add(*e.entries, entry);
    array_add(*iface.enums, e);

    // One request
    req: Message; req.name = "destroy"; req.is_destructor = true;
    array_add(*iface.requests, req);

    // One event
    ev: Message; ev.name = "enter";
    arg: Arg; arg.name = "output"; arg.arg_type = .UINT;
    array_add(*ev.args, arg);
    array_add(*iface.events, ev);

    result := generate_interface_file(*iface);

    // Check all sections are present and in order
    assert(contains(result, "Auto-generated"), "Missing header");
    assert(contains(result, "Wl_Surface :: struct"), "Missing struct");
    assert(contains(result, "WL_SURFACE_DESTROY :: 0"), "Missing opcodes");
    assert(contains(result, "Wl_Surface_Error :: enum u32"), "Missing enum");
    assert(contains(result, "Wl_Surface_Event_Kind"), "Missing event kind");
    assert(contains(result, "Wl_Surface_Event :: union"), "Missing event union");
    assert(contains(result, "wl_surface_destroy"), "Missing request function");
    assert(contains(result, "WL_SURFACE_INTERFACE"), "Missing descriptor");
    print("  PASS: test_generate_interface_file\n");
}
```

Add call in `main()`:

```jai
print("\nfull interface file:\n");
test_generate_interface_file();
```

### Step 2: Run tests to verify failure

```bash
./build.sh - gen_test
```

### Step 3: Implement generate_interface_file

Add to `src/generator.jai`:

```jai
// Generate a complete per-interface .jai file.
generate_interface_file :: (iface: *Interface) -> string {
    sb: String_Builder;
    sb.allocator = temp;

    print_to_builder(*sb, "// Auto-generated by jai-wayland code generator. Do not edit.\n\n");

    // 1. Interface struct with doc comment
    print_to_builder(*sb, "%\n", generate_interface_struct(iface));

    // 2. Opcode constants
    opcodes := generate_opcodes(iface);
    if opcodes.count > 0
        print_to_builder(*sb, "%\n", opcodes);

    // 3. Enums
    for * e: iface.enums {
        print_to_builder(*sb, "%\n", generate_enum(e, iface.name));
    }

    // 4. Event tagged union
    events := generate_events(iface);
    if events.count > 0
        print_to_builder(*sb, "%\n", events);

    // 5. Request functions
    for * req, idx: iface.requests {
        print_to_builder(*sb, "%\n", generate_request(iface, req, idx));
    }

    // 6. Interface descriptor
    print_to_builder(*sb, "%", generate_interface_descriptor(iface));

    return builder_to_string(*sb,, allocator = temp);
}
```

### Step 4: Run tests to verify they pass

```bash
./build.sh - gen_test
```

### Step 5: Commit

```bash
git add src/generator.jai tests/generator_test.jai
git commit -m "feat: full interface file assembly from components"
```

---

## Task 8: Protocol Directory and #load Chain Generation

Generate protocol-level directory structure and `#load` files.

**Files:**
- Modify: `src/generator.jai`
- Modify: `tests/generator_test.jai`

### Step 1: Write failing tests

Add to `tests/generator_test.jai`:

```jai
test_generate_protocol_loader :: () {
    proto: Protocol;
    proto.name = "wayland";

    iface1: Interface; iface1.name = "wl_display"; iface1.version = 1;
    iface2: Interface; iface2.name = "wl_registry"; iface2.version = 1;
    array_add(*proto.interfaces, iface1);
    array_add(*proto.interfaces, iface2);

    result := generate_protocol_loader(*proto);
    assert(contains(result, "#load \"wl_display.jai\""), "Missing wl_display load");
    assert(contains(result, "#load \"wl_registry.jai\""), "Missing wl_registry load");
    print("  PASS: test_generate_protocol_loader\n");
}

test_generate_module_root :: () {
    protocol_names: [..] string;
    array_add(*protocol_names, "wayland");
    array_add(*protocol_names, "xdg_shell");

    result := generate_module_root(protocol_names);
    assert(contains(result, "#load \"types.jai\""), "Missing types load");
    assert(contains(result, "#load \"wayland/wayland.jai\""), "Missing wayland protocol load");
    assert(contains(result, "#load \"xdg_shell/xdg_shell.jai\""), "Missing xdg_shell load");
    print("  PASS: test_generate_module_root\n");
}
```

Add calls in `main()`:

```jai
print("\nprotocol structure:\n");
test_generate_protocol_loader();
test_generate_module_root();
```

### Step 2: Run tests to verify failure

```bash
./build.sh - gen_test
```

### Step 3: Implement

Add to `src/generator.jai`:

```jai
// Generate protocol-level loader file (e.g., wayland/wayland.jai)
// that #loads each interface file.
generate_protocol_loader :: (proto: *Protocol) -> string {
    sb: String_Builder;
    sb.allocator = temp;

    print_to_builder(*sb, "// Auto-generated by jai-wayland code generator. Do not edit.\n");
    print_to_builder(*sb, "// Protocol: % (%)\n\n", proto.name, proto.interfaces.count);

    for iface: proto.interfaces {
        print_to_builder(*sb, "#load \"%.jai\";\n", iface.name);
    }

    return builder_to_string(*sb,, allocator = temp);
}

// Generate the top-level module.jai that #loads types and all protocols.
generate_module_root :: (protocol_names: [..] string) -> string {
    sb: String_Builder;
    sb.allocator = temp;

    print_to_builder(*sb, "// Auto-generated by jai-wayland code generator. Do not edit.\n\n");
    print_to_builder(*sb, "#load \"types.jai\";\n\n");

    for name: protocol_names {
        print_to_builder(*sb, "#load \"%/%.jai\";\n", name, name);
    }

    return builder_to_string(*sb,, allocator = temp);
}
```

### Step 4: Run tests to verify they pass

```bash
./build.sh - gen_test
```

### Step 5: Commit

```bash
git add src/generator.jai tests/generator_test.jai
git commit -m "feat: protocol loader and module root generation"
```

---

## Task 9: File Writer — End-to-End Generation

Wire up the file I/O: read all protocol XMLs, generate all files, write to `modules/wayland/`.

**Files:**
- Modify: `src/generator.jai`
- Modify: `first.jai` (add `generate` build mode)
- Create: `src/generate_main.jai` (entry point for generator)

### Step 1: Write failing test for single-protocol file generation

Add to `tests/generator_test.jai`:

```jai
test_generate_from_xml :: () {
    contents, ok := read_entire_file("vendor/wayland-protocols/core/wayland.xml");
    assert(ok);
    proto := parse_protocol(contents);

    // Generate wl_display file from parsed protocol
    assert(proto.interfaces.count >= 22);
    display := proto.interfaces[0];
    assert(display.name == "wl_display");

    result := generate_interface_file(*display);
    assert(contains(result, "Wl_Display :: struct"), "Missing struct");
    assert(contains(result, "WL_DISPLAY_SYNC :: 0"), "Missing sync opcode");
    assert(contains(result, "WL_DISPLAY_GET_REGISTRY :: 1"), "Missing get_registry opcode");
    assert(contains(result, "Wl_Display_Error :: enum u32"), "Missing error enum");
    assert(contains(result, "Wl_Display_Event"), "Missing event union");
    assert(contains(result, "wl_display_sync"), "Missing sync request");
    assert(contains(result, "-> *Wl_Callback"), "sync should return Wl_Callback");
    assert(contains(result, "WL_DISPLAY_INTERFACE"), "Missing descriptor");
    print("  PASS: test_generate_from_xml\n");
}
```

Add call in `main()`:

```jai
print("\nend-to-end:\n");
test_generate_from_xml();
```

### Step 2: Run tests to verify they pass (this uses existing code)

```bash
./build.sh - gen_test
```

This should already pass since it uses existing functions. If it does, proceed.

### Step 3: Create generate_main.jai entry point

Create `src/generate_main.jai`:

```jai
#import "Basic";
#import "File";
#import "File_Utilities";
#import "String";

#load "xml.jai";
#load "protocol.jai";
#load "generator.jai";

OUTPUT_DIR :: "modules/wayland";
INPUT_DIR :: "vendor/wayland-protocols";

main :: () {
    print("Generating Wayland bindings...\n\n");

    // Collect all protocol XML files and parse them
    Parsed :: struct {
        proto: Protocol;
        name: string;  // protocol name (used for directory)
    };

    parsed_protocols: [..] Parsed;

    visit_files(INPUT_DIR, true, *parsed_protocols, (info: *File_Visit_Info, protocols: *[..] Parsed) {
        if !ends_with(info.full_name, ".xml") return;
        contents, ok := read_entire_file(info.full_name);
        if !ok {
            print("  WARNING: failed to read %\n", info.full_name);
            return;
        }
        proto := parse_protocol(contents);
        array_add(protocols, .{ proto = proto, name = proto.name });
    });

    print("Parsed % protocol files.\n", parsed_protocols.count);

    // Create output directory
    make_directory_if_it_does_not_exist(OUTPUT_DIR);

    // Generate types.jai
    {
        sb: String_Builder;
        print_to_builder(*sb, "%", generate_types_file());
        ok := write_entire_file(tprint("%/types.jai", OUTPUT_DIR), *sb);
        if ok print("  wrote types.jai\n");
    }

    // Generate per-protocol directories and files
    protocol_names: [..] string;

    for * parsed: parsed_protocols {
        proto_dir := tprint("%/%", OUTPUT_DIR, parsed.name);
        make_directory_if_it_does_not_exist(proto_dir);

        array_add(*protocol_names, copy_string(parsed.name));

        // Generate per-interface files
        for * iface: parsed.proto.interfaces {
            file_content := generate_interface_file(iface);
            file_path := tprint("%/%.jai", proto_dir, iface.name);
            sb: String_Builder;
            print_to_builder(*sb, "%", file_content);
            write_entire_file(file_path, *sb);
        }

        // Generate protocol loader
        loader := generate_protocol_loader(*parsed.proto);
        {
            sb: String_Builder;
            print_to_builder(*sb, "%", loader);
            write_entire_file(tprint("%/%.jai", proto_dir, parsed.name), *sb);
        }

        print("  % — % interfaces\n", parsed.name, parsed.proto.interfaces.count);
    }

    // Generate module.jai
    {
        root := generate_module_root(protocol_names);
        sb: String_Builder;
        print_to_builder(*sb, "%", root);
        write_entire_file(tprint("%/module.jai", OUTPUT_DIR), *sb);
        print("  wrote module.jai\n");
    }

    print("\nDone. Generated % protocols, output in %/\n", parsed_protocols.count, OUTPUT_DIR);
}
```

### Step 4: Add `generate` mode to first.jai

Add a new case in `first.jai`'s arg loop:

```jai
case "generate";
    build_and_run("generator", "generator", "src/generate_main.jai", "build");
```

Also add a variant of `build_and_run_test` that just builds and runs (without the test naming convention):

```jai
build_and_run :: (workspace_name: string, executable_name: string, source_file: string, build_dir: string) {
    // Same as build_and_run_test — can just call it directly
    build_and_run_test(workspace_name, executable_name, source_file, build_dir);
}
```

Or just reuse `build_and_run_test` directly.

### Step 5: Run the generator

```bash
./build.sh - generate
```

Expected output:
```
Generating Wayland bindings...

Parsed 59 protocol files.
  wrote types.jai
  wayland — 23 interfaces
  xdg_shell — 5 interfaces
  ... (59 protocols)
  wrote module.jai

Done. Generated 59 protocols, output in modules/wayland/
```

### Step 6: Verify generated files exist

```bash
ls modules/wayland/module.jai
ls modules/wayland/types.jai
ls modules/wayland/wayland/wl_display.jai
ls modules/wayland/xdg_shell/xdg_toplevel.jai
```

### Step 7: Commit

```bash
git add src/generate_main.jai first.jai
git commit -m "feat: generator entry point and build integration (./build.sh - generate)"
```

---

## Task 10: Compilation Smoke Test

Verify the generated module compiles by importing it.

**Files:**
- Create: `tests/compile_test.jai`
- Modify: `first.jai` (add compile_test workspace)

### Step 1: Generate the module (if not already done)

```bash
./build.sh - generate
```

### Step 2: Create compilation test

Create `tests/compile_test.jai`:

```jai
#import "Basic";
#import,dir "../modules/wayland";

test_types_exist :: () {
    d: Wl_Display;
    assert(d.id == 0);
    s: Wl_Surface;
    assert(s.version == 0);
    print("  PASS: test_types_exist\n");
}

test_opcodes_exist :: () {
    assert(WL_DISPLAY_SYNC == 0);
    assert(WL_DISPLAY_GET_REGISTRY == 1);
    assert(WL_SURFACE_ATTACH == 1);
    assert(WL_SURFACE_DAMAGE_BUFFER == 9);
    print("  PASS: test_opcodes_exist\n");
}

test_enums_exist :: () {
    err: Wl_Display_Error = .INVALID_OBJECT;
    assert(cast(u32) err == 0);
    print("  PASS: test_enums_exist\n");
}

test_events_exist :: () {
    assert(size_of(Wl_Display_Event) > 0);
    assert(size_of(Wl_Surface_Event) > 0);
    print("  PASS: test_events_exist\n");
}

test_descriptors_exist :: () {
    assert(WL_DISPLAY_INTERFACE.name == "wl_display");
    assert(WL_DISPLAY_INTERFACE.version == 1);
    assert(WL_SURFACE_INTERFACE.version == 6);
    print("  PASS: test_descriptors_exist\n");
}

test_xdg_types :: () {
    t: Xdg_Toplevel;
    assert(t.id == 0);
    assert(XDG_TOPLEVEL_INTERFACE.name == "xdg_toplevel");
    print("  PASS: test_xdg_types\n");
}

main :: () {
    print("Running compilation tests...\n\n");

    print("generated module:\n");
    test_types_exist();
    test_opcodes_exist();
    test_enums_exist();
    test_events_exist();
    test_descriptors_exist();
    test_xdg_types();

    print("\nAll tests passed.\n");
}
```

### Step 3: Add compile_test to first.jai

```jai
case "compile_test";
    build_and_run_test("compile_tests", "compile_tests", "tests/compile_test.jai", "build_tests");
```

### Step 4: Run the compilation test

```bash
./build.sh - compile_test
```

Expected: All 6 tests pass. If there are compilation errors, fix the generator output.

### Step 5: Commit

```bash
git add tests/compile_test.jai first.jai
git commit -m "feat: compilation smoke test for generated wayland module"
```

---

## Task 11: Generate and Check In the Module

Generate the final output and check it into the repository.

### Step 1: Clean and regenerate

```bash
rm -rf modules/wayland
./build.sh - generate
```

### Step 2: Run all tests

```bash
./build.sh - test
./build.sh - gen_test
./build.sh - compile_test
```

All should pass.

### Step 3: Add generated files and commit

```bash
git add modules/wayland/
git commit -m "feat: generated Wayland protocol bindings for 59 protocols (189 interfaces)"
```

### Step 4: Update .gitignore

The `modules/wayland/` directory should NOT be gitignored — it's part of the distributable library.

Verify `modules/` is not in `.gitignore`. If it is, remove it.

### Step 5: Run full test suite one more time

```bash
./build.sh - test
./build.sh - gen_test
./build.sh - compile_test
```

### Step 6: Commit any remaining changes

```bash
git add -A
git commit -m "chore: final Phase 2 cleanup"
```

---

## Task 12: Update Documentation

Update README.md, CLAUDE.md, and push.

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

### Step 1: Update README.md

Add Phase 2 status, update project structure to include `modules/wayland/`, document the `./build.sh - generate` command.

### Step 2: Update CLAUDE.md

Add generator documentation: `src/generator.jai` architecture, `src/generate_main.jai` entry point, build commands, testing.

### Step 3: Commit and push

```bash
git add README.md CLAUDE.md
git commit -m "docs: update README and CLAUDE.md for Phase 2 code generator"
git push
```
