#!/bin/sh
# Boot the ISO in QEMU and check the installer came up.
#
# Checks the serial console, not the graphical path. That is deliberate: the
# graphical path is optional on the medium and the fallback is the one that has
# to work everywhere, so it is the one CI proves. A smoke test that only
# exercises the preferred path leaves the important one untested.

. "$(dirname "$0")/../../tools/common.sh"

LOG=${SERIAL_LOG:-$BUILD_DIR/serial.log}

step "Boot smoke test"

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
	say "qemu not installed - skipping"
	exit 0
fi
if ! ls "$BUILD_DIR"/*.iso >/dev/null 2>&1; then
	say "no ISO built - skipping"
	exit 0
fi

SMOKE_TIMEOUT=${SMOKE_TIMEOUT:-180} sh "$REPO_ROOT/tools/qemu.sh" smoke

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
