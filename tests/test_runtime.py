import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
PREFIX = ["/usr/bin/timeout", "--kill-after=1s", "2s", "/usr/bin/python3", "-I"]


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.home = Path(directory.name)
        self.state = self.home / ".local/state/omarchy"
        self.state.mkdir(parents=True)
        self.env = {"HOME": str(self.home), "PATH": "/usr/bin:/bin", "LC_ALL": "C"}

    def run_storage(self, operation, payload=None, env=None):
        return subprocess.run(PREFIX + [str(ROOT / "storage.py"), operation],
                              input=payload, capture_output=True, cwd="/",
                              env=env or self.env, timeout=5)

    def test_isolated_dump_and_mutation_ignore_pythonpath(self):
        (self.home / "safe_io.py").write_text("raise RuntimeError('untrusted helper')")
        (self.home / "sitecustomize.py").write_text("raise RuntimeError('untrusted site')")
        env = dict(self.env, PYTHONPATH=str(self.home), PYTHONHOME=str(self.home))
        result = self.run_storage("pin", b'{"identity":"text:hello"}\n', env)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_storage("dump", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"history": [], "pins": ["text:hello"]})

    def test_combined_dump_has_hard_stdout_ceiling(self):
        for name in ("clipboard-history.json", "clip-pins.json"):
            (self.state / name).write_text(json.dumps(["x" * (1024 * 1024)]))
        result = self.run_storage("dump")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"Output exceeds byte limit", result.stderr)

    def test_unterminated_mutation_input_times_out(self):
        with subprocess.Popen(PREFIX + [str(ROOT / "storage.py"), "pin"],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, cwd="/", env=self.env) as process:
            try:
                self.assertEqual(process.wait(timeout=5), 124)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, 9)
                    process.wait()

    def test_timeout_kills_term_resistant_process_group(self):
        # Both generations ignore TERM and hold output pipes open. communicate
        # can finish only once the whole group has closed those pipes.
        script = """
import os, signal, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
child = os.fork()
print(os.getpid(), os.getpgrp(), flush=True)
while True:
    time.sleep(1)
"""
        started = time.monotonic()
        with subprocess.Popen(PREFIX + ["-c", script], stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, cwd="/", env=self.env) as process:
            try:
                stdout, stderr = process.communicate(timeout=5)
                self.assertEqual(process.returncode, -9, stderr)
                records = [line.split() for line in stdout.decode().splitlines()]
                self.assertEqual(len(records), 2)
                self.assertTrue(all(int(group) == process.pid for _, group in records))
                self.assertLess(time.monotonic() - started, 4)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, 9)
                    process.wait()


if __name__ == "__main__":
    unittest.main()
