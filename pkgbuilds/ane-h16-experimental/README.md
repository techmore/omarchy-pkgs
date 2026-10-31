# ane-h16-experimental

Opt-in, experimental Neural Engine (ANE) bring-up for the Mac mini M4 (J773g, T8132) on the techmore `elementaryos-mseries` kernel (`linux-aurora` 7.3.0.aurora90). It packages `ane_h16.ko` from [joshuaswarren/omarchy-ane](https://github.com/joshuaswarren/omarchy-ane) `v0.5.7` (`ane/h16`) as a DKMS module, with two device tree overlays checked against the J773g ADT and a helper, `ane-h16-experimental`.

**This is not ANE support.** `ane_h16` performs no inference and registers no device for user space. Its best possible outcome is a log that tells the next developer what the M4's ANE does when Linux powers it and starts its firmware. No M4 has run any of it yet: upstream tested it only in a userspace simulation.

## What installing it changes

Nothing that runs. Installing the package:

- builds `ane_h16.ko` with DKMS for every installed kernel that has headers. The module has no device table and the package blacklists it (`/usr/lib/modprobe.d/ane-h16-experimental.conf`), so nothing loads it. Its probe also refuses without `optin=t8132`.
- installs two overlays in `/usr/lib/omarchy-mac-boot/dtb-overlays/t8132-j773g/`. Each carries an `omarchy,opt-in` key, so omarchy-mac-boot applies it only when that key is a line of `/etc/omarchy-mac-boot/dtb-overlays.opt-in`. Until then `boot.bin` gets the device trees the kernel shipped. omarchy-mac-boot's pacman hook still reruns `update-m1n1` on install and removal, as it does after a kernel update.
- installs `/usr/bin/ane-h16-experimental` and a copy of omarchy-ane's firmware fetcher. No firmware is fetched until you run `sudo ane-h16-experimental firmware`.

## Stages

Run them in order. Stop at the first result you did not expect and keep the log (`ane-h16-experimental log`).

| Step | Needs | Touches hardware? | What it tells you |
|---|---|---|---|
| `overlay dt` + reboot | – | No. The ANE node is added with five power domains, which the platform core does not attach, and nothing built in binds it | The node is in `/proc/device-tree/soc/ane@500000000` |
| `load dt` | overlay `dt` (or `full`) | **No MMIO.** Parses the DT and the boot ADT copy m1n1 leaves in memory | `RESULT stage=0 ... verdict=PASS reason=dt-parse-only`, plus `adt seg0/seg1` lines if iBoot preloaded the ANE firmware |
| `load status` | overlay `dt` | **Yes.** Powers ANE_SYS, ANE_MPM, ANE_CPU, ANE_TD and ANE_BASE, waits for each to report on, then reads RVBAR, CPU_STATUS, SCRATCH0-7 and two mailbox words. Writes nothing to the engine. Powers off again when done | `RESULT stage=1 ... PASS reason=ps-guard+reads`, or `FAIL pmgr-actual-stuck` (a domain never came on; the engine was not touched) |
| `firmware` | network | No (downloads ~1.5 MB from Apple's macOS 27.0 restore image by HTTP range requests and checks it against the module's SHA-256 pin) | `/usr/lib/firmware/apple/ane/h16_ane_fw_leto_j7x.macho` |
| `overlay full` + reboot | – | **Yes, on every boot**: the built-in apple-dart driver probes the three ANE DARTs, powering ANE_SYS and resetting them | `ane-h16-experimental status` shows the DARTs |
| `load boot --reboot-is-ok` (optionally `--hello`) | overlay `full`, firmware | **Yes, and not reversible without a reboot.** Validates the preloaded firmware, maps it through the DART, writes RVBAR, releases the ANE CPU and waits for its wake word; `--hello` then answers the RTKit HELLO | `RESULT stage=3 ...` |

Typical session:

```
sudo pacman -S ane-h16-experimental         # needs linux-aurora-headers
sudo ane-h16-experimental overlay dt        # rebuilds m1n1 stage 2
sudo reboot
sudo ane-h16-experimental load dt
sudo ane-h16-experimental load status
ane-h16-experimental status
```

`ane-h16-experimental overlay off` removes both keys; reboot to drop the node.

## What can go wrong

- **The overlay does not apply.** omarchy-mac-boot then keeps the kernel's device tree and prints `dtb-overlays: ... does not apply`. Nothing changes; `status` shows no ANE node.
- **`load status` fails with `pmgr-actual-stuck`.** A power domain did not report on within 500 ms. The engine window was not read. Keep the log; the power state for ANE_SYS is managed by PMP on macOS (`notify_pmp`), which Linux does not do yet.
- **`load status` hangs or the Mac resets.** Reading the engine window of an ANE that is not really powered can raise an SError. Hold the power button, boot, run `sudo ane-h16-experimental overlay off` (or see Recovery) and keep any pstore log.
- **`overlay full` makes boot fail or the log fills with DART faults.** apple-dart owns the ANE DARTs on every boot with that key. Use Recovery and go back to `overlay dt`.
- **`load boot` refuses with `segment-ranges`.** Expected on the J773g ADT we checked: its TEXT `segment-ranges` entry ends in the 64-bit word `0x1000c0000` (size `0xc0000` with the upper word 1), which the module reads as a size and refuses because it is not the pinned `0xc0000`. Nothing is written before that check. Send the log upstream rather than patching around it.
- **`load boot` gets further than that.** Then the ANE CPU runs until a reboot, the mapping stays, and `ane_h16` must not be unloaded (the helper refuses). A hang is possible. Reboot after every boot run.
- **A kernel update.** DKMS rebuilds the module if `linux-aurora-headers` for the new kernel is installed. The overlays only depend on the device tree paths (`/soc/interrupt-controller@381000000`, `/soc/power-management@380700000/power-controller@{570,c000,c008,c010,c018}`); if a future kernel renames them, the overlay stops applying and nothing else happens. If a kernel ships its own `apple,t8132-ane` node, both overlays skip themselves.

## Recovery

The opt-in keys live in `/etc/omarchy-mac-boot/dtb-overlays.opt-in` and take effect only when m1n1 stage 2 is rebuilt. If the Mac does not boot with an overlay:

1. Boot the previous m1n1 stage 2 or a rescue system (the image's normal recovery path).
2. Delete the lines `ane-h16-dt` and `ane-h16-experimental` from that file on the installed system.
3. Run `update-m1n1` from the installed system (chroot) and reboot.

Removing the package (`pacman -R ane-h16-experimental`) also deletes both keys, the overlays and the fetched firmware, and rebuilds m1n1 stage 2.

## Without omarchy-mac-boot

On an image that does not apply `/usr/lib/omarchy-mac-boot/dtb-overlays` the helper's `overlay` command refuses. Apply `/usr/lib/omarchy-mac-boot/dtb-overlays/t8132-j773g/omarchy-ane-h16-dt.dtbo` yourself with `fdtoverlay` (dtc 1.7.1 or newer) to the `t8132-j773g.dtb` your boot loader passes, keeping the original to go back to.

## Sources and changes

- `ane_h16` from omarchy-ane `v0.5.7` (`ane/h16`, GPL-2.0-only OR MIT), with two patches:
  - `0001-ane_h16-default-to-stage-dt.patch`: a load without `stage=` runs `stage=dt` (upstream defaults to `stage=status`).
  - `0002-ane_h16-attach-the-ANE-power-domains.patch`: attach the five power domains by index and link them for runtime PM, as `ane_h15` does. Without it the platform core attaches none of them (it does so only for a node with exactly one), `pm_runtime_get_sync()` powers nothing, and `stage=status` can only end in `pmgr-actual-stuck`. Once `stage=boot` has touched the firmware the patch also keeps the domains on (upstream's `remove()` already does), instead of powering the ANE off under a released CPU.
- The overlays are upstream's `t8132-ane-experimental.dts` with the AIC target path this kernel uses (`interrupt-controller@381000000`; upstream names `@381180000`, which does not exist in this tree, so upstream's overlay never applies here), split in two so the DARTs are a separate opt-in, and with `omarchy,skip-if-compatible`.
- `omarchy-ane-firmware-fetch` from omarchy-ane `v0.5.7`. Apple's firmware is never redistributed: each Mac fetches its own copy.

The recipe's `check()` runs upstream's userspace simulation (with both patches), applies both overlays to the J773g device tree compiled from the kernel commit `linux-aurora` pins, and builds the module with DKMS against the installed `linux-aurora-headers`.
