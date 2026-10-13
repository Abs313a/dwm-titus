#!/bin/sh
set -eu

repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
model=$repo/config/quickshell/appearance/AppearanceModel.qml
pane=$repo/config/quickshell/settings/AppearanceSettingsPane.qml

# 1. AppearanceModel must define property bool mutationRestricted
grep -Fq 'property bool mutationRestricted: false' "$model" || {
	printf 'AppearanceModel lacks property bool mutationRestricted: false\n' >&2
	exit 1
}

# 2. AppearanceModel readinessProcess must set mutationRestricted only on restricted output
grep -Fq 'root.mutationRestricted = !root.mutationReadinessPending' "$model" || {
	printf 'AppearanceModel readinessProcess does not track mutationRestricted\n' >&2
	exit 1
}

# 3. AppearanceSettingsPane must gate the Protected StatusCard on mutationRestricted, not raw !mutationReady
grep -Fq 'visible: root.appearanceModel.mutationRestricted && !root.appearanceBusy' "$pane" || {
	printf 'AppearanceSettingsPane does not gate Protected StatusCard on mutationRestricted && !root.appearanceBusy\n' >&2
	exit 1
}

printf 'test-quickshell-appearance-mutation-state: PASS\n'
