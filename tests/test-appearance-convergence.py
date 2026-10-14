#!/usr/bin/env python3
"""Behavioral regressions for appearance readers and queued discovery."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parent.parent


class ConvergenceTests(unittest.TestCase):
    def test_generated_environment_readers(self):
        base = ("export QT_QPA_PLATFORMTHEME=qt6ct\n"
                "export XCURSOR_THEME=Capitaine-Cursors\n"
                "export XCURSOR_SIZE=32\n")
        cases = [
            ("legacy", "", 0),
            ("generated", r"export XCURSOR_PATH=\/home\/abs\/.icons\:\/usr\/share\/icons" + "\n", 0),
            ("plain", "export XCURSOR_PATH=/home/abs/.icons:/usr/share/icons\n", 0),
            ("spaces", r"export XCURSOR_PATH=\/home\/a\ b\/.icons\:\/usr\/share\/icons" + "\n", 0),
            ("relative", "export XCURSOR_PATH=relative:/usr/share/icons\n", 1),
            ("trailing-empty", "export XCURSOR_PATH=/usr/share/icons:\n", 1),
            ("interior-empty", "export XCURSOR_PATH=/home/abs/.icons::/usr/share/icons\n", 1),
            ("duplicate", "export XCURSOR_PATH=/usr/share/icons\n" * 2, 1),
            ("unknown", "export UNKNOWN=/usr/share/icons\n", 1),
            ("substitution", "export XCURSOR_PATH=$(false)\n", 1),
            ("empty", "export XCURSOR_PATH=\n", 1),
        ]
        for script in ("dwm-settings-personalization", "dwm-settings-appearance"):
            source = (REPO / "scripts" / script).read_text()
            functions = "\n".join(re.findall(r"^\w+\(\) \{\n.*?^\}", source, re.M | re.S))
            with tempfile.TemporaryDirectory() as directory:
                config = Path(directory) / "dwm-titus"
                config.mkdir()
                for name, extra, expected in cases:
                    with self.subTest(script=script, case=name):
                        (config / "theme-env.sh").write_text(base + extra)
                        code = functions + '\nconfig_home="$1"\nmax_theme_environment_size=4096\nmax_value_length=255\nparse_theme_environment\n'
                        result = subprocess.run(["bash", "-s", "--", directory], input=code,
                                                text=True, capture_output=True, timeout=10)
                        self.assertEqual(result.returncode, expected, result.stderr)

    def test_queued_discovery_refresh(self):
        runner = next((str(p) for p in (Path("/usr/lib64/qt6/bin/qml"), Path("/usr/lib/qt6/bin/qml")) if p.is_file()), None)
        runner = runner or shutil.which("qml6")
        self.assertIsNotNone(runner, "Qt 6 qml is required for this behavioral test")
        source = (REPO / "config/quickshell/settings/SettingsModel.qml").read_text()
        functions = "\n".join(re.findall(r"^    function (?:refreshCapabilities|parseDiscovery|capabilityById)\(.*?^    \}", source, re.M | re.S))
        process = source.split("id: providerProcess", 1)[1].split("\n    Connections", 1)[0]
        handler = process.split("onRunningChanged: {", 1)[1].rsplit("\n    }", 1)[0].rsplit("\n        }", 1)[0]
        script = r'''
            var root = {visible: true, discoveryState: "loading", capabilities: [],
                        capabilityRefreshPending: false, capabilityRefreshForced: false};
            var providerProcess = {running: true, command: []};
            var Commands = {settingsProviderCommand: function(action, args) { return [action].concat(args); }};
            FUNCTIONS
            root.refreshCapabilities = refreshCapabilities;
            function complete() { var running = providerProcess.running; HANDLER }
            function check(value, message) { if (!value) throw new Error(message); }
            refreshCapabilities(true);
            refreshCapabilities(false);
            check(root.capabilityRefreshPending, "refresh was not queued");
            parseDiscovery("settings-protocol\t1\ncapability\tappearance\tthemes\tThemes\tavailable\tuser\thelper\tReady");
            providerProcess.running = false;
            complete();
            Qt.callLater(function() {
                try {
                    check(providerProcess.running, "queued refresh was dropped");
                    check(providerProcess.command.join(" ") === "discover --force", "forced refresh was lost");
                    check(!root.capabilityRefreshPending, "pending flag was not cleared");
                    check(!root.capabilityRefreshForced, "forced flag leaked into subsequent discovery");
                    parseDiscovery("settings-protocol\t1\ncapability\tappearance\tthemes\tThemes\tavailable\tuser\thelper\tReady");
                    providerProcess.running = false;
                    check(capabilityById("themes").status === "available", "capability remained unavailable");
                    refreshCapabilities(false);
                    check(!providerProcess.running, "ready discovery unnecessarily restarted");
                    console.log("queued discovery: PASS"); Qt.quit();
                } catch (error) { console.error(error); Qt.exit(1); }
            });
        '''.replace("FUNCTIONS", functions).replace("HANDLER", handler)
        with tempfile.TemporaryDirectory() as directory:
            qml = Path(directory) / "test.qml"
            qml.write_text("import QtQuick\nQtObject { Component.onCompleted: {\n" + script + "\n} }\n")
            result = subprocess.run([runner, str(qml)], env={**os.environ, "QT_QPA_PLATFORM": "offscreen", "QT_FORCE_STDERR_LOGGING": "1"},
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("queued discovery: PASS", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
