"""Physical XKB input regressions, each using its own isolated X server."""
import ctypes
import os
import select
import shlex
import shutil
import subprocess
import unittest
from unittest.mock import patch

import test_ghostty_integration as integration


@unittest.skipUnless(os.environ.get("SEANCE_TEST_BINARY"), "set SEANCE_TEST_BINARY for GUI validation")
class KeyboardRemapTests(unittest.TestCase):
    def setUp(self):
        for command in ("Xvfb", "xdotool", "setxkbmap"):
            if not shutil.which(command):
                self.skipTest(f"keyboard tests require {command}")
        # Never change the developer's desktop keymap, even when run outside xvfb-run.
        server = subprocess.Popen(
            ["Xvfb", "-displayfd", "1", "-screen", "0", "1280x800x24", "-nolisten", "tcp", "-noreset"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        self.addCleanup(self.stop_server, server)
        self.assertTrue(select.select([server.stdout], [], [], 10)[0], "Xvfb startup timed out")
        display = ":" + server.stdout.readline().decode().strip()
        self.assertNotEqual(display, ":", "Xvfb failed to start")
        self.app = integration.GhosttyIntegrationTests()
        self.addCleanup(self.app.doCleanups)
        with patch.dict(os.environ, {"DISPLAY": display}):
            self.app.setUp()
        self.app.wait(lambda: self.app.call("surface.read_screen").get("text"), "shell startup")
        window = self.run_x("xdotool", "search", "--onlyvisible", "--pid", str(self.app.process.pid)).strip().splitlines()[0]
        self.run_x("xdotool", "windowfocus", "--sync", window)

        # XTest sends physical keycodes through XKB and GTK; ctl send-key bypasses both.
        self.x11 = ctypes.CDLL("libX11.so.6")
        self.xtst = ctypes.CDLL("libXtst.so.6")
        self.x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
        self.x11.XOpenDisplay.restype = ctypes.c_void_p
        self.x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
        self.x11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
        self.xtst.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
        self.display = self.x11.XOpenDisplay(display.encode())
        self.assertTrue(self.display)
        self.addCleanup(self.x11.XCloseDisplay, self.display)

    @staticmethod
    def stop_server(server):
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
        server.stdout.close()

    def run_x(self, *args):
        return subprocess.run(args, env=self.app.env, check=True, capture_output=True,
                              text=True, timeout=10).stdout

    def capture(self, options="", variant="", kitty=False):
        self.run_x("setxkbmap", "-layout", "us", "-variant", variant, "-option", "", "-option", options)
        self.output = self.app.root / "keys.bin"
        ready = self.app.root / "ready"
        script = self.app.root / "capture.py"
        script.write_text(
            "import os, tty\nfrom pathlib import Path\n"
            "tty.setraw(0)\n" +
            ("os.write(1, b'\x1b[>11u')\n" if kitty else "") +
            f"out = open({str(self.output)!r}, 'wb', buffering=0)\n"
            f"Path({str(ready)!r}).touch()\n"
            "while True:\n    out.write(os.read(0, 4096))\n"
        )
        self.app.call("surface.send_text", {"text": "python3 " + shlex.quote(str(script)) + "\n"})
        self.app.wait(ready.exists, "raw input recorder")

    def key(self, code, pressed):
        self.assertTrue(self.xtst.XTestFakeKeyEvent(self.display, code, pressed, 20))
        self.x11.XSync(self.display, 0)

    def tap(self, code):
        self.key(code, True)
        self.key(code, False)

    def received(self):
        return self.output.read_bytes()

    def test_caps_backspace_keeps_real_lock_state_and_release(self):
        self.capture("caps:backspace,shift:both_capslock", kitty=True)
        self.tap(66)  # Caps -> Backspace, initially unlocked.
        self.app.wait(lambda: b"\x1b[127" in self.received(), "remapped Backspace")
        self.key(50, True)
        self.key(62, True)  # Both Shifts enable a real Caps Lock state.
        self.key(62, False)
        self.key(50, False)
        self.tap(66)
        self.app.wait(lambda: b"\x1b[127;65:3u" in self.received(),
                      "Backspace release must retain Caps Lock: " + repr(self.received()))
        self.assertRegex(self.received(), rb"\x1b\[127;65(?::1)?u")

    def test_caps_escape_swap_works_in_both_directions(self):
        self.capture("caps:swapescape")
        self.tap(66)  # Caps -> Escape.
        self.tap(9)   # Escape -> Caps Lock; must not also emit Escape.
        self.tap(38)  # A with Caps Lock enabled.
        self.tap(9)
        self.tap(38)
        self.app.wait(lambda: self.received().endswith(b"a"), "letters after swapped Caps Lock")
        self.assertEqual(self.received(), b"\x1bAa")

    def test_level_modifier_does_not_send_keypad_enter(self):
        self.capture("lv3:enter_switch")
        self.tap(104)  # Keypad Enter is now ISO_Level3_Shift.
        self.tap(38)
        self.app.wait(lambda: self.received().endswith(b"a"), "letter after level modifier")
        self.assertEqual(self.received(), b"a")

    def test_colemak_typing_and_control_shortcut(self):
        self.capture(variant="colemak")
        self.tap(38)  # A stays A.
        self.tap(26)  # Physical E produces F on Colemak.
        self.key(37, True)
        self.tap(26)  # Ctrl+F.
        self.key(37, False)
        self.app.wait(lambda: self.received().endswith(b"\x06"), "Colemak Ctrl+F")
        self.assertEqual(self.received(), b"af\x06")
