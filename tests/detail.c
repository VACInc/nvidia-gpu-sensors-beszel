#define main collector_main
#include "../src/nvidia-gpu-sensors.c"
#undef main
#include <assert.h>

static void put(uint8_t *mem, unsigned off, uint32_t v)
{
    *(uint32_t *)(mem + off) = v;
}

int main(void)
{
    uint8_t *mem = calloc(1, BAR0_MAP_LEN);
    assert(mem);
    double v = 0;
    unsigned reg = 0;
    char lab[8];
    int n = 0;

    /* hottest die sensor register matches the Hot Spot value */
    GPU a = { .bar0 = mem, .arch = ARCH_AMPERE };
    put(mem, NV_THERM_HOTSPOT_AMPERE[0], 0x40003000); /* 48.0 */
    put(mem, NV_THERM_HOTSPOT_AMPERE[3], 0x40003800); /* 56.0 */
    assert(bar0_hotspot_sensor(&a, &v, &reg) && v == 56.0 && reg == NV_THERM_HOTSPOT_AMPERE[3]);
    double hot = 0;
    assert(bar0_hotspot(&a, &hot) && hot == v);

    /* no chip status bits: no per-chip reading */
    assert(!bar0_vram_chips(&a, &v, lab, &n) && n == 0);

    /* clamshell; partition D (p=3) slot +4 valid with front 0x30 (56C) back 0x38 (72C);
     * partition A (p=0) slot +8 valid (first of pair invalid) front 0x2E (52C) */
    put(mem, GDDR_CLAMSHELL, 1u << 22);
    put(mem, GDDR_TEMP_STATUS_BASE + 3 * 0x4000, 1u << 25);
    put(mem, GDDR_TEMP_DATA_BASE + 3 * 0x4000 + 0x4, 0x38300000);
    put(mem, GDDR_TEMP_STATUS_BASE + 0 * 0x4000, 1u << 26);
    put(mem, GDDR_TEMP_DATA_BASE + 0 * 0x4000 + 0x8, 0x002E0000);
    /* BADF partition is skipped */
    put(mem, GDDR_TEMP_STATUS_BASE + 5 * 0x4000, 0xBADF5040);
    assert(bar0_vram_chips(&a, &v, lab, &n));
    assert(n == 3 && v == 72 && !strcmp(lab, "D1B"));

    /* non-clamshell ignores the back byte */
    put(mem, GDDR_CLAMSHELL, 0);
    assert(bar0_vram_chips(&a, &v, lab, &n));
    assert(n == 2 && v == 56 && !strcmp(lab, "D1F"));

    /* raw clamps at 0x50 => 120C */
    put(mem, GDDR_TEMP_DATA_BASE + 3 * 0x4000 + 0x4, 0x00700000);
    assert(bar0_vram_chips(&a, &v, lab, &n) && v == 120);

    /* GA107 never reports chips */
    GPU c = { .bar0 = mem, .arch = ARCH_AMPERE_GA107 };
    assert(!bar0_vram_chips(&c, &v, lab, &n));

    free(mem);
    return 0;
}
