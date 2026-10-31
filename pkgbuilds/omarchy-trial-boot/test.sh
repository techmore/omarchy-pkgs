#!/bin/bash
# omarchy-trial-boot against fixture machines: the Limine one-shot (efivarfs
# and U-Boot's variable file), the GRUB one-shot (env file on the ESP and the
# custom.cfg hook), the trial command line, the watch and complete units, and
# collect's verdicts. Every path the tool touches is redirected under a
# scratch directory; findmnt and journalctl are stand-ins, grub-editenv is the
# real one where installed. Runs as root or not, on Linux, and on macOS for
# the stage --esp path (also under /bin/bash 3.2 there).
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
tool=${OMARCHY_TRIAL_BOOT_BIN:-$here/omarchy-trial-boot}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail() {
  echo "not ok - $1" >&2
  [[ $# -lt 2 ]] || printf '%s\n' "$2" >&2
  exit 1
}
pass() { echo "ok - $1"; }

bash -n "$tool" || fail "the tool parses"
for unit in "$here"/*.service; do
  grep -q '^ExecStart=/usr/bin/omarchy-trial-boot \(watch\|complete\|collect --quiet\)$' "$unit" ||
    fail "${unit##*/} runs the packaged tool"
done
pass "the tool parses and every unit runs it"

# --- stand-ins -------------------------------------------------------------------
mkdir -p "$T/bin"
cat >"$T/bin/findmnt" <<'EOF'
#!/bin/bash
# Mounts from $FAKE_MOUNTS: TARGET FSTYPE UUID SOURCE per line.
mode="" arg="" fields=""
while (($#)); do
  case $1 in
    --mountpoint) mode=mp arg=$2; shift 2 ;;
    -T) mode=t arg=$2; shift 2 ;;
    -o) fields=$2; shift 2 ;;
    *) shift ;;
  esac
