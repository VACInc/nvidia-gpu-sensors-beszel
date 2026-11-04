#define main collector_main
#include "../src/nvidia-gpu-sensors.c"
#undef main
#include <assert.h>

/* RUSD seqlock reader: only a settled, valid timestamp yields a reading. */
static void put_entry(uint8_t *rusd, int sensor, uint64_t ts, int32_t raw)
{
    uint8_t *e = rusd + RUSD_TEMPS_OFF + sensor * RUSD_TEMP_STRIDE;
    memcpy(e, &ts, sizeof ts);
    memcpy(e + RUSD_TEMP_VALUE, &raw, sizeof raw);
}

int main(void)
{
    static _Alignas(8) uint8_t rusd[RUSD_SIZE];
    double v = -1;

    put_entry(rusd, SENSOR_GPU, 1234, 51 * 256 + 128);
    assert(read_temp(rusd, SENSOR_GPU, &v) && v == 51.5);

    v = -1;
    put_entry(rusd, SENSOR_MEMORY, RUSD_TS_INVALID, 40 * 256);
    assert(!read_temp(rusd, SENSOR_MEMORY, &v) && v == -1);

    /* A writer that never finishes must not read back as 0 C. */
    put_entry(rusd, SENSOR_MEMORY, RUSD_TS_WRITE_IN_PROGRESS, 0);
    assert(!read_temp(rusd, SENSOR_MEMORY, &v) && v == -1);
    return 0;
}
