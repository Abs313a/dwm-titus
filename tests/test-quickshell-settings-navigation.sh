#!/bin/sh
set -eu

repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
model=$repo/config/quickshell/settings/SettingsModel.qml
shell=$repo/config/quickshell/shell.qml

# 1. SettingsModel must have warmup function
grep -Fq 'function warmup()' "$model" || {
	printf 'SettingsModel lacks function warmup()\n' >&2
	exit 1
}

# 2. shell.qml must call settingsModel.warmup() on shell start
grep -Fq 'settingsModel.warmup()' "$shell" || {
	printf 'shell.qml does not call settingsModel.warmup() on startup\n' >&2
	exit 1
}

# 3. SettingsModel refreshCapabilities must not reset to loading when already ready unless forced
grep -Fq 'root.discoveryState === "ready"' "$model" || {
	printf 'SettingsModel does not check ready state in capability refresh\n' >&2
	exit 1
}

printf 'test-quickshell-settings-navigation: PASS\n'
