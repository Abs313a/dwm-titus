#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
theme_helper=$repo/scripts/dwm-settings-theme
apply_script=$repo/scripts/theme-apply.sh

work=$(mktemp -d "${TMPDIR:-/tmp}/dwm-fastpath-test.XXXXXX")
cleanup() {
	rm -rf "$work"
}
trap cleanup EXIT

home_dir=$work/home
config_home=$home_dir/.config
data_home=$home_dir/.local/share
state_home=$home_dir/.local/state
runtime_dir=$work/runtime
bin_dir=$work/bin
dconf_dir=$work/dconf

mkdir -p "$config_home/dwm-titus" "$config_home/gtk-3.0" "$config_home/gtk-4.0" \
	"$config_home/alacritty" "$config_home/kitty" \
	"$data_home/dwm-titus/config" "$data_home/icons/Capitaine-Cursors/cursors" \
	"$data_home/icons/Bob's Icons" \
	"$state_home/dwm-titus/appearance" "$runtime_dir" "$bin_dir" "$dconf_dir"

cp "$repo/config/themes.toml" "$data_home/dwm-titus/config/themes.toml"

cursor_reload_log=$work/cursor-reload.log
picom_log=$work/picom.log
touch "$cursor_reload_log" "$picom_log"

cat >"$bin_dir/dwm-cursor-reload" <<SH
#!/bin/sh
printf '%s\n' "\$*" >>"$cursor_reload_log"
exit 0
SH

cat >"$bin_dir/dwm-settings-picom" <<SH
#!/bin/sh
printf '%s\n' "\$*" >>"$picom_log"
exit 0
SH

printf "'Old Font 10'\n" >"$dconf_dir/font-name"
printf '1.0\n' >"$dconf_dir/text-scaling-factor"
printf "'Old Cursor'\n" >"$dconf_dir/cursor-theme"
printf '32\n' >"$dconf_dir/cursor-size"
printf "'Old Icons'\n" >"$dconf_dir/icon-theme"
printf "'Old GTK'\n" >"$dconf_dir/gtk-theme"

cat >"$bin_dir/gsettings" <<'SH'
#!/bin/sh
set -eu
command=${1:-}
schema=${2:-}
key=${3:-}
state=${DWM_TEST_DCONF_DIR:?}/${key}
case $command in
writable)
	printf 'true\n'
	;;
get)
	if [ -f "$state" ]; then
		cat "$state"
	else
		printf '1.0\n'
	fi
	;;
set)
	mkdir -p -- "${state%/*}"
	value=${4:?}
	case $value in
	*"'"*)
		value=$(printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g')
		printf '"%s"\n' "$value" >"$state"
		;;
	*)
		value=$(printf '%s' "$value" | sed 's/\\/\\\\/g')
		printf "'%s'\n" "$value" >"$state"
		;;
	esac
	;;
reset)
	rm -f -- "$state"
	;;
*) exit 1 ;;
esac
SH

cat >"$bin_dir/dconf" <<'SH'
#!/bin/sh
set -eu
command=${1:?}
path=${2:?}
key=${path##*/}
state=${DWM_TEST_DCONF_DIR:?}/${key}
case $command in
read)
	[ ! -f "$state" ] || cat "$state"
	;;
write)
	mkdir -p -- "${state%/*}"
	printf '%s\n' "${3:?}" >"$state"
	;;
reset)
	rm -f -- "$state"
	;;
*) exit 1 ;;
esac
SH

cat >"$bin_dir/dwm-xsettings" <<'SH'
#!/bin/sh
printf 'xsettings-protocol\t1\t0\nstate\tactive\t122880\n'
exit 0
SH

cat >"$bin_dir/dump_xsettings" <<'SH'
#!/bin/sh
printf 'Xft/DPI 122880\n'
exit 0
SH

cat >"$bin_dir/xsettingsd" <<'SH'
#!/bin/sh
exit 0
SH

cat >"$bin_dir/xrdb" <<'SH'
#!/bin/sh
cat >/dev/null
exit 0
SH

chmod +x "$bin_dir"/*

# Initialize alacritty and kitty marker files with known mtimes
touch -t 202601010000 "$config_home/alacritty/alacritty.toml"
touch -t 202601010000 "$config_home/kitty/kitty.conf"

run_theme() {
	PATH=$bin_dir:$PATH \
	HOME=$home_dir \
	XDG_CONFIG_HOME=$config_home \
	XDG_DATA_HOME=$data_home \
	XDG_STATE_HOME=$state_home \
	XDG_RUNTIME_DIR=$runtime_dir \
	DWM_TEST_DCONF_DIR=$dconf_dir \
	DWM_APPEARANCE_APPLY_HELPER=$apply_script \
	DWM_APPEARANCE_XSETTINGS_HELPER=$bin_dir/dwm-xsettings \
	DWM_APPEARANCE_CURSOR_HELPER=$bin_dir/dwm-cursor-reload \
	DWM_APPEARANCE_PICOM_HELPER=$bin_dir/dwm-settings-picom \
	DISPLAY=:199 \
	"$theme_helper" "$@"
}

printf '=== Test 1: Fast-path for font personalization ===\n'
: >"$cursor_reload_log"
: >"$picom_log"
run_theme personalize font 'MesloLGS Nerd Font 10'

# Assert personalization.conf updated
grep -Fqx $'font\tMesloLGS Nerd Font 10' "$config_home/dwm-titus/personalization.conf"

# Assert cursor reload and picom reload were NOT called
if [ -s "$cursor_reload_log" ]; then
	printf 'FAILURE: dwm-cursor-reload was called during font personalization:\n' >&2
	cat "$cursor_reload_log" >&2
	exit 1
fi

if [ -s "$picom_log" ]; then
	printf 'FAILURE: dwm-settings-picom was called during font personalization:\n' >&2
	cat "$picom_log" >&2
	exit 1
fi

# Assert terminal configs were NOT generated or modified
if [ -f "$config_home/alacritty/active-theme.toml" ]; then
	printf 'FAILURE: alacritty active-theme.toml was generated during font personalization\n' >&2
	exit 1
fi
if [ -f "$config_home/kitty/active-theme.conf" ]; then
	printf 'FAILURE: kitty active-theme.conf was generated during font personalization\n' >&2
	exit 1
fi

printf '=== Test 2: Fast-path for cursor personalization ===\n'
: >"$cursor_reload_log"
: >"$picom_log"
run_theme personalize cursor 'Capitaine-Cursors'

grep -Fqx $'cursor\tCapitaine-Cursors' "$config_home/dwm-titus/personalization.conf"

# Cursor reload SHOULD be called for cursor change
if ! grep -Fq 'Capitaine-Cursors' "$cursor_reload_log"; then
	printf 'FAILURE: dwm-cursor-reload was NOT called during cursor personalization\n' >&2
	exit 1
fi

# But picom should NOT be called
if [ -s "$picom_log" ]; then
	printf 'FAILURE: dwm-settings-picom was called during cursor personalization\n' >&2
	cat "$picom_log" >&2
	exit 1
fi

printf '=== Test 3: Fast-path for icon personalization ===\n'
: >"$cursor_reload_log"
: >"$picom_log"
run_theme personalize icon "Bob's Icons"

grep -Fqx $'icon\tBob\'s Icons' "$config_home/dwm-titus/personalization.conf"
if [ -s "$cursor_reload_log" ]; then
	printf 'FAILURE: dwm-cursor-reload was called during icon personalization\n' >&2
	cat "$cursor_reload_log" >&2
	exit 1
fi

printf 'personalization fast-path tests: PASS\n'
