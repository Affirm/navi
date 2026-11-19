"""Tests for hooks/relay.py. Run with: python3 -m unittest discover -s Tests/relay

Each test runs the relay as a subprocess against a private temp --root, so it
never touches the live /tmp/navi that Navi.app watches.
"""

import json
import os
import queue
import subprocess
import sys
import tempfile
import threading
import time
import unittest

RELAY = os.path.join(os.path.dirname(__file__), "..", "..", "hooks", "relay.py")
EID = "1700000000-" + "ab" * 16


class Relay:
    def __init__(self, root, sessions_dir, features=""):
        self.proc = subprocess.Popen(
            [sys.executable, "-I", RELAY, "--root", root, "--sessions-dir", sessions_dir,
             "--features", features, "--heartbeat", "0.2"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True, bufsize=1)
        self.lines = queue.Queue()
        t = threading.Thread(target=self._pump)
        t.daemon = True
        t.start()

    def _pump(self):
        for line in self.proc.stdout:
            self.lines.put(json.loads(line))
        self.lines.put(None)

    def next(self, kind, timeout=5.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                msg = self.lines.get(timeout=max(0.01, deadline - time.time()))
            except queue.Empty:
                break
            if msg is None:
                raise AssertionError("relay exited while waiting for " + kind)
            if msg.get("kind") == kind:
                return msg
        raise AssertionError("timed out waiting for " + kind)

    def send(self, obj):
        self.proc.stdin.write(json.dumps(obj) + "\n")
        self.proc.stdin.flush()

    def close(self):
        try:
            if self.proc.poll() is None:
                self.proc.stdin.close()
                try:
                    self.proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    raise
            return self.proc.returncode
        finally:
            for f in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
                try:
                    f.close()
                except (OSError, ValueError):
                    pass


class RelayTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = os.path.join(self.tmp.name, "navi")
        self.sessions = os.path.join(self.tmp.name, "sessions")
        os.mkdir(self.sessions)
        self.relay = None

    def tearDown(self):
        if self.relay:
            self.relay.close()
        self.tmp.cleanup()

    def start(self, features=""):
        self.relay = Relay(self.root, self.sessions, features)
        self.relay.next("hello")
        return self.relay

    def write_event(self, name, obj):
        d = os.path.join(self.root, "events")
        tmp = os.path.join(d, "." + name + ".tmp")
        with open(tmp, "w") as f:
            json.dump(obj, f)
        os.rename(tmp, os.path.join(d, name))

    def test_creates_private_dirs(self):
        self.start()
        for sub in ("", "events", "responses", "features"):
            mode = os.stat(os.path.join(self.root, sub)).st_mode & 0o777
            self.assertEqual(mode, 0o700, sub)

    def test_forwards_event_and_deletes_file(self):
        r = self.start()
        self.write_event(EID + ".json", {"id": EID, "type": "permission", "session_id": "s1"})
        msg = r.next("event")
        self.assertEqual(msg["event"]["id"], EID)
        time.sleep(0.1)
        self.assertEqual(os.listdir(os.path.join(self.root, "events")), [])

    def test_resolve_and_working_kinds(self):
        r = self.start()
        self.write_event("resolve-" + EID + ".json", {"type": "resolve", "session_id": "s1", "tool_use_id": "t"})
        self.assertEqual(r.next("resolve")["resolve"]["tool_use_id"], "t")
        self.write_event("working-" + EID + ".json", {"type": "working", "session_id": "s1"})
        self.assertEqual(r.next("working")["session_id"], "s1")

    def test_ignores_tmp_files_and_drops_stale_events(self):
        r = self.start()
        d = os.path.join(self.root, "events")
        with open(os.path.join(d, ".partial.tmp"), "w") as f:
            f.write("{")
        stale = os.path.join(d, "1-" + "cd" * 16 + ".json")
        with open(stale, "w") as f:
            json.dump({"id": "x", "type": "stop"}, f)
        old = time.time() - 3600
        os.utime(stale, (old, old))
        r.next("heartbeat")
        time.sleep(0.5)
        self.assertEqual(os.listdir(d), [".partial.tmp"])
        with self.assertRaises(AssertionError):
            r.next("event", timeout=0.3)

    def test_heartbeat_lists_only_live_sessions(self):
        with open(os.path.join(self.sessions, "1.json"), "w") as f:
            json.dump({"sessionId": "alive", "pid": os.getpid(), "cwd": "/w/p", "status": "idle",
                       "updatedAt": 1700000000000, "secret": "not forwarded"}, f)
        with open(os.path.join(self.sessions, "2.json"), "w") as f:
            json.dump({"sessionId": "dead", "pid": 2 ** 22 + 12345}, f)
        r = self.start()
        beat = r.next("heartbeat")
        self.assertEqual(beat["live"], ["alive"])
        self.assertEqual(beat["sessions"][0]["cwd"], "/w/p")
        self.assertNotIn("secret", beat["sessions"][0])
        self.assertTrue(os.path.exists(os.path.join(self.root, "relay.alive")))

    def test_missing_sessions_dir_means_no_sessions(self):
        os.rmdir(self.sessions)
        r = self.start()
        self.assertEqual(r.next("heartbeat")["live"], [])

    def test_valid_response_written_atomically(self):
        r = self.start()
        r.send({"kind": "response", "id": EID, "decision": "approve"})
        path = os.path.join(self.root, "responses", EID)
        for _ in range(50):
            if os.path.exists(path):
                break
            time.sleep(0.05)
        with open(path) as f:
            self.assertEqual(f.read(), "approve")
        leftovers = [n for n in os.listdir(os.path.join(self.root, "responses")) if n != EID]
        self.assertEqual(leftovers, [])

    def test_invalid_responses_rejected(self):
        r = self.start()
        bad = [
            {"kind": "response", "id": "../../etc/passwd", "decision": "approve"},
            {"kind": "response", "id": "1-short", "decision": "approve"},
            {"kind": "response", "id": EID, "decision": "allow"},
            {"kind": "response", "id": EID.upper(), "decision": "deny"},
            {"kind": "other", "id": EID, "decision": "deny"},
        ]
        for b in bad:
            r.send(b)
        r.proc.stdin.write("not json\n")
        r.proc.stdin.flush()
        time.sleep(0.4)
        self.assertEqual(os.listdir(os.path.join(self.root, "responses")), [])
        self.assertIsNone(r.proc.poll())

    def test_exits_cleanly_on_stdin_eof_and_removes_alive_file(self):
        r = self.start()
        r.next("heartbeat")
        self.assertEqual(r.close(), 0)
        self.assertFalse(os.path.exists(os.path.join(self.root, "relay.alive")))

    def test_sigterm_cleans_up_alive_file(self):
        import signal
        r = self.start()
        r.next("heartbeat")
        r.proc.send_signal(signal.SIGTERM)
        self.assertEqual(r.proc.wait(timeout=5), 0)
        self.assertFalse(os.path.exists(os.path.join(self.root, "relay.alive")))

    def test_feature_mirroring_is_whitelisted(self):
        os.makedirs(os.path.join(self.root, "features"), mode=0o700)
        os.chmod(self.root, 0o700)
        open(os.path.join(self.root, "features", "session-names"), "w").close()
        self.start(features="auto-dismiss,terminal-focus,../evil")
        names = sorted(os.listdir(os.path.join(self.root, "features")))
        self.assertEqual(names, ["auto-dismiss"])

    def test_runs_via_base64_exec_like_navi_launches_it(self):
        # Navi runs: python3 -c 'import base64;exec(base64.b64decode("..."))' [args]
        import base64
        with open(RELAY, "rb") as f:
            b64 = base64.b64encode(f.read()).decode()
        code = 'import base64;exec(base64.b64decode("{}"))'.format(b64)
        proc = subprocess.run(
            [sys.executable, "-I", "-c", code, "--root", self.root, "--sessions-dir", self.sessions],
            input="", stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True, timeout=10)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        # Immediate stdin EOF: says hello, then exits cleanly.
        kinds = [json.loads(l)["kind"] for l in proc.stdout.splitlines()]
        self.assertEqual(kinds[0], "hello")

    def test_refuses_symlinked_root(self):
        real = os.path.join(self.tmp.name, "elsewhere")
        os.mkdir(real, 0o700)
        os.symlink(real, self.root)
        r = Relay(self.root, self.sessions)
        msg = r.next("error")
        self.assertIn("refusing", msg["message"])
        self.assertEqual(r.proc.wait(timeout=5), 2)
        r.close()


if __name__ == "__main__":
    unittest.main()
