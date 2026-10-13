#!/bin/sh
set -eu

repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
provider=$repo/scripts/dwm-settings-provider

work=$(mktemp -d /tmp/dwm-test-provider-cache.XXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM

runtime_dir=$work/run/user/1000
mkdir -p "$runtime_dir"
export XDG_RUNTIME_DIR=$runtime_dir

cache_dir=$runtime_dir/dwm-titus
cache_file=$cache_dir/capabilities.cache

# 1. Initial discover should create the cache file in XDG_RUNTIME_DIR/dwm-titus/
output1=$("$provider" discover)
printf '%s\n' "$output1" | grep -Fqx 'settings-protocol	1'
test -f "$cache_file" || {
	printf 'Expected cache file %s was not created on first discover\n' "$cache_file" >&2
	exit 1
}

cached_contents=$(cat "$cache_file")
if [ "$output1" != "$cached_contents" ]; then
	printf 'Cache contents do not match discover output\n' >&2
	exit 1
fi

# 2. Subsequent discover should serve from cache (inject marker to verify cache read)
printf 'settings-protocol\t1\ncapability\ttest\ttest\tTest\tavailable\ttest\ttest\tCached\n' > "$cache_file"
output2=$("$provider" discover)
if ! printf '%s\n' "$output2" | grep -Fq 'Cached'; then
	printf 'Second discover did not serve from cache file\n' >&2
	exit 1
fi

# 3. Discover with --force should refresh the cache and ignore injected mock
output3=$("$provider" discover --force)
if printf '%s\n' "$output3" | grep -Fq 'Cached'; then
	printf 'discover --force did not refresh cache\n' >&2
	exit 1
fi

# 4. DWM_SETTINGS_NO_CACHE=1 should bypass cache
printf 'settings-protocol\t1\ncapability\ttest\ttest\tTest\tavailable\ttest\ttest\tCached\n' > "$cache_file"
output4=$(DWM_SETTINGS_NO_CACHE=1 "$provider" discover)
if printf '%s\n' "$output4" | grep -Fq 'Cached'; then
	printf 'DWM_SETTINGS_NO_CACHE=1 did not bypass cache\n' >&2
	exit 1
fi

printf 'test-settings-provider-cache: PASS\n'
