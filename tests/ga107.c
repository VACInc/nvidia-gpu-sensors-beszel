#define main collector_main
#include "../src/nvidia-gpu-sensors.c"
#undef main
#include <assert.h>
int main(void) {
    assert(is_ga107(0xb77000a1));
    assert(is_ga107(0x177000a1));
    assert(!is_ga107(0xb76000a1));
    assert(ampere_vram_offset(0x2584) == 0);
    uint8_t *mem = calloc(1, BAR0_MAP_LEN);
    assert(mem);
    GPU g = { .bar0 = mem, .arch = ARCH_AMPERE_GA107, .vramOff = 0 };
    double value = 0;
    *(uint32_t *)(mem + 0x02046C) = 0x40002c30;
    assert(bar0_hotspot(&g, &value) && value == 44.1875);
    *(uint32_t *)(mem + 0x02046C) = 0;
    assert(!bar0_hotspot(&g, &value));
    free(mem);
    return 0;
}
