#import "Basic";
#import "File";
#load "xml.jai";

main :: () {
    contents, ok := read_entire_file("vendor/wayland-protocols/core/wayland.xml");
    if !ok { print("Failed to read file\n"); return; }

    parser := xml_parser_init(contents);
    tag_count := 0;
    attr_count := 0;
    char_count := 0;
    while true {
        event, has_event := xml_next(*parser);
        if !has_event break;
        if event.kind == .OPEN_TAG   tag_count += 1;
        if event.kind == .ATTRIBUTE  attr_count += 1;
        if event.kind == .CHARACTER_DATA  char_count += 1;
    }
    print("Tags: %, Attributes: %, Character data: %\n", tag_count, attr_count, char_count);
}
