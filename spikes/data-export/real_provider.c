/* Stand-in for real libwayland-client: DEFINES the interface data symbol. */
#include <stdint.h>
struct Thing { int32_t a; int32_t b; void *p; };
struct Thing my_test_interface = { 0xDEAD, 0, 0 };  /* REAL sentinel */
