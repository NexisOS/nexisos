#!/bin/sh
# Boot the ISO in QEMU and check the installer came up.
#
# Checks the serial console, not the graphical path. That is deliberate: the
# graphical path is optional on the medium and the fallback is the one that has
# to work everywhere, so it is the one CI proves. A smoke test that only
# exercises the preferred path leaves the important one untested.
# Set NEXIS_REQUIRE_SMOKE=1 in CI so missing prerequisites are failures.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
. "$REPO_ROOT/tools/common.sh"

IMAGE_DIR=${IMAGE_DIR:-$REPO_ROOT/build/installer/images}
LOG=${SERIAL_LOG:-$REPO_ROOT/build/installer/serial.log}

step "Boot smoke test"

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
	skip "qemu-system-x86_64 is not installed"
fi
if ! command -v timeout >/dev/null 2>&1; then
	die "timeout is required to bound the QEMU smoke test"
fi

ISO=${NEXIS_INSTALLER_ISO:-}
if [ -n "$ISO" ]; then
	[ -f "$ISO" ] || die "installer ISO not found: $ISO"
else
	for candidate in "$IMAGE_DIR"/*.iso; do
		[ -f "$candidate" ] || continue
		if [ -n "$ISO" ]; then
			die "more than one installer ISO found under $IMAGE_DIR" \
				"Set NEXIS_INSTALLER_ISO to select one explicitly."
		fi
		ISO=$candidate
	done
	[ -n "$ISO" ] || skip "no installer ISO found under $IMAGE_DIR"
fi

mkdir -p "$(dirname -- "$LOG")"
: > "$LOG"

say "ISO: $ISO"
say "serial log: $LOG"

# A successful boot remains running, so timeout(1) returning 124 is expected.
# Any other non-zero status is a QEMU failure rather than a guest-test result.
set +e
timeout --signal=TERM --kill-after=5s "${SMOKE_TIMEOUT:-180}s" \
	qemu-system-x86_64 \
	-machine q35,accel=tcg \
	-cpu qemu64 \
	-smp 2 \
	-m 1024M \
	-cdrom "$ISO" \
	-boot order=d \
	-display none \
	-monitor none \
	-serial "file:$LOG" \
	-no-reboot
qemu_status=$?
set -e

case $qemu_status in
	0 | 124) ;;
	*) die "QEMU failed with exit status $qemu_status" \
		"See the serial log at $LOG." ;;
esac

[ -s "$LOG" ] || die "the guest produced no serial output" \
	"The kernel did not boot, or console=ttyS0 is missing from grub.cfg."

# Each stage of the boot chain, in order. Checking them separately means a
# failure names the stage rather than saying only that the installer did not
# appear - the difference between a five-minute fix and an evening.
fail=0
check() {
	if grep -q "$1" "$LOG"; then
		printf '  ok    %s\n' "$2"
	else
		printf '  FAIL  %s\n' "$2"
		fail=1
	fi
}

step "Boot stages"
check "NexisOS: handing over"  "initramfs found the medium and switch_root'd"
check "nexis-init"             "PID 1 started"
check "service(s) declared"    "the service set loaded"
check "starting installer"     "the installer service was dispatched"

if [ "$fail" -ne 0 ]; then
	step "Serial log (last 40 lines)"
	tail -40 "$LOG" | sed 's/^/  /'
	die "the boot chain did not complete" \
		"The stage marked FAIL above is where it stopped."
fi

step "Passed"
say "the full chain reached the installer"
