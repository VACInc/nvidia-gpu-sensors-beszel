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
| GeForce RTX 3090 | GA102 | n/a (Blackwell-only registers) | n/a on this interface |

Driver 610.43.02 on all of the above. Community reports of `n/a` hotspot on
GB203/GB206 appear to be driver-version related (595.x); 610.x works here.

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

## Layout

```
src/       patched nvidia-gpu-sensors (MIT, upstream copyright preserved)
beszel/    update-hwmon.sh, systemd units, beszel-agent drop-in
install.sh / uninstall.sh
```
