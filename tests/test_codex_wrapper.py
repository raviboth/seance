"""Run with python3 -m unittest discover -s tests -v.

Set SEANCE_TEST_CODEX to a real Codex binary to also verify hook loading and
persisted trust through its local app-server (no login or model calls needed).
"""

import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time
import unittest


WRAPPER = Path(__file__).resolve().parents[1] / "resources/bin/codex"


class CodexWrapperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="seance-codex-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.home = self.root / "home with spaces"
        self.home.mkdir()
        self.codex_home = self.home / "custom codex"
        self.codex_home.mkdir()
        self.capture = self.root / "invocation.json"
        self.events = self.root / "events"
        self.env = {
            **os.environ,
            "PATH": f"{WRAPPER.parent}:{self.bin}:/usr/bin:/bin",
            "HOME": str(self.home),
            "CODEX_HOME": str(self.codex_home),
            "SEANCE_SURFACE_ID": "3",
            "SEANCE_SOCKET_PATH": str(self.root / "socket"),
            "TEST_CAPTURE": str(self.capture),
            "TEST_EVENTS": str(self.events),
        }
        for key in ("SEANCE_CODEX_HOOKS_DISABLED", "SEANCE_CODEX_SESSION_DIR",
                    "SEANCE_CODEX_PID"):
            self.env.pop(key, None)
        self.script("codex", """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
Path(os.environ['TEST_CAPTURE']).write_text(json.dumps({
    'args': sys.argv[1:],
    'home': os.environ.get('CODEX_HOME'),
    'pid': os.environ.get('SEANCE_CODEX_PID'),
}))
sys.exit(int(os.environ.get('TEST_EXIT', '0')))
""")
        self.script("seance", """#!/usr/bin/env bash
if [[ "${*: -1}" == ping ]]; then
    exit "${TEST_PING_EXIT:-0}"
fi
printf '%s\\n' "$*" >> "$TEST_EVENTS"
cat >/dev/null
echo '{"continue":true}'
exit "${TEST_CLEANUP_EXIT:-0}"
""")

    def script(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def invoke(self, *args):
        result = subprocess.run(
            [str(WRAPPER), *args], env=self.env, cwd=self.root,
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.stderr, "")
        self.assertEqual(result.stdout, "")
        return result, json.loads(self.capture.read_text())

    def test_keeps_real_home_and_user_arguments(self):
        originals = {"hooks.json": '{"hooks": {}}', "config.toml": "# user config\n",
                     ".marker": "hidden state", "history.jsonl": "saved history\n"}
        for name, content in originals.items():
            (self.codex_home / name).write_text(content)
        args = ("resume", "--last", "a prompt with spaces; $HOME")
        result, invocation = self.invoke(*args)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(invocation["home"], str(self.codex_home))
        self.assertTrue(invocation["pid"].isdigit())
        self.assertEqual(invocation["args"][-len(args):], list(args))
        self.assertEqual(invocation["args"][:2], ["--enable", "hooks"])
        for name, content in originals.items():
            self.assertEqual((self.codex_home / name).read_text(), content)
        self.assertFalse((self.home / ".cache/seance-codex").exists())
        self.assertEqual(self.events.read_text(), "ctl codex-hook session-end\n")

    def test_default_home_stays_unset(self):
        self.env.pop("CODEX_HOME")
        _, invocation = self.invoke()
        self.assertIsNone(invocation["home"])

    def test_definitions_stay_identical_across_panes(self):
        _, first = self.invoke()
        self.env["SEANCE_SURFACE_ID"] = "72"
        self.env["SEANCE_SOCKET_PATH"] = str(self.root / "another socket")
        _, second = self.invoke()
        self.assertEqual(first["args"], second["args"])

    def test_failure_still_cleans_up_and_preserves_exit_status(self):
        self.env.update(TEST_EXIT="42", TEST_CLEANUP_EXIT="7")
        result, _ = self.invoke()
        self.assertEqual(result.returncode, 42)
        self.assertEqual(self.events.read_text(), "ctl codex-hook session-end\n")

    def test_passthrough_when_unavailable_or_disabled(self):
        for key, value in (("SEANCE_SURFACE_ID", ""),
                           ("SEANCE_CODEX_HOOKS_DISABLED", "1"),
                           ("TEST_PING_EXIT", "1")):
            with self.subTest(key=key):
                previous = self.env.copy()
                self.env[key] = value
                self.env["TEST_EXIT"] = "17"
                result, invocation = self.invoke("exec", "hello")
                self.assertEqual(result.returncode, 17)
                self.assertEqual(invocation["args"], ["exec", "hello"])
                self.assertIsNone(invocation["pid"])
                self.assertFalse(self.events.exists())
                self.env = previous

    def test_management_commands_pass_through(self):
        for command in ("--help", "--version", "login", "mcp", "app-server",
                        "plugin", "update", "doctor", "features", "help"):
            with self.subTest(command=command):
                result, invocation = self.invoke(command)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(invocation["args"], [command])
                self.assertFalse(self.events.exists())

    @unittest.skipUnless(os.environ.get("SEANCE_TEST_CODEX"), "set SEANCE_TEST_CODEX for live validation")
    def test_codex_loads_user_hooks_and_remembers_trust_across_panes(self):
        (self.codex_home / "hooks.json").write_text(json.dumps({"hooks": {
            "SessionStart": [{"hooks": [{"type": "command", "command": "echo user-hook"}]}],
        }}))
        _, first = self.invoke()
        with AppServer(os.environ["SEANCE_TEST_CODEX"], first["args"], self.env, self.root) as server:
            hooks = server.hooks()
            self.assertEqual(len(hooks), 7)
            ours = [hook for hook in hooks if hook["source"] == "sessionFlags"]
            self.assertEqual(len(ours), 6)
            self.assertTrue(all(hook["trustStatus"] == "untrusted" for hook in ours))
            self.assertTrue(all(hook["timeoutSec"] <= 3 for hook in ours))
            # The same config write that Codex's /hooks review performs.
            server.rpc("config/batchWrite", {"edits": [
                {"keyPath": f'hooks.state.{json.dumps(hook["key"])}.trusted_hash',
                 "value": hook["currentHash"], "mergeStrategy": "replace"}
                for hook in ours
            ]})
        self.env["SEANCE_SURFACE_ID"] = "99"
        _, second = self.invoke()
        with AppServer(os.environ["SEANCE_TEST_CODEX"], second["args"], self.env, self.root) as server:
            hooks = server.hooks()
            self.assertEqual(len(hooks), 7)
            for hook in hooks:
                if hook["source"] == "sessionFlags":
                    self.assertEqual(hook["trustStatus"], "trusted")
                else:
                    self.assertEqual(hook["command"], "echo user-hook")
                    self.assertEqual(hook["trustStatus"], "untrusted")


class AppServer:
    """Minimal local JSON-RPC client; never starts an agent turn."""

    def __init__(self, binary, args, env, cwd):
        self.cwd = str(cwd)
        self.counter = 0
        self.buffer = b""
        self.process = subprocess.Popen(
            [binary, "app-server", *args], env=env, cwd=cwd,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )

    def __enter__(self):
        try:
            self.rpc("initialize", {"clientInfo": {"name": "seance-test", "version": "1"},
                                    "capabilities": {"experimentalApi": True}})
        except BaseException:
            self.__exit__(None, None, None)
            raise
        return self

    def __exit__(self, *_):
        self.process.terminate()
        try:
            self.process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.communicate()

    def rpc(self, method, params):
        self.counter += 1
        self.process.stdin.write(json.dumps({"id": self.counter, "method": method,
                                            "params": params}).encode() + b"\n")
        self.process.stdin.flush()
        deadline = time.monotonic() + 15
        while True:
            if b"\n" not in self.buffer:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                    raise AssertionError(f"Codex RPC timed out: {method}")
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk:
                    raise AssertionError(f"Codex exited during {method}")
                self.buffer += chunk
                continue
            line, self.buffer = self.buffer.split(b"\n", 1)
            response = json.loads(line)
            if response.get("id") == self.counter:
                if "error" in response:
                    raise AssertionError(response["error"])
                return response["result"]

    def hooks(self):
        entry = self.rpc("hooks/list", {"cwd": self.cwd})["data"][0]
        if entry["errors"] or entry["warnings"]:
            raise AssertionError(entry)
        return entry["hooks"]


if __name__ == "__main__":
    unittest.main()
