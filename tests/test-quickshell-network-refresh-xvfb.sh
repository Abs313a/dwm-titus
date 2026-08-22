#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

for command_name in dbus-run-session quickshell; do
	if ! command -v "$command_name" >/dev/null 2>&1; then
		printf 'SKIP: %s is unavailable for NetworkModel snapshot test\n' "$command_name"
		exit 77
	fi
done

if [ "${DWM_NETWORK_SNAPSHOT_DBUS_SESSION:-0}" != 1 ]; then
	exec env DWM_NETWORK_SNAPSHOT_DBUS_SESSION=1 dbus-run-session -- "$0" "$@"
fi

work=$(mktemp -d)
cleanup() {
	set +e
	[ -n "${quickshell_pid:-}" ] && kill "$quickshell_pid" 2>/dev/null
	[ -n "${quickshell_pid:-}" ] && wait "$quickshell_pid" 2>/dev/null
	rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

home=$work/home
runtime=$work/runtime
config_home=$home/.config
data_home=$home/.local/share
network_test_dir=$work/network-test
mkdir -p "$config_home/quickshell" "$data_home/dwm-titus/scripts" \
	"$runtime" "$network_test_dir"
chmod 700 "$runtime"
cp -a "$repo/config/quickshell/." "$config_home/quickshell/"
mkfifo "$network_test_dir/monitor"
printf '%s\n' ethernet >"$network_test_dir/state"

cat >"$config_home/quickshell/shell.qml" <<'QML'
//@ pragma UseQApplication

import Quickshell
import Quickshell.Io
import qs.network

ShellRoot {
    NetworkModel { id: networkModel }

    IpcHandler {
        target: "network-snapshot-test"

        function state(): string { return networkModel.barIconState + "\t" + networkModel.wifiSignal; }
        function refresh(rescan: bool, origin: string): void { networkModel.refresh(rescan, origin); }
        function origin(): string { return networkModel.snapshotOrigin; }
        function closeSettings(): void { networkModel.closeSettings(); }
    }
}
QML

cat >"$data_home/dwm-titus/scripts/dwm-quickshell-network" <<'SH'
#!/bin/sh
set -eu

test_dir=${DWM_TEST_NETWORK_DIR:?}

snapshot() {
	printf '%s\n' "$*" >>"$test_dir/snapshot-args"
	count=$(cat "$test_dir/snapshot-count")
	count=$((count + 1))
	printf '%s\n' "$count" >"$test_dir/snapshot-count"
	if [ -e "$test_dir/block-next" ]; then
		block=$(cat "$test_dir/block-next")
		rm -f "$test_dir/block-next"
		: >"$test_dir/snapshot-blocked-$block"
		while [ ! -e "$test_dir/release-$block" ]; do sleep 0.02; done
	fi
	printf 'connectivity-protocol\t1\t0\n'
	printf 'provider\tnetwork\tavailable\tdelegated\tTest NetworkManager snapshot\n'
	case "$(cat "$test_dir/state")" in
	ethernet)
		printf 'network-device\tenp2s0\tethernet\tconnected\tWired connection 1\n'
		printf 'network-device\twlan0\twifi\tdisconnected\t-\n'
		;;
	wifi)
		printf 'network-device\twlan0\twifi\tconnected\tTest Wi-Fi\n'
		printf 'wifi-network\t*\tAA:BB:CC:DD:EE:01\tTest Wi-Fi\t74\tWPA2\t6\twlan0\n'
		;;
	both)
		printf 'network-device\twlan0\twifi\tconnected\tTest Wi-Fi\n'
		printf 'network-device\tenp2s0\tethernet\tconnected\tWired connection 1\n'
		printf 'wifi-network\t*\tAA:BB:CC:DD:EE:01\tTest Wi-Fi\t74\tWPA2\t6\twlan0\n'
		;;
	*)
		printf 'network-device\tenp2s0\tethernet\tdisconnected\t-\n'
		printf 'network-device\twlan0\twifi\tdisconnected\t-\n'
		;;
	esac
}

case "${1:-}" in
snapshot)
	shift
	snapshot "$@"
	;;
monitor)
	: >"$test_dir/monitor-ready"
	while IFS= read -r event; do printf '%s\n' "$event"; done <"$test_dir/monitor"
	;;
editor) exit 127 ;;
*) exit 2 ;;
esac
SH
chmod +x "$data_home/dwm-titus/scripts/dwm-quickshell-network"
printf '%s\n' 0 >"$network_test_dir/snapshot-count"
: >"$network_test_dir/snapshot-args"

env QT_QPA_PLATFORM=offscreen HOME="$home" XDG_CONFIG_HOME="$config_home" \
	XDG_DATA_HOME="$data_home" XDG_RUNTIME_DIR="$runtime" \
	DWM_TEST_NETWORK_DIR="$network_test_dir" \
	PATH="$data_home/dwm-titus/scripts:$PATH" \
	quickshell --no-duplicate >"$work/quickshell.log" 2>&1 &
quickshell_pid=$!

