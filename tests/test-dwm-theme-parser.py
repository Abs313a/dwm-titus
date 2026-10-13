#!/usr/bin/env python3
"""Unit tests for dwm-theme-parser."""

import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PARSER = REPO / "scripts" / "dwm-theme-parser"
THEMES_TOML = REPO / "config" / "themes.toml"


def run_parser(*args, check=True):
    cmd = [str(PARSER), *args]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if check and proc.returncode != 0:
        raise RuntimeError(
            f"Command {cmd} failed ({proc.returncode}):\n{proc.stderr}\n{proc.stdout}"
        )
    return proc


def test_active_theme():
    proc = run_parser("active", str(THEMES_TOML))
    assert proc.stdout.strip() == "nord", f"Expected 'nord', got {proc.stdout.strip()}"


def test_get_value():
    proc = run_parser("get", "theme.nord", "normfgcolor", str(THEMES_TOML))
    assert (
        proc.stdout.strip() == "#D8DEE9"
    ), f"Expected '#D8DEE9', got {proc.stdout.strip()}"

    proc = run_parser("get", "theme.dracula", "dark_mode", str(THEMES_TOML))
    assert proc.stdout.strip() == "true", f"Expected 'true', got {proc.stdout.strip()}"


def test_validate_structure():
    proc = run_parser("validate-structure", str(THEMES_TOML))
    assert proc.returncode == 0

    with tempfile.NamedTemporaryFile("w+", suffix=".toml") as tmp:
        # Invalid TOML syntax
        tmp.write("invalid toml [[[]\n")
        tmp.flush()
        res = run_parser("validate-structure", tmp.name, check=False)
        assert res.returncode != 0, "Invalid TOML should fail validation"


def test_dump_theme():
    proc = run_parser("dump-theme", "nord", str(THEMES_TOML))
    out = proc.stdout
    assert (
        "THEME_NAME='nord'" in out
        or 'THEME_NAME="nord"' in out
        or "THEME_NAME=nord" in out
    )
    assert "TERM_BG=" in out
    assert "NORMFGCOLOR=" in out
    assert "DARK_MODE=true" in out or "DARK_MODE='true'" in out


def test_list_themes():
    proc = run_parser("list-themes", str(THEMES_TOML))
    themes = proc.stdout.strip().splitlines()
    assert "nord" in themes
    assert "dracula" in themes
    assert len(themes) >= 10


def main():
    test_active_theme()
    test_get_value()
    test_validate_structure()
    test_dump_theme()
    test_list_themes()
    print("dwm-theme-parser tests: PASS")


if __name__ == "__main__":
    main()
