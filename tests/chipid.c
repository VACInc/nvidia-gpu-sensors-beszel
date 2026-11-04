#define main collector_main
#include "../src/nvidia-gpu-sensors.c"
#undef main
#include <assert.h>

/* BOOT0 chipset decoding gates every architecture-specific register read. */
int main(void)
{
    assert(is_blackwell(0x1b2000a1));     /* GB202, clean high bits */
    assert(is_blackwell(0xbb2000a1u));    /* GB202 with bits 31:29 set, as GA107 shows */
    assert(is_blackwell(0xbb6000a1u));    /* GB206, same */
    assert(!is_blackwell(0x1a2000a1));    /* not GB20x */
    assert(!is_blackwell(0xffffffffu));   /* GPU fell off the bus */
    assert(!is_blackwell(0xb77000a1));    /* GA107 */
    assert(is_ga107(0xb77000a1) && !is_ga107(0x1b2000a1));
    return 0;
}