config=$config_home/quickshell/shell.qml
network_state() {
	QT_QPA_PLATFORM=offscreen HOME="$home" XDG_CONFIG_HOME="$config_home" \
		XDG_DATA_HOME="$data_home" XDG_RUNTIME_DIR="$runtime" \
		quickshell ipc --path "$config" call network-snapshot-test state 2>/dev/null || true
}
network_ipc() {
	QT_QPA_PLATFORM=offscreen HOME="$home" XDG_CONFIG_HOME="$config_home" \
		XDG_DATA_HOME="$data_home" XDG_RUNTIME_DIR="$runtime" \
		quickshell ipc --path "$config" call network-snapshot-test "$@"
}
wait_for_file() {
	path=$1
	index=0
	while [ "$index" -lt 100 ] && [ ! -e "$path" ]; do
		index=$((index + 1))
		sleep 0.05
	done
	if [ ! -e "$path" ]; then
		printf 'timed out waiting for %s\n' "$path" >&2
		return 1
	fi
}
wait_snapshot_count() {
	want=$1
	index=0
	while [ "$index" -lt 100 ]; do
		[ "$(cat "$network_test_dir/snapshot-count")" -ge "$want" ] && return 0
		index=$((index + 1))
		sleep 0.05
	done
	printf 'snapshot count: got %s, want at least %s\n' "$(cat "$network_test_dir/snapshot-count")" "$want" >&2
	return 1
}
assert_origin() {
	want=$1
	actual=$(network_ipc origin)
	if [ "$actual" != "$want" ]; then
		printf 'snapshot origin: got %s, want %s\n' "$actual" "$want" >&2
		return 1
	fi
}
assert_no_rescan_yes() {
	if grep -Fqx -- '--rescan yes' "$network_test_dir/snapshot-args"; then
		printf 'cancelled settings rescan reached a shared snapshot\n' >&2
		return 1
	fi
}
wait_state() {
	want=$1
	index=0
	while [ "$index" -lt 100 ]; do
		actual=$(network_state)
		[ "$actual" = "$want" ] && return 0
		index=$((index + 1))
		sleep 0.05
	done
	printf 'NetworkModel state: got %s, want %s\n' "${actual:-<empty>}" "$want" >&2
	tail -60 "$work/quickshell.log" >&2
	return 1
}
refresh_for_state() {
	printf '%s\n' "$1" >"$network_test_dir/state"
	network_ipc refresh false shared >/dev/null
	wait_state "$2"
}

wait_state "$(printf 'ethernet\t-1')"
[ -e "$network_test_dir/monitor-ready" ]
refresh_for_state wifi "$(printf 'wifi\t74')"
refresh_for_state disconnected "$(printf 'disconnected\t-1')"
refresh_for_state both "$(printf 'ethernet\t-1')"

printf '%s\n' wifi >"$network_test_dir/state"
printf 'changed\n' >"$network_test_dir/monitor"
wait_state "$(printf 'wifi\t74')"

queued_start=$(cat "$network_test_dir/snapshot-count")
printf '%s\n' panel >"$network_test_dir/block-next"
network_ipc refresh false panel >/dev/null
wait_for_file "$network_test_dir/snapshot-blocked-panel"
printf '%s\n' settings >"$network_test_dir/block-next"
network_ipc refresh true settings >/dev/null
: >"$network_test_dir/release-panel"
wait_for_file "$network_test_dir/snapshot-blocked-settings"
[ "$(network_ipc origin)" = settings ]
grep -Fqx -- '--rescan yes' "$network_test_dir/snapshot-args"
: >"$network_test_dir/release-settings"
wait_snapshot_count $((queued_start + 2))

cancel_start=$(cat "$network_test_dir/snapshot-count")
printf '%s\n' cancel-panel >"$network_test_dir/block-next"
network_ipc refresh false panel >/dev/null
wait_for_file "$network_test_dir/snapshot-blocked-cancel-panel"
network_ipc refresh true settings >/dev/null
network_ipc closeSettings >/dev/null
: >"$network_test_dir/release-cancel-panel"
wait_snapshot_count $((cancel_start + 1))
sleep 0.3
[ "$(cat "$network_test_dir/snapshot-count")" -eq $((cancel_start + 1)) ]

# A shared refresh queued before settings work must survive closing settings.
: >"$network_test_dir/snapshot-args"
shared_first_start=$(cat "$network_test_dir/snapshot-count")
printf '%s\n' shared-first-panel >"$network_test_dir/block-next"
network_ipc refresh false panel >/dev/null
wait_for_file "$network_test_dir/snapshot-blocked-shared-first-panel"
network_ipc refresh false shared >/dev/null
printf '%s\n' shared-first-trailing >"$network_test_dir/block-next"
network_ipc refresh true settings >/dev/null
network_ipc closeSettings >/dev/null
: >"$network_test_dir/release-shared-first-panel"
wait_for_file "$network_test_dir/snapshot-blocked-shared-first-trailing"
assert_origin shared
assert_no_rescan_yes
: >"$network_test_dir/release-shared-first-trailing"
wait_snapshot_count $((shared_first_start + 2))

# If settings queues a rescan first, closing it must discard that rescan while
# preserving the later shared refresh.
: >"$network_test_dir/snapshot-args"
settings_first_start=$(cat "$network_test_dir/snapshot-count")
printf '%s\n' settings-first-panel >"$network_test_dir/block-next"
network_ipc refresh false panel >/dev/null
wait_for_file "$network_test_dir/snapshot-blocked-settings-first-panel"
network_ipc refresh true settings >/dev/null
printf '%s\n' settings-first-trailing >"$network_test_dir/block-next"
network_ipc refresh false shared >/dev/null
network_ipc closeSettings >/dev/null
: >"$network_test_dir/release-settings-first-panel"
wait_for_file "$network_test_dir/snapshot-blocked-settings-first-trailing"
assert_origin shared
assert_no_rescan_yes
: >"$network_test_dir/release-settings-first-trailing"
wait_snapshot_count $((settings_first_start + 2))

printf 'NetworkModel snapshot state contract: PASS\n'
