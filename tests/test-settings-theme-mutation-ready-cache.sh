#!/bin/sh
set -eu

repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
theme_helper=$repo/scripts/dwm-settings-theme

work=$(mktemp -d /tmp/dwm-test-theme-cache.XXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM

export XDG_CONFIG_HOME=$work/config
export XDG_DATA_HOME=$work/data
export XDG_STATE_HOME=$work/state
export XDG_RUNTIME_DIR=$work/run/user/1000

mkdir -p "$XDG_CONFIG_HOME/dwm-titus" "$XDG_DATA_HOME/dwm-titus/config" \
	"$XDG_STATE_HOME/dwm-titus/appearance" "$XDG_RUNTIME_DIR/dwm-settings-theme"
chmod 700 "$XDG_RUNTIME_DIR" "$XDG_RUNTIME_DIR/dwm-settings-theme"

cp "$repo/config/themes.toml" "$XDG_DATA_HOME/dwm-titus/config/themes.toml"

# 1. Initial mutation-ready should succeed and populate cache
"$theme_helper" mutation-ready || {
	printf 'mutation-ready failed on clean fixture\n' >&2
	exit 1
}

cache_file=$XDG_RUNTIME_DIR/dwm-settings-theme/mutation-ready.cache
test -f "$cache_file" || {
	printf 'mutation-ready did not produce cache file %s\n' "$cache_file" >&2
	exit 1
}

# 2. Subsequent call should succeed and utilize cache
"$theme_helper" mutation-ready || {
	printf 'Cached mutation-ready invocation failed\n' >&2
	exit 1
}

# 3. Touch themes file to alter mtime -> cache must invalidate
sleep 0.05
touch "$XDG_DATA_HOME/dwm-titus/config/themes.toml"
"$theme_helper" mutation-ready || {
	printf 'mutation-ready failed after themes file mtime update\n' >&2
	exit 1
}

printf 'test-settings-theme-mutation-ready-cache: PASS\n'
