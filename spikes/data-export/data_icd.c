/* Fake Vulkan ICD for the DATA-interposition spike. References the interface
 * table as an UNDEFINED extern data symbol (resolved at load via DT_NEEDED to
 * the provider) — exactly like the Mesa/NVIDIA ICD references wl_registry_interface. */
#include <stdint.h>
struct Thing { int32_t a; int32_t b; void *p; };
extern struct Thing my_test_interface;
void   *icd_addr_of_interface(void) { return (void *)&my_test_interface; }
int32_t icd_read_interface_a(void)  { return my_test_interface.a; }
