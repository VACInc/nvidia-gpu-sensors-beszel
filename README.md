# nvidia-gpu-sensors-beszel

NVIDIA Blackwell **hotspot** and **VRAM** temperatures, charted and alertable in
[Beszel](https://beszel.dev) — plug and play.

```
RTX PRO 6000 Blackwell Workstation Edition 3 Hotspot   41.6 °C
RTX PRO 6000 Blackwell Workstation Edition 3 VRAM      40.0 °C
GeForce RTX 5090 Hotspot                               48.6 °C
GeForce RTX 5060 Ti Hotspot                            57.5 °C
```

## Why

NVIDIA removed the hotspot sensor from NVML/`nvidia-smi` for the RTX 50 /
Blackwell generation, so no Linux monitoring stack sees it — while the silicon
still throttles on it at 107 °C. Community reporting has tied hidden hotspot
readings to real thermal defects (dry TIM, cards throttling while the "GPU
temp" looks fine). On one of our RTX 5060 Ti cards the core reported 51 °C
while the hotspot was at 57.5 °C and VRAM at 58 °C — that gap is exactly what
you want on a dashboard with an alert on it.

[philipl/nvidia-gpu-sensors](https://github.com/philipl/nvidia-gpu-sensors)
reverse-engineered the sensor access. This repo packages a **fixed** copy of
that tool plus the glue that lands the readings in Beszel next to your
existing sensors.

## What's changed vs upstream

Vendored from upstream @ `505a11e` (MIT, license preserved), with these fixes:

1. **Multi-GPU enumeration.** Upstream opens `/dev/nvidia<N>` using the RM
   `deviceInstance`, but the RM's numbering and the Linux device minors can be
   permuted. The kernel's `nv_is_gpu_accessible` then rejects device allocs
   with a silent `NV_ERR_INSUFFICIENT_PERMISSIONS` — on a 7-GPU box only 4
   GPUs enumerated, partly by luck of leaked fds. Fixed by mapping
   gpuId → minor via `NV_ESC_CARD_INFO` (what `nvidia-smi` does) and checking
   `NV_ESC_WAIT_OPEN_COMPLETE` after each open (device opens are async on
   newer drivers).
2. **Correct hotspot attribution.** Upstream paired GPUs with PCI BDFs by
   sorted sysfs order, so the hotspot value could be printed on another GPU's
   row. Each GPU's BAR0 is now mapped via its own
   `NV0000_CTRL_CMD_GPU_GET_PCI_INFO` result.
3. **Loud diagnostics.** Every setup failure reports the gpuId, step, and RM
   status code instead of silently dropping the GPU.
4. **`--csv` mode.** BDF-keyed machine-readable output for scripting:
   `0000:41:00.0,37.1,38.0,39.8,0.805,`
5. **`--detail` mode.** The `--csv` columns plus which die sensor is the
   hottest and which GDDR chip is the hottest:
   `0000:41:00.0,45.0,60.0,52.3,0.9,0.9,0xAD0A94,52.3,D1B,64,32`
   (hot spot register, its value, hottest chip label, its value, chip count).

## How the Beszel side works

Beszel's agent has no custom-metric hook, but it honours `SYS_SENSORS` — a
/sys root override meant for containerized agents. A systemd timer (30 s)
builds a shadow tree at `/run/gpu-sensors-sys/class/hwmon/`:

- symlinks to every **real** hwmon entry (existing sensors keep working), and
- one tiny synthetic hwmon device **per reading**, fed by
  `nvidia-gpu-sensors --csv`.

The display string goes in the device's `name` file (passed through verbatim)
rather than a `tempN_label` (which gopsutil lowercases and underscores), so
sensors show up with the same names Beszel already uses for the GPUs
themselves: nvidia-smi's name minus the `NVIDIA ` prefix, with the index
appended only when several GPUs share a name.

A one-line drop-in points `beszel-agent` at the shadow tree. Nothing else
about the agent changes, and removing the drop-in reverts everything.

Boards that report NVIDIA's T.Limit (`temperature.gpu.tlimit`, the margin in
degrees C to the slowdown temperature; Blackwell here) also get a
`<GPU> T.Limit` sensor. Lower is hotter; throttling starts near 0.

## Install

Requirements: NVIDIA proprietary/open driver (verified on 610.43.02), root,
`gcc`, systemd, and a native `beszel-agent` service.

```sh
sudo ./install.sh
```

Builds the tool, installs to `/opt/gpu-hotspot/`, enables
`gpu-hotspot-hwmon.timer`, adds the `SYS_SENSORS` drop-in, and restarts the
agent. Idempotent; survives reboots. Remove with `sudo ./uninstall.sh`.

## Verified hardware

| GPU | Chip | Hotspot | VRAM temp |
|---|---|---|---|
| RTX PRO 6000 Blackwell Workstation Edition | GB202 | yes | yes |
| GeForce RTX 5090 | GB202 | yes | yes |
| GeForce RTX 5060 Ti | GB206 | yes | yes |
| GeForce RTX 3090 | GA102 | yes | yes |

Driver 610.43.02 on all of the above. Community reports of `n/a` hotspot on
GB203/GB206 appear to be driver-version related (595.x); 610.x works here.

Ampere uses a different layout and is handled separately: the on-die sensors
live in the low NV_THERM window (`0x0203B8`–`0x0204C4`) rather than Blackwell's
`0xAD0A90..`, and the memory-junction temperature comes from the GDDR6/6X
controller register (`0xE2A8`, or `0xEE50` on GA104) instead of RUSD, which
publishes no memory sensor on this generation. The Ampere offsets were
confirmed on a GA102 RTX 3090 under a sustained 283 W load: core went 37 → 72 °C
while the selected hotspot sensor tracked 47 → 87 °C and VRAM 44 → 70 °C. Two
constant-valued words in the same window (`0x020074`, `0x020858`) are limits,
not sensors, and are excluded. Ampere boards are matched by PCI device ID, so
an unlisted card degrades to `n/a` instead of reading unknown registers.

## Safety notes

- The tool is **read-only**: BAR0 is mmapped read-only and every RM ioctl is a
  query. There is no path that writes to the GPU or to persistent state.
- The upstream author cautions that reading beyond the known register windows
  can put a GPU into a state that needs a reset; this tool maps only the
  minimal NV_THERM window and gates Blackwell-only offsets on the chip ID.
  Many thousands of 30-second one-shot cycles across mixed Ampere/Blackwell
  fleets have been uneventful for us.
- Not affiliated with NVIDIA. The interfaces are unofficial and may change in
  future drivers.

## Per-chip VRAM and the health watch

`--detail` reads every GDDR chip's own sensor (register layout from LACT
PR #1125): partition `p` keeps four 32-bit slots at `0x9024C0 + p*0x4000` and
a valid mask in bits 24..27 of `0x9024D0 + p*0x4000`. Byte 2 is the front
chip, byte 3 the back chip on clamshell boards (`0x900200` bit 22), and
C = 2 * min(raw, 0x50) - 40. Labels name the chip: `D1B` is partition D,
chip 1, back side. Validated read-only on GA102 (3090, 24 chips), GA106
(A2000, 6 chips) and GB202 (RTX PRO 6000, 32 chips); GA107 reports none.
The single VRAM value Beszel charts is unchanged.

`health/` installs `gpu-health-watch` (`sudo health/install.sh`), a 30 s
timer that is separate from the Beszel publisher:

- logs one line per card to `/var/log/gpu-health/gpu-YYYY-MM-DD.log` (30 days):
  core, hot spot and its sensor register, hottest VRAM chip, T.Limit, power,
  and slowdown seconds per reason since the previous sample;
- sends ntfy (`/etc/ntfy.env`, `NTFY_URL` + `NTFY_AUTH=user:password`) when
  thermal or power-brake slowdown exceeds 30 s in 5 min (power cap is logged
  only). Software thermal time counts only with a valid core temperature at
  or above 70 C (`GPU_HEALTH_SW_THERM_MIN_C`), never with `[N/A]`;
- alerts when PCIe replay or rollover counters, PCIe AER totals, or NVLink
  error counters rise (polled every 5 min). Replays and rollovers have separate
  deltas. NVLink 1 through 5 error counters are parsed; traffic and BER rates
  are excluded. One successfully delivered alert per card and kind per hour.
  Failed alerts stay pending, with at most one retry per key per minute,
  including one-shot errors that no longer rise;
- on Jetson (no NVML), logs the hottest thermal zone, margin to the 99 C
  throttle trip, active throttle alerts and soctherm over-current counters,
  and alerts on > 30 s of throttling in 5 min or any new over-current event.

Tests: `tests/health-watch.sh` and `tests/health-regressions.sh` (fake nvidia-smi,
ntfy and sysfs), plus `tests/detail.c` and `tests/ga107.c`.

## Layout

```
src/       patched nvidia-gpu-sensors (MIT, upstream copyright preserved)
beszel/    update-hwmon.sh, systemd units, beszel-agent drop-in
health/    gpu-health-watch (thermal log + slowdown/link-error ntfy)
install.sh / uninstall.sh
```

### RTX 3050 6GB (GA107)

PCI `10de:2584`, chipset `0x177`, supports a narrowly gated read of the
Ampere hotspot register `0x02046C`. Chipset extraction masks `0x1ff00000`
(as Linux nouveau does); the observed BOOT0 is `0xb77000a1`.
The tagged Q8.8 word `0x40002c30` decoded to 44.1875 C with core at 34.2 C.
Other GA107 boards are not implicitly enabled.

VRAM temperature remains unavailable on the tested board: RUSD returns no
reading and no GA107 memory-register mapping has been validated. No guessed
VRAM register or fabricated sensor is published. Existing supported boards
are unchanged.

Regression test: `gcc -std=gnu11 -Wall -Wextra -O2 tests/ga107.c -o /tmp/ga107-test && /tmp/ga107-test`.

Hardware validation on 2026-09-18 (driver 610.57.04): a bounded 45-second
CUDA load moved core from 34.2 C to 70.4 C and hotspot from 44.2 C to 82.9 C,
at approximately 69.8 W and 100% utilization. CSV memory remained empty.
The hotspot tracks load; this does not establish a VRAM register.
