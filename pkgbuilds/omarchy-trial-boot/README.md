# omarchy-trial-boot

Boot a trial kernel or install **exactly once** on an Apple Silicon Mac, and come back to the known-good boot entry by itself on any failure: a panic, a hang anywhere from the kernel to the desktop, a watchdog reset or a missed deadline. Made for the first boots of new kernels on the Mac mini M4 (J773g), whose boot chain is m1n1 stage 2 → U-Boot → Limine (or GRUB) → kernel.

The method is [chriskearney/maclab](https://github.com/chriskearney/maclab)'s (MIT), cut down to one command and three systemd units for an attended machine with no lab server: no network, no controller Mac, no agent.

## How a trial comes back

| What goes wrong | What brings the Mac back | Lands on |
|---|---|---|
| Anything after the loader starts the trial | The loader clears the one-shot **before** it boots the entry | the default entry |
| Kernel panic, at any point | `panic=10` | the default entry |
| Kernel hard hang after `apple_wdt` probes | The watchdog U-Boot left running (30 s) | the default entry |
| Alive but stuck before the root filesystem (initramfs, missing root device) | `watchdog.open_timeout=N`: the kernel stops feeding the watchdog N s after `apple_wdt` probes unless userspace opened it | the default entry |
| Up, but never reaches boot-complete (failed units, no display manager, a failing check) | `omarchy-trial-boot-watch.service` reboots at the deadline | the default entry |
| PID 1 wedged before boot-complete | The watch unit stops feeding the watchdog after 30 s without an answer | the default entry |
| A reboot that stalls after the deadline | The watch unit leaves the watchdog armed; the hardware resets the Mac | the default entry |

The one-shot:

- **Limine** (Omarchy on Apple Silicon): the Boot Loader Interface variable `LoaderEntryOneShot`, which Limine deletes as it reads it, before it boots anything. U-Boot keeps EFI variables in RAM at runtime and names the ESP file it loads them from in `RTStorageVolatile` (`ubootefi.var`), so `arm` writes U-Boot's exported store (`VarToFile`) to that file and checks the one-shot is in it. The trial is a top-level entry `/omarchy-trial` at the end of `limine.conf`, between `# omarchy-trial-boot: begin` and `# omarchy-trial-boot: end`, so no other entry's index moves. It boots the same file as the kernel's own entry (`path: boot():/EFI/Linux/omarchy_linux-aurora.efi`), with a `cmdline:` that overrides the UKI's (systemd-stub takes the loader's command line when Secure Boot is off, which it always is behind m1n1 and U-Boot).
- **GRUB**: `omarchy_trial_next=` in `omarchy-trial.env` on the FAT ESP, read and cleared by a hook appended to `/boot/grub/custom.cfg`. GRUB cannot write `grubenv` on btrfs, so a plain `grub-reboot` would never clear. The trial entry is `/boot/grub/omarchy-trial.cfg`, `--id omarchy-trial`.

The trial's command line is the kernel entry's own plus:

```
panic=10 watchdog.open_timeout=180 systemd.watchdog_sec=0 omarchy.trial=<id> omarchy.trial_deadline=900
```

`systemd.watchdog_sec=0` keeps systemd off `/dev/watchdog0` so the watch unit can hold it, as maclab's agent does. When the trial's root filesystem may not have this package (`stage` from macOS, or `--cmdline-base` for another install), the default is `--watchdog systemd`, which writes `systemd.watchdog_sec=30` instead: systemd holds the watchdog and a healthy boot is never reset, but a boot stuck in the initramfs is then reset only if the initramfs does not run systemd.

## Use

```bash
# On the known-good boot, as root:
omarchy-trial-boot arm --verbose linux-aurora     # or: arm --uki EFI/Linux/omarchy_linux-test.efi
omarchy-trial-boot status
systemctl reboot                                  # the next boot, and only it, is the trial

# On the trial boot:
omarchy-trial-boot status                         # "This boot: TRIAL ...", the watchdog, the deadline
omarchy-trial-boot hold                           # debug at the console without the deadline

# Back on the default entry (collect also runs at boot and saves everything):
omarchy-trial-boot collect
```

Options: `--deadline SEC` (900), `--open-timeout SEC` (180; give 600 for a boot that asks for a LUKS passphrase), `--watchdog trial|systemd|none`, `--verbose` (drop `quiet splash`, `loglevel=7`), `--append "ARGS"`, `--cmdline-base "ARGS"`, `--uki PATH`, `--initrd PATH` (GRUB), `--loader limine|grub`, `--esp DIR`, `--id ID`, `--force`, `--reboot`. `stage` writes the trial entry without arming it, to pick by hand in the boot menu; it is the one command that also runs on macOS (bash 3.2) against a mounted ESP: `bash omarchy-trial-boot stage --esp "/Volumes/EFI - OMARC" linux-aurora`. `disarm` clears the one-shot and removes the trial entry.

`arm` refuses when the trial could not come back:

- the kernel's modules directory shows no `apple_wdt` (built in or module): U-Boot's running watchdog would then reset every boot about 60 s in (`--force` overrides);
- `remember_last_entry: yes` in `limine.conf` (Limine would keep booting the trial);
- a `limine.conf` checksum enrolled in Limine (it would refuse the changed menu);
- U-Boot's variable file does not carry the one-shot after the write;
- GRUB's `grub.cfg` does not source `custom.cfg` (no `41_custom`).

## Boot-complete

`omarchy-trial-boot-complete.service` runs after `multi-user.target`, `graphical.target` and `boot-complete.target` on a trial boot and runs every executable in `/etc/omarchy-trial-boot/checks.d/` (120 s each). All passing marks the trial complete: the watch unit stops the deadline and releases the watchdog with the magic close. A failing check leaves the deadline to reboot it. Units can gate it too with `RequiredBy=boot-complete.target` and `Before=boot-complete.target` (for example `systemd-boot-check-no-failures.service`). A check that the GPU driver bound, say:

```bash
#!/bin/bash
# /etc/omarchy-trial-boot/checks.d/10-gpu
[[ -e /dev/dri/renderD128 ]]
```

## What collect saves

On the boot after a trial, `omarchy-trial-boot-collect.service` (or `omarchy-trial-boot collect`) writes `/var/lib/omarchy-trial-boot/trials/<id>/collected-<time>/` (mode 700):

- `summary.txt`: the verdict, the error lines from the trial's journal and its last lines;
- `journal-<boot>.txt`, `kernel-<boot>.txt`, `warnings-<boot>.txt` for every boot that ran the trial;
- `pstore/`: anything in `/sys/fs/pstore` and `/var/lib/systemd/pstore`;
- `boot-<boot>.env`: what the watch unit recorded (start, watchdog, result);
- `pending.env`, `boots.txt`, `cmdline-now.txt`.

Verdicts: `PASSED`; `FAILED: MISSED THE DEADLINE`; `CRASHED OR HUNG` (reached the root filesystem, then reset without a result); `NO TRIAL BOOT REACHED THE ROOT FILESYSTEM` (stopped in the kernel, device tree or initramfs); `NOT ATTEMPTED` (the loader never took the one-shot, which collect then clears); `HELD`.

Limits, as maclab measured them on an M1 Air: Apple Silicon Macs have **no pstore backend** (no ramoops region in the device tree; EFI pstore is off by default and would land in U-Boot's RAM store anyway), so a panic message reaches only the screen or a serial console. Writes in the last second or two before a panic are lost, so the trial's journal can end before the crash; the watch unit runs `journalctl --sync` every 15 s to narrow that. Boot an attended trial with `--verbose` and watch the screen, or photograph it.

## Not verified on the M4 yet

Read from source and from maclab's M1/M3 measurements, not yet observed on J773g:

- U-Boot arms the watchdog on the M4: `t8132.dtsi` gives the watchdog `"apple,t8132-wdt", "apple,t8103-wdt"`, and both U-Boot's and Linux's `apple_wdt` match `apple,t8103-wdt`. Look for `WDT: Started watchdog@... with servicing (60s timeout)` on U-Boot's screen.
- The M4's secondary iBoot watchdog is disarmed by m1n1 (`wdt-version` 2/3), so it does not reset a slow boot at 120 s.
- A watchdog or panic reset comes back through iBoot to the default startup disk. Without the SMC `reboot` cell (Gravity patch 0067) a reset once landed in macOS recovery on this mini; if it does, pick the Linux volume in the startup picker and the default entry boots.

## Files

- `/usr/bin/omarchy-trial-boot`
- `/usr/lib/systemd/system/omarchy-trial-boot-{watch,complete,collect}.service`, enabled statically (each is a no-op unless its condition holds)
- `/etc/omarchy-trial-boot/checks.d/`
- `/var/lib/omarchy-trial-boot/` (`pending`, `trials/<id>/`), `/run/omarchy-trial-boot/`
- On the ESP: the Limine block in `limine.conf`, `ubootefi.var` (and `ubootefi.var.pre-omarchy-trial`, U-Boot's file before the first arm); or for GRUB `omarchy-trial.env`, `/boot/grub/omarchy-trial.cfg` and the `custom.cfg` hook (`custom.cfg.pre-omarchy-trial`).

`test.sh` runs every path above against fixture machines (`bash pkgbuilds/omarchy-trial-boot/test.sh`); `check()` runs it in the package build.
