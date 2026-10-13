#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
provider=$repo/scripts/dwm-settings-provider

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

mkdir -p "$work/bin" "$work/runtime"
cat >"$work/bin/bluetoothctl" <<'EOF'
#!/bin/sh
# bluetoothctl must not be invoked when busctl reports BlueZ daemon is absent
touch "${DWM_TEST_BLUETOOTHCTL_INVOKED:?}"
sleep 2
exit 1
EOF
chmod +x "$work/bin/bluetoothctl"

# When busctl reports org.bluez is absent (exit 1), bluetooth capability should
# fail-fast without invoking bluetoothctl for 2 seconds.
cat >"$work/bin/busctl" <<'EOF'
#!/bin/sh
if [ "$1" = "--system" ] && [ "$2" = "status" ] && [ "$3" = "org.bluez" ]; then
    exit 1
fi
exit 0
EOF
chmod +x "$work/bin/busctl"

start_time=$(date +%s%N)
output=$(DWM_TEST_BLUETOOTHCTL_INVOKED="$work/bluetoothctl_invoked" XDG_RUNTIME_DIR="$work/runtime" PATH="$work/bin:$PATH" "$provider" discover)
end_time=$(date +%s%N)
elapsed_ms=$(( (end_time - start_time) / 1000000 ))

if [ -f "$work/bluetoothctl_invoked" ]; then
    printf 'bluetoothctl was invoked despite busctl reporting inactive BlueZ\n' >&2
    exit 1
fi

# Assert bluetooth capability is reported as unavailable without waiting 2s
printf '%s\n' "$output" | grep -Fqx \
    'capability	bluetooth	bluez	Bluetooth	unavailable	delegated	bluetoothctl	BlueZ tools are installed, but no daemon or adapter is responding'

# Assert canonical section ordering
sections=$(printf '%s\n' "$output" | awk -F '\t' '$1 == "capability" { if ($2 != last) { print $2; last = $2 } }')
expected_sections=$(printf '%s\n' "displays" "input" "network" "bluetooth" "audio" "power" "defaults" "appearance" "system")
[ "$sections" = "$expected_sections" ]

printf 'test-settings-provider-perf: PASS (elapsed %sms)\n' "$elapsed_ms"
