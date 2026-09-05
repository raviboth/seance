"""Embedding regressions. Run under Xvfb with SEANCE_TEST_BINARY set."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest


@unittest.skipUnless(os.environ.get("SEANCE_TEST_BINARY"), "set SEANCE_TEST_BINARY for GUI validation")
class GhosttyIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="seance-ghostty-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.binary = str(Path(os.environ["SEANCE_TEST_BINARY"]).resolve())
        self.socket_path = self.root / "seance.sock"
        self.env = os.environ.copy()
        for key, name in (("HOME", "home"), ("XDG_CONFIG_HOME", "config"),
                          ("XDG_CACHE_HOME", "cache"), ("XDG_RUNTIME_DIR", "run")):
            path = self.root / name
            path.mkdir(mode=0o700)
            self.env[key] = str(path)
        self.env.update(GDK_BACKEND="x11", DBUS_SESSION_BUS_ADDRESS="disabled:",
                        LIBGL_ALWAYS_SOFTWARE="1", NO_AT_BRIDGE="1", SHELL="/bin/bash")
        self.env.pop("SEANCE_DISABLE_SESSION_RESTORE", None)
        config = self.root / "config" / "seance"
        config.mkdir()
        (config / "config.toml").write_text(
            '[socket]\npath = ' + json.dumps(str(self.socket_path)) +
            '\n[behavior]\nconfirm-close-window = false\n')
        ghostty = self.root / "config" / "ghostty"
        ghostty.mkdir()
        (ghostty / "config").write_text("command = /bin/bash --noprofile --norc\n")
        self.log = (self.root / "stderr.log").open("w+")
        self.addCleanup(self.log.close)
        self.process = None
        self.addCleanup(self.stop)
        self.start()

    def start(self):
        self.process = subprocess.Popen([self.binary], env=self.env, cwd=self.root,
                                        stdout=subprocess.DEVNULL, stderr=self.log)
        self.wait(lambda: self.call("system.ping"), "application startup")

    def stop(self):
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
                self.fail("application failed to shut down")

    def call(self, method, params=None):
        with socket.socket(socket.AF_UNIX) as conn:
            conn.settimeout(2)
            conn.connect(str(self.socket_path))
            conn.sendall((json.dumps({"id": "test", "method": method, "params": params}) + "\n").encode())
            data = b""
            while b"\n" not in data:
                part = conn.recv(65536)
                if not part:
                    break
                data += part
        reply = json.loads(data)
        self.assertTrue(reply["ok"], reply)
        return reply.get("result")

    def wait(self, check, description):
        deadline = time.monotonic() + 15
        last = None
        while time.monotonic() < deadline:
            try:
                if check():
                    return
            except (OSError, ValueError, AssertionError) as exc:
                last = exc
            if self.process.poll() is not None:
                break
            time.sleep(0.1)
        self.log.flush()
        self.log.seek(0)
        self.fail(f"{description}: {last}\n{self.log.read()[-8000:]}")

    def print_marker(self, marker, surface=None):
        params = {"text": "printf '\\033[31mSEANCE_%s\\033[0m\\n' " + marker + "\n"}
        if surface is not None:
            params["surface_id"] = surface
        self.call("surface.send_text", params)
        self.wait(lambda: "SEANCE_" + marker in self.call(
            "surface.read_screen", {"surface_id": surface} if surface else None)["text"],
            "terminal output")

    def test_indexed_scrollback_survives_restart_and_cli_reads_it(self):
        self.wait(lambda: self.call("surface.read_screen").get("text"), "shell startup")
        self.print_marker("SAVED_COLOR_42")
        self.stop()
        self.assertEqual(self.process.returncode, 0)
        session_path = self.root / "home" / ".config" / "seance" / "session.json"
        session = json.loads(session_path.read_text())

        def strings(value):
            if isinstance(value, str):
                yield value
            elif isinstance(value, dict):
                for child in value.values():
                    yield from strings(child)
            elif isinstance(value, list):
                for child in value:
                    yield from strings(child)

        self.assertTrue(any("\x1b[38;5;1mSEANCE_SAVED_COLOR_42" in value for value in strings(session)),
                        "saved scrollback must preserve the palette index instead of RGB")
        self.start()
        self.wait(lambda: "SEANCE_SAVED_COLOR_42" in self.call("surface.read_screen")["text"],
                  "restored scrollback")
        cli = subprocess.run([self.binary, "ctl", "--socket", str(self.socket_path), "read-screen"],
                             env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(cli.returncode, 0, cli.stderr)
        self.assertIn("SEANCE_SAVED_COLOR_42", cli.stdout)

    def test_terminal_remains_usable_after_reparent_and_close(self):
        self.wait(lambda: self.call("surface.read_screen").get("text"), "shell startup")
        workspace = self.call("workspace.current")["id"]
        split = self.call("surface.split")
        surface = split["surface_id"]
        self.wait(lambda: self.call("surface.read_screen", {"surface_id": surface}).get("text"),
                  "split surface startup")
        self.print_marker("SPLIT_42", surface)
        target = self.call("window.create")["index"]
        self.call("workspace.move_to_window", {"workspace_id": workspace, "target_window_id": target})
        self.print_marker("MOVED_42", surface)
        self.call("surface.close", {"surface_id": surface})
        self.call("workspace.select", {"workspace_id": workspace})
        self.print_marker("AFTER_CLOSE_42")

    def test_clipboard_write_and_paste(self):
        self.wait(lambda: self.call("surface.read_screen").get("text"), "shell startup")
        # OSC 52 writes the clipboard through Ghostty's length-delimited callback.
        # Keep the final marker out of the echoed command so only executed output
        # can satisfy the assertion after GTK's asynchronous paste callback.
        self.call("surface.send_text", {
            "text": "printf '\\033]52;c;Q0xJUEJPQVJEXzQy\\a'; printf 'READY_%s\\n' CLIPBOARD\n"
        })
        self.wait(lambda: "READY_CLIPBOARD" in self.call("surface.read_screen")["text"],
                  "clipboard write")
        self.call("surface.send_text", {"text": "printf 'SEANCE_%s\\n' "})
        self.call("surface.send_key", {"key": "ctrl+shift+v"})
        self.wait(lambda: "printf 'SEANCE_%s\\n' CLIPBOARD_42" in
                  self.call("surface.read_screen")["text"], "clipboard paste")
        self.call("surface.send_key", {"key": "enter"})
        self.wait(lambda: "SEANCE_CLIPBOARD_42" in self.call("surface.read_screen")["text"],
                  "pasted command output")
