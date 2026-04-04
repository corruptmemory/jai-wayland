# Wayland Protocol XML Parser Design

## Goal

Parse Wayland protocol XML files into a structured data model that a future code generator will consume to emit Jai bindings.

## Architecture: Two Layers

### Layer 1 — `xml.jai`: Pull Parser

A streaming pull parser over an in-memory string. Returns events as slices into the source buffer (zero-copy).

**Input:** `string` (entire XML file loaded into memory)

**Output:** Iterator yielding `Xml_Event` (tagged union):
- `open_tag` — element name
- `close_tag` — element name (also emitted for self-closing `<foo/>`)
- `attribute` — name + value (raw, within an open tag)
- `character_data` — text content between tags
- `comment`, `processing_instruction` — skipped by consumer

**Entity handling:** `&lt;` `&gt;` `&amp;` `&apos;` `&quot;` — only these 5 XML entities appear in protocol files. Numeric entities (`&#xNN;`) not needed.

**Not handled:** DTDs, namespaces, encoding declarations — none appear in Wayland protocol XML.

### Layer 2 — `protocol.jai`: Data Model + Consumer

Drives the pull parser to build protocol structs.

**Data model:**

```
Protocol
  name: string
  copyright: string  (optional)
  interfaces: [] Interface

Interface
  name: string
  version: u32
  description: Description  (optional)
  requests: [] Message
  events: [] Message
  enums: [] Enum

Message
  name: string
  since: u32
  is_destructor: bool
  description: Description  (optional)
  args: [] Arg

Arg
  name: string
  type: Arg_Type  (INT, UINT, FIXED, STRING, OBJECT, NEW_ID, ARRAY, FD)
  interface: string  (optional, for OBJECT/NEW_ID)
  enum_name: string  (optional, can be "local_name" or "interface.name")
  allow_null: bool
  summary: string  (optional)

Enum
  name: string
  since: u32
  bitfield: bool
  description: Description  (optional)
  entries: [] Entry

Entry
  name: string
  value: u32  (supports decimal and 0x hex)
  since: u32
  summary: string  (optional)

Description
  summary: string
  body: string
```

## XML Elements Handled

Only 8 element types matter: `protocol`, `copyright`, `interface`, `request`, `event`, `enum`, `entry`, `arg`, plus `description` as metadata on most of them.

## Reference Implementations

- `vendor/reference/zig-wayland/src/xml.zig` — pull parser (~230 lines)
- `vendor/reference/zig-wayland/src/scanner.zig` — consumer/codegen
- `vendor/reference/wayland-rs/wayland-scanner/src/protocol.rs` — data model
- `vendor/reference/wayland-rs/wayland-scanner/src/parse.rs` — consumer