done
best="" bestlen=0
while read -r target fstype uuid source; do
  [[ -n $target ]] || continue
  if [[ $mode == mp ]]; then
    [[ $target == "$arg" ]] || continue
  else
    [[ $arg == "$target" || $arg == "$target"/* ]] || continue
  fi
  if (( ${#target} > bestlen )); then best="$target $fstype $uuid $source"; bestlen=${#target}; fi
done <"$FAKE_MOUNTS"
[[ -n $best ]] || exit 1
read -r target fstype uuid source <<<"$best"
case $fields in
  FSTYPE) echo "$fstype" ;;
  UUID) echo "$uuid" ;;
  SOURCE,FSTYPE,UUID,TARGET) echo "$source $fstype $uuid $target" ;;
esac
EOF
cat >"$T/bin/journalctl" <<'EOF'
#!/bin/bash
# Boots from $FAKE_JOURNAL/boots (one id per line, oldest first) and
# $FAKE_JOURNAL/<id>.log.
case " $* " in
  *" --sync "*) exit 0 ;;
  *" --list-boots "*)
    n=0; total=$(wc -l <"$FAKE_JOURNAL/boots")
    while read -r id; do n=$((n + 1)); echo "$((n - total)) $id Fri 2026-10-31"; done <"$FAKE_JOURNAL/boots"
    exit 0 ;;
esac
while (($#)); do
  if [[ $1 == -b ]]; then cat "$FAKE_JOURNAL/$2.log" 2>/dev/null; exit 0; fi
  shift
done
EOF
cat >"$T/bin/fake-reboot" <<'EOF'
#!/bin/bash
echo "reboot ${1:-}" >>"$FAKE_REBOOT_LOG"
EOF
if ! command -v timeout >/dev/null 2>&1; then
  printf '#!/bin/bash\nshift\nexec "$@"\n' >"$T/bin/timeout"
fi
if ! command -v grub-editenv >/dev/null 2>&1; then
  cat >"$T/bin/grub-editenv" <<'EOF'
#!/bin/bash
# GRUB's env block: a header, NAME=VALUE lines, # padding to 1024 bytes.
file=$1 cmd=$2; shift 2
body() { [[ -f $file ]] && grep -v '^#' "$file" | tr -d '#' | grep . || true; }
write() { { echo '# GRUB Environment Block'; cat; } | head -c 1024 >"$file.new"; s=$(wc -c <"$file.new");
  while ((s < 1024)); do printf '#' >>"$file.new"; s=$((s + 1)); done; mv "$file.new" "$file"; }
case $cmd in
  create) [[ -f $file ]] || printf '' | write ;;
  list) body ;;
  set) { body | grep -v "^${1%%=*}=" || true; echo "$1"; } | write ;;
  unset) { body | grep -v "^$1=" || true; } | write ;;
esac
EOF
fi
chmod +x "$T/bin"/*
export PATH="$T/bin:$PATH"

export OMARCHY_TRIAL_OS=Linux \
  OMARCHY_TRIAL_STATE=$T/state OMARCHY_TRIAL_RUN=$T/run OMARCHY_TRIAL_EFIVARS=$T/efivars \
  OMARCHY_TRIAL_CMDLINE=$T/cmdline OMARCHY_TRIAL_UPTIME=$T/uptime OMARCHY_TRIAL_BOOT_ID=$T/boot_id \
  OMARCHY_TRIAL_WATCHDOG=$T/watchdog OMARCHY_TRIAL_GRUB_DIR=$T/boot/grub OMARCHY_TRIAL_BOOT_DIR=$T/boot \
  OMARCHY_TRIAL_CHECKS=$T/checks OMARCHY_TRIAL_MODULES=$T/modules \
  OMARCHY_TRIAL_LIMINE_DEFAULT=$T/default-limine OMARCHY_TRIAL_UNIT_DIR=$T/units \
  OMARCHY_TRIAL_PSTORE=$T/pstore OMARCHY_TRIAL_TICK=0.1 OMARCHY_TRIAL_ESCALATE=0 \
  OMARCHY_TRIAL_PID1_CHECK=0 OMARCHY_TRIAL_REBOOT=$T/bin/fake-reboot OMARCHY_TRIAL_NO_LOCK=1 \
  FAKE_MOUNTS=$T/mounts FAKE_JOURNAL=$T/journal FAKE_REBOOT_LOG=$T/reboots
mkdir -p "$T/efivars" "$T/units" "$T/checks" "$T/journal" "$T/pstore" "$T/modules/7.2.0-aurora"
: >"$T/mounts"
: >"$T/journal/boots"
touch "$T/units/omarchy-trial-boot-watch.service"
echo linux-aurora >"$T/modules/7.2.0-aurora/pkgbase"
echo 'kernel/drivers/watchdog/apple_wdt.ko' >"$T/modules/7.2.0-aurora/modules.builtin"
echo 'root=UUID=1111 rw quiet splash' >"$T/cmdline"
echo '120.00 100.00' >"$T/uptime"
echo boot-armed >"$T/boot_id"

hex() { od -An -v -tx1 "$1" | tr -d ' \n'; }
utf16hex() {
  local s=$1 i
  for ((i = 0; i < ${#s}; i++)); do printf '%02x00' "'${s:i:1}"; done
  printf '0000'
}
bytes_from_hex() {
  local h=$1 i
  for ((i = 0; i < ${#h}; i += 2)); do printf "\\x${h:i:2}"; done
}

# --- a Limine Mac ----------------------------------------------------------------
esp=$T/esp
mkdir -p "$esp/EFI/BOOT" "$esp/EFI/Linux"
zeros=$(printf '%0128d' 0)
printf 'MZ...limine.conf...++CONFIG_B2SUM_SIGNATURE++%s...' "$zeros" >"$esp/EFI/BOOT/BOOTAA64.EFI"
: >"$esp/EFI/Linux/omarchy_linux-aurora.efi"
cat >"$esp/limine.conf" <<'EOF'
timeout: 5
default_entry: 2
interface_branding: Omarchy Bootloader

/+Omarchy
comment: machine-id=0123456789abcdef0123456789abcdef
  //linux-aurora
  comment: Kernel version: 7.2.0-aurora
    protocol: efi
    path: boot():/EFI/Linux/omarchy_linux-aurora.efi#ab12
    cmdline: root=UUID=2222 rw rootflags=subvol=@ quiet splash
EOF
cp "$esp/limine.conf" "$T/limine.conf.orig"
echo "$esp vfat 5E1F-0A0A /dev/nvme0n1p4" >>"$T/mounts"

# U-Boot's runtime variable store, already holding the one-shot (U-Boot
# regenerates VarToFile itself on the Mac; the fixture has it ready).
oneshot_hex=$(utf16hex omarchy-trial)
bytes_from_hex "07000000" >"$T/efivars/RTStorageVolatile-b2ac5fc9-92b7-4acd-aeac-11e818c3130c"
printf 'ubootefi.var\0' >>"$T/efivars/RTStorageVolatile-b2ac5fc9-92b7-4acd-aeac-11e818c3130c"
v2f=$T/efivars/VarToFile-b2ac5fc9-92b7-4acd-aeac-11e818c3130c
{ bytes_from_hex 07000000; printf '\0\0\0\0\0\0\0\0UbEfiVa\0'; bytes_from_hex "$oneshot_hex"; } >"$v2f"
printf 'old store' >"$esp/ubootefi.var"

block() { sed -n '/^# omarchy-trial-boot: begin/,/^# omarchy-trial-boot: end/p' "$esp/limine.conf"; }

out=$("$tool" stage --esp "$esp" --id t1 linux-aurora 2>&1) || fail "stage on a Limine Mac" "$out"
b=$(block)
[[ $b == *$'\n/omarchy-trial\n'* ]] || fail "the trial is a top-level entry named omarchy-trial" "$b"
[[ $b == *'    protocol: efi'* && $b == *'    path: boot():/EFI/Linux/omarchy_linux-aurora.efi#ab12'* ]] ||
  fail "the trial boots the entry's own UKI" "$b"
want='    cmdline: root=UUID=2222 rw rootflags=subvol=@ quiet splash panic=10 watchdog.open_timeout=180 systemd.watchdog_sec=0 omarchy.trial=t1 omarchy.trial_deadline=900'
grep -qxF "$want" "$esp/limine.conf" || fail "the trial command line is the entry's plus the trial's" "$b"
[[ $b != *machine-id* && $b != *'Kernel version'* ]] || fail "the entry's comments are not copied" "$b"
head -n "$(wc -l <"$T/limine.conf.orig")" "$esp/limine.conf" | cmp -s - "$T/limine.conf.orig" ||
  fail "the rest of limine.conf is unchanged"
pass "stage writes a top-level trial entry from the kernel's own entry, at the end of the menu"

"$tool" stage --esp "$esp" --id t1 --verbose --deadline 600 --open-timeout 300 --append 'asahi.debug=1' linux-aurora >/dev/null 2>&1 ||
  fail "restage"
[[ $(grep -c '^# omarchy-trial-boot: begin' "$esp/limine.conf") == 1 ]] || fail "restaging keeps one block"
want='    cmdline: root=UUID=2222 rw rootflags=subvol=@ loglevel=7 systemd.show_status=1 panic=10 watchdog.open_timeout=300 systemd.watchdog_sec=0 omarchy.trial=t1 omarchy.trial_deadline=600 asahi.debug=1'
grep -qxF "$want" "$esp/limine.conf" || fail "--verbose, --deadline, --open-timeout and --append" "$(block)"
pass "restaging replaces the block; --verbose drops quiet and splash"

# Options the trial sets are not inherited twice.
"$tool" stage --esp "$esp" --id t2 --cmdline-base 'BOOT_IMAGE=/x root=UUID=3 panic=0 watchdog.open_timeout=5 omarchy.trial=old' --watchdog systemd linux-aurora >/dev/null 2>&1 ||
  fail "stage with --cmdline-base"
grep -qxF '    cmdline: root=UUID=3 panic=10 watchdog.open_timeout=180 systemd.watchdog_sec=30 omarchy.trial=t2 omarchy.trial_deadline=900' "$esp/limine.conf" ||
  fail "--cmdline-base is cleaned of trial settings; --watchdog systemd" "$(block)"
pass "a base command line loses BOOT_IMAGE and old trial settings"

out=$("$tool" stage --esp "$esp" no-such-kernel 2>&1) && fail "an unknown entry is refused"
[[ $out == *'no entry named no-such-kernel'* ]] || fail "unknown entry message" "$out"
out=$("$tool" stage --esp "$esp" --deadline 10 linux-aurora 2>&1) && fail "a deadline under 60 s is refused"
pass "an unknown entry and a too-short deadline are refused"

# The kernel must take over the watchdog U-Boot leaves running.
echo 'kernel/drivers/other.ko' >"$T/modules/7.2.0-aurora/modules.builtin"
out=$("$tool" stage --esp "$esp" linux-aurora 2>&1) && fail "a kernel without apple_wdt is refused"
[[ $out == *'has no apple_wdt'* ]] || fail "apple_wdt message" "$out"
"$tool" stage --esp "$esp" --force linux-aurora >/dev/null 2>&1 || fail "--force stages a kernel without apple_wdt"
echo 'kernel/drivers/watchdog/apple_wdt.ko.zst: kernel/drivers/watchdog/x.ko' >"$T/modules/7.2.0-aurora/modules.dep"
"$tool" stage --esp "$esp" linux-aurora >/dev/null 2>&1 || fail "apple_wdt as a module is enough"
echo 'kernel/drivers/watchdog/apple_wdt.ko' >"$T/modules/7.2.0-aurora/modules.builtin"
pass "a kernel without apple_wdt is refused unless forced"

# --- arm on Limine ---------------------------------------------------------------
out=$("$tool" arm --esp "$esp" --id t3 linux-aurora 2>&1) || fail "arm on a Limine Mac" "$out"
f=$T/efivars/LoaderEntryOneShot-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
[[ $(hex "$f") == "07000000$oneshot_hex" ]] || fail "LoaderEntryOneShot is NV|BS|RT and UTF-16 omarchy-trial" "$(hex "$f")"
[[ $(hex "$esp/ubootefi.var") == "$(tail -c +5 "$v2f" | od -An -v -tx1 | tr -d ' \n')" ]] ||
  fail "U-Boot's store is written to its file on the ESP"
[[ $(cat "$esp/ubootefi.var.pre-omarchy-trial") == 'old store' ]] || fail "the first arm keeps U-Boot's old file"
grep -qx 'id=t3' "$T/state/pending" && grep -qx 'loader=limine' "$T/state/pending" &&
  grep -qx 'armed_boot_id=boot-armed' "$T/state/pending" || fail "arm records the pending trial" "$(cat "$T/state/pending")"
pass "arm sets LoaderEntryOneShot and persists U-Boot's variable store"

out=$("$tool" status --esp "$esp" 2>&1) || fail "status" "$out"
[[ $out == *'One-shot (LoaderEntryOneShot): omarchy-trial'* && $out == *'holds the one-shot'* && $out == *'Pending trial: t3'* ]] ||
  fail "status shows the armed trial" "$out"
pass "status shows the one-shot, U-Boot's file and the pending trial"

# A store that does not hold the one-shot is caught before the reboot.
cp "$v2f" "$T/v2f.good"
{ bytes_from_hex 07000000; printf '\0\0\0\0\0\0\0\0UbEfiVa\0nothing'; } >"$v2f"
out=$("$tool" arm --esp "$esp" --id t4 linux-aurora 2>&1) && fail "arm without the one-shot in U-Boot's store is refused"
[[ $out == *'would not see it'* ]] || fail "store message" "$out"
cp "$T/v2f.good" "$v2f"
pass "arm refuses when U-Boot's variable file would not carry the one-shot"

cp "$esp/limine.conf" "$T/keep.conf"
echo 'remember_last_entry: yes' >>"$esp/limine.conf"
out=$("$tool" arm --esp "$esp" linux-aurora 2>&1) && fail "remember_last_entry is refused"
[[ $out == *remember_last_entry* ]] || fail "remember message" "$out"
cp "$T/keep.conf" "$esp/limine.conf"
cp "$esp/EFI/BOOT/BOOTAA64.EFI" "$T/keep.efi"
printf 'MZ limine.conf ++CONFIG_B2SUM_SIGNATURE++%s' "$(printf '%0127d1' 0)" >"$esp/EFI/BOOT/BOOTAA64.EFI"
out=$("$tool" arm --esp "$esp" linux-aurora 2>&1) && fail "an enrolled config hash is refused"
[[ $out == *'enroll-config --reset'* ]] || fail "enrollment message" "$out"
cp "$T/keep.efi" "$esp/EFI/BOOT/BOOTAA64.EFI"
pass "remember_last_entry and an enrolled config hash are refused"

# --- the trial boot --------------------------------------------------------------
wait_for_exit() {
  local pid=$1 n=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    n=$((n + 1))
    ((n < 100)) || { kill "$pid"; fail "$2 did not finish"; }
  done
  wait "$pid"
}

echo 'root=UUID=2222 rw panic=10 watchdog.open_timeout=180 systemd.watchdog_sec=0 omarchy.trial=t3 omarchy.trial_deadline=300' >"$T/cmdline"
echo boot-trial-1 >"$T/boot_id"
echo '40.00 1.00' >"$T/uptime"
: >"$T/watchdog"
"$tool" watch 2>"$T/watch.log" &
pid=$!
sleep 0.5
grep -q '^1' "$T/watchdog" || fail "watch feeds the watchdog it holds" "$(cat "$T/watch.log")"
echo '301.00 1.00' >"$T/uptime"
wait_for_exit "$pid" "watch"
grep -qx 'reboot ' "$T/reboots" || fail "a missed deadline reboots" "$(cat "$T/watch.log")"
[[ $(tr -d '1' <"$T/watchdog") == "" ]] || fail "after a missed deadline the watchdog is not released"
env=$T/state/trials/t3/boot-boot-trial-1.env
grep -qx 'result=deadline' "$env" && grep -qx 'watchdog=held' "$env" || fail "the trial records its result" "$(cat "$env")"
pass "watch holds the watchdog and reboots a trial that misses its deadline"

# collect on the next (default) boot: the loader took the one-shot.
rm -f "$f"
echo 'root=UUID=2222 rw quiet splash' >"$T/cmdline"
echo boot-good-1 >"$T/boot_id"
printf 'boot-armed\nboot-trial-1\nboot-good-1\n' >"$T/journal/boots"
printf 'kernel: Kernel command line: omarchy.trial=t3\nsystemd[1]: Failed to start Hyprland.\n' >"$T/journal/boot-trial-1.log"
echo 'dmesg-ramoops-0' >"$T/pstore/dmesg-efi-1"
out=$("$tool" collect 2>&1) || fail "collect" "$out"
[[ $out == *'Trial t3: FAILED: MISSED THE DEADLINE'* ]] || fail "collect names the missed deadline" "$out"
[[ $out == *'Failed to start Hyprland'* ]] || fail "collect shows the trial's errors" "$out"
c=$(ls -d "$T/state/trials/t3"/collected-*)
[[ -f $c/journal-boot-trial-1.txt && -f $c/kernel-boot-trial-1.txt && -f $c/pstore/dmesg-efi-1 && -f $c/summary.txt ]] ||
  fail "collect saves the journal, kernel log, pstore and summary" "$(ls -R "$c")"
[[ ! -f $T/state/pending && -f $T/state/trials/t3/pending.env ]] || fail "collect resolves the pending trial"
pass "collect saves the failed trial's journal and pstore records and names what happened"

# A trial that reaches boot-complete.
reset_trial() {
  rm -rf "$T/run" "$T/reboots"
  : >"$T/watchdog"
  echo "id=$1" >"$T/state/pending"
  echo "loader=limine" >>"$T/state/pending"
  echo "esp=$esp" >>"$T/state/pending"
  echo "armed_boot_id=boot-armed" >>"$T/state/pending"
  echo "root=UUID=2222 rw panic=10 systemd.watchdog_sec=0 omarchy.trial=$1 omarchy.trial_deadline=300" >"$T/cmdline"
  echo "boot-$1" >"$T/boot_id"
  echo '40.00 1.00' >"$T/uptime"
}
reset_trial t5
printf '#!/bin/bash\nexit 0\n' >"$T/checks/10-ok"
chmod +x "$T/checks/10-ok"
"$tool" watch 2>"$T/watch.log" &
pid=$!
sleep 0.3
"$tool" complete 2>/dev/null || fail "complete passes with passing checks"
wait_for_exit "$pid" "watch"
[[ ! -e $T/reboots ]] || fail "a complete trial is not rebooted"
[[ $(tail -c 1 "$T/watchdog") == V ]] || fail "a complete trial releases the watchdog with the magic close"
grep -qx 'result=complete' "$T/state/trials/t5/boot-boot-t5.env" || fail "complete is recorded"
echo boot-after-t5 >"$T/boot_id"
echo 'root=UUID=2222 rw' >"$T/cmdline"
out=$("$tool" collect 2>&1) || fail "collect after a passing trial" "$out"
[[ $out == *'Trial t5: PASSED'* ]] || fail "collect passes a complete trial" "$out"
pass "a trial that reaches boot-complete releases the watchdog and passes"

reset_trial t6
printf '#!/bin/bash\nexit 3\n' >"$T/checks/20-bad"
chmod +x "$T/checks/20-bad"
"$tool" complete 2>/dev/null && fail "a failing check keeps the trial incomplete"
[[ ! -e $T/run/complete ]] || fail "no complete marker after a failing check"
rm -f "$T/checks/20-bad"
"$tool" watch 2>/dev/null &
pid=$!
sleep 0.3
"$tool" hold >/dev/null || fail "hold on a trial boot"
wait_for_exit "$pid" "watch"
[[ ! -e $T/reboots && $(tail -c 1 "$T/watchdog") == V ]] || fail "hold releases the watchdog without rebooting"
pass "a failing check blocks completion; hold stops the deadline"

# A trial that never reached the root filesystem, and a one-shot never taken.
echo boot-after-t6 >"$T/boot_id"
echo 'root=UUID=2222 rw' >"$T/cmdline"
rm -rf "$T/state/trials/t6"
printf 'boot-armed\nboot-after-t6\n' >"$T/journal/boots"
out=$("$tool" collect 2>&1) || fail "collect without a trial boot" "$out"
[[ $out == *'NO TRIAL BOOT REACHED THE ROOT FILESYSTEM'* ]] || fail "collect names an early failure" "$out"
reset_trial t7
echo boot-after-t7 >"$T/boot_id"
echo 'root=UUID=2222 rw' >"$T/cmdline"
bytes_from_hex "07000000$oneshot_hex" >"$f"
out=$("$tool" collect 2>&1) || fail "collect with the one-shot still set" "$out"
[[ $out == *'NOT ATTEMPTED'* ]] || fail "collect names an untaken one-shot" "$out"
[[ ! -e $f ]] || fail "collect clears an untaken one-shot"
reset_trial t8
echo boot-armed >"$T/boot_id"
echo 'root=UUID=2222 rw' >"$T/cmdline"
out=$("$tool" collect 2>&1) || fail "collect before the reboot"
[[ $out == *'runs at the next reboot'* && -f $T/state/pending ]] || fail "collect before the reboot leaves the trial pending" "$out"
pass "collect tells an early failure, an untaken one-shot and a trial not yet booted"

# Not a trial boot: the units do nothing.
rm -rf "$T/run" "$T/reboots"
"$tool" watch 2>/dev/null && "$tool" complete 2>/dev/null || fail "watch and complete exit 0 on a default boot"
[[ ! -e $T/run && ! -e $T/reboots ]] || fail "nothing happens on a default boot"
pass "watch and complete do nothing on a default boot"

"$tool" disarm --esp "$esp" >/dev/null 2>&1 || fail "disarm"
cmp -s "$esp/limine.conf" "$T/limine.conf.orig" || fail "disarm leaves limine.conf as it was" "$(diff "$T/limine.conf.orig" "$esp/limine.conf")"
[[ ! -e $f ]] || fail "disarm clears the one-shot"
pass "disarm removes the block and the one-shot"

# --- GRUB ------------------------------------------------------------------------
gesp=$T/esp-grub
mkdir -p "$gesp/EFI/BOOT" "$T/boot/grub"
printf 'MZ grub' >"$gesp/EFI/BOOT/BOOTAA64.EFI"
printf 'function load_video {\n}\n### BEGIN /etc/grub.d/41_custom ###\nsource ${config_directory}/custom.cfg\n' >"$T/boot/grub/grub.cfg"
printf 'menuentry "mine" {\n}\n' >"$T/boot/grub/custom.cfg"
cp "$T/boot/grub/custom.cfg" "$T/custom.orig"
: >"$T/boot/vmlinuz-linux-test"
: >"$T/boot/initramfs-linux-test.img"
echo "$T btrfs 9f8e-root /dev/nvme0n1p6[/@]" >>"$T/mounts"
echo "$gesp vfat ABCD-1234 /dev/nvme0n1p4" >>"$T/mounts"
echo 'BOOT_IMAGE=/@/boot/vmlinuz-linux root=UUID=9f8e rw rootflags=subvol=@ quiet' >"$T/cmdline"
echo boot-grub >"$T/boot_id"
rm -f "$T/state/pending"
out=$("$tool" arm --esp "$gesp" --id g1 linux-test 2>&1) || fail "arm on GRUB" "$out"
cfg=$T/boot/grub/omarchy-trial.cfg
grep -q "^menuentry 'Omarchy trial: linux-test (g1)' --class gnu-linux --id omarchy-trial {" "$cfg" || fail "the GRUB entry has the trial id" "$(cat "$cfg")"
grep -qxF $'\tlinux /@/boot/vmlinuz-linux-test root=UUID=9f8e rw rootflags=subvol=@ quiet panic=10 watchdog.open_timeout=180 systemd.watchdog_sec=0 omarchy.trial=g1 omarchy.trial_deadline=900' "$cfg" ||
  fail "GRUB boots the kernel by its btrfs subvolume path with the trial command line" "$(cat "$cfg")"
grep -qxF $'\tinitrd /@/boot/initramfs-linux-test.img' "$cfg" && grep -qxF $'\tinsmod zstd' "$cfg" &&
  grep -qxF $'\tsearch --no-floppy --fs-uuid --set=root 9f8e-root' "$cfg" && grep -qxF $'\tload_video' "$cfg" ||
  fail "GRUB entry details" "$(cat "$cfg")"
grep -q 'search --no-floppy --fs-uuid --set=omarchy_trial_esp ABCD-1234' "$T/boot/grub/custom.cfg" &&
  grep -q 'save_env -f ($omarchy_trial_esp)/omarchy-trial.env omarchy_trial_next' "$T/boot/grub/custom.cfg" &&
  head -n 2 "$T/boot/grub/custom.cfg" | cmp -s - "$T/custom.orig" || fail "the custom.cfg hook" "$(cat "$T/boot/grub/custom.cfg")"
grub-editenv "$gesp/omarchy-trial.env" list | grep -qx 'omarchy_trial_next=omarchy-trial' || fail "the GRUB one-shot is set on the ESP"
"$tool" arm --esp "$gesp" --id g1 linux-test >/dev/null 2>&1 || fail "re-arm on GRUB"
[[ $(grep -c '^# omarchy-trial-boot: begin' "$T/boot/grub/custom.cfg") == 1 ]] || fail "re-arming keeps one hook"
out=$("$tool" status --esp "$gesp" --loader grub 2>&1) || fail "GRUB status" "$out"
[[ $out == *'One-shot (omarchy_trial_next in '*'): omarchy-trial'* ]] || fail "GRUB status shows the one-shot" "$out"
"$tool" disarm --esp "$gesp" --loader grub >/dev/null 2>&1 || fail "GRUB disarm"
cmp -s "$T/boot/grub/custom.cfg" "$T/custom.orig" || fail "disarm restores custom.cfg" "$(cat "$T/boot/grub/custom.cfg")"
[[ ! -e $cfg ]] || fail "disarm removes the GRUB trial entry"
! grub-editenv "$gesp/omarchy-trial.env" list | grep -q omarchy_trial_next= || fail "disarm clears the GRUB one-shot"
pass "GRUB: the trial entry, the custom.cfg hook and the one-shot on the ESP"

printf 'function load_video {\n}\n' >"$T/boot/grub/grub.cfg"
out=$("$tool" stage --esp "$gesp" --loader grub linux-test 2>&1) && fail "a grub.cfg without 41_custom is refused"
[[ $out == *41_custom* ]] || fail "41_custom message" "$out"
pass "GRUB without 41_custom is refused"

# --- from macOS --------------------------------------------------------------------
cp "$T/limine.conf.orig" "$esp/limine.conf"
mac() { env OMARCHY_TRIAL_OS=Darwin "$@"; }
out=$(mac "$tool" stage --esp "$esp" --id m1 linux-aurora 2>&1) || fail "stage from macOS" "$out"
grep -qxF '    cmdline: root=UUID=2222 rw rootflags=subvol=@ quiet splash panic=10 watchdog.open_timeout=180 systemd.watchdog_sec=30 omarchy.trial=m1 omarchy.trial_deadline=900' "$esp/limine.conf" ||
  fail "from macOS systemd holds the watchdog (the trial root may not have the watch unit)" "$(block)"
out=$(mac "$tool" arm --esp "$esp" linux-aurora 2>&1) && fail "arm from macOS is refused"
[[ $out == *'use stage from macOS'* ]] || fail "macOS arm message" "$out"
out=$(mac "$tool" stage linux-aurora 2>&1) && fail "stage from macOS needs --esp"
mac "$tool" disarm --esp "$esp" >/dev/null 2>&1 || fail "disarm from macOS"
cmp -s "$esp/limine.conf" "$T/limine.conf.orig" || fail "disarm from macOS removes the block"
if [[ -x /bin/bash && $(/bin/bash -c 'echo ${BASH_VERSINFO[0]}') == 3 ]]; then
  out=$(mac /bin/bash "$tool" stage --esp "$esp" --id m2 linux-aurora 2>&1) || fail "stage under bash 3.2" "$out"
  grep -qF 'omarchy.trial=m2 ' "$esp/limine.conf" || fail "bash 3.2 writes the trial entry"
  mac /bin/bash "$tool" disarm --esp "$esp" >/dev/null 2>&1 || fail "disarm under bash 3.2"
  pass "stage and disarm run under macOS's bash 3.2"
fi
pass "from macOS: stage the trial entry on the ESP for the boot menu, never arm"

echo "all omarchy-trial-boot tests passed"
