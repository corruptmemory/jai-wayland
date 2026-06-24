# data-export spike — can a Jai exe interpose a libwayland DATA symbol?

Gate-1 (`../symbol-scope/`) proved a Jai executable interposes a libwayland
*procedure* (`wl_proxy_get_version`) over a real libwayland a dlopened ICD pulls
in via `DT_NEEDED`. This spike closes the remaining half of the linchpin: the
Vulkan ICD also references the interface tables (`wl_registry_interface`,
`wl_compositor_interface`, …) as **undefined OBJECT (data) symbols**. For the
duck-type proxy to work, those must bind to OUR `#program_export`'d tables.

## Two tiers

**Tier A — export:** `data_export.jai` `#program_export`s two globals (a struct
and a scalar). `readelf --dyn-syms` shows both in `.dynsym` as `OBJECT GLOBAL`
with bare C names (no Jai mangling). → Jai CAN export data symbols.

**Tier B — interposition:** `data_spike.jai` `#program_export`s
`my_test_interface` with sentinel `0xC0FFEE`. `data_icd.c` (a fake ICD) carries
an `extern struct Thing my_test_interface;` and `DT_NEEDED`s
`real_provider.c` — a stand-in for real libwayland that *defines* the same
symbol with sentinel `0xDEAD`. The exe dlopens the ICD `RTLD_GLOBAL` and asks it
to read `.a`.

## Reproduce

```bash
mkdir -p build
gcc -shared -fPIC -o build/libreal_provider.so real_provider.c
gcc -shared -fPIC -o build/libdata_icd.so data_icd.c -Lbuild -lreal_provider -Wl,-rpath,'$ORIGIN'
~/jai/jai/bin/jai-linux data_export.jai && readelf --dyn-syms data_export | grep my_exported   # Tier A
~/jai/jai/bin/jai-linux data_spike.jai  && ./data_spike                                        # Tier B
```

## Verdict (2026-06-24, AMD/Mesa desktop)

**DATA INTERPOSITION HOLDS.** The ICD's extern-data ref resolved to our exported
table (address match; `.a == 0xC0FFEE`, not the provider's `0xDEAD`). So the
Task-7 mechanism is settled: `#program_export` each `<iface>_interface` global in
`modules/libwayland_shim/tables.jai`; no C-owned data tables are needed. The
`st_size` Jai reports for exported data is bogus (4120) but irrelevant — dlopen
resolves data by name through global scope, with no COPY relocations.

Still to confirm on the **laptop**: the same against NVIDIA's ICD (mechanism is
driver-agnostic ELF, so it should hold; verify with `nm -D --undefined`).
