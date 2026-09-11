import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import install
import safe_io
import storage


class SafeIOTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.state = Path(directory.name)
        self.history = self.state / "clipboard-history.json"
        self.victim = self.state / "victim.json"
        self.victim.write_text('["untouched"]')

    def test_symlink_history_refused_for_read_and_mutation(self):
        self.history.symlink_to(self.victim)
        with self.assertRaises(ValueError):
            storage.dump(self.state)
        with self.assertRaises(ValueError):
            storage.mutate(self.state, "clear", {"identities": []})
        self.assertEqual(self.victim.read_text(), '["untouched"]')

    def test_oversize_history_refused_before_parse(self):
        self.history.write_bytes(b" " * (storage.MAX_BYTES + 1))
        with patch.object(storage.json, "loads") as parse:
            with self.assertRaises(ValueError):
                storage.read(self.history, [])
            parse.assert_not_called()
        with self.assertRaises(ValueError):
            storage.update(self.history, lambda _: [])
        self.assertEqual(self.history.stat().st_size, storage.MAX_BYTES + 1)

    def test_symlink_write_destination_refused(self):
        self.history.symlink_to(self.victim)
        with self.assertRaises(ValueError):
            safe_io.atomic_write(self.history, b"[]")
        self.assertTrue(self.history.is_symlink())
        self.assertEqual(self.victim.read_text(), '["untouched"]')

    def test_destination_rechecked_after_staging(self):
        real_fsync = os.fsync
        def substitute(fd):
            self.history.symlink_to(self.victim)
            real_fsync(fd)
        with patch.object(safe_io.os, "fsync", side_effect=substitute):
            with self.assertRaises(ValueError):
                safe_io.atomic_write(self.history, b"[]")
        self.assertEqual(self.victim.read_text(), '["untouched"]')
        self.assertEqual(list(self.state.glob('.clip-*')), [])

    def test_nonregular_files_refused_without_fifo_hang(self):
        self.history.mkdir()
        with self.assertRaises(ValueError):
            storage.read(self.history, [])
        self.history.rmdir()
        os.mkfifo(self.history)
        with self.assertRaises(ValueError):
            storage.read(self.history, [])

    def test_wrong_owner_refused(self):
        with patch.object(safe_io.os, "getuid", return_value=os.getuid() + 1):
            with self.assertRaises(ValueError):
                storage.read(self.victim, [])
            with self.assertRaises(ValueError):
                safe_io.atomic_write(self.victim, b"[]")

    def test_symlink_parent_refused(self):
        linked = self.state / "linked"
        linked.symlink_to(self.state, target_is_directory=True)
        for operation in (lambda: storage.read(linked / self.victim.name, []),
                          lambda: safe_io.atomic_write(linked / 'new.json', b"[]"),
                          lambda: safe_io.ensure_directory(linked)):
            with self.assertRaises(ValueError):
                operation()
        self.assertFalse((self.state / 'new.json').exists())

    def test_entry_limit_rejects_read_and_transform(self):
        self.history.write_text(json.dumps(["x"] * (storage.MAX_ENTRIES + 1)))
        with self.assertRaises(ValueError):
            storage.read(self.history, [])
        self.history.write_text(json.dumps(["x"] * storage.MAX_ENTRIES))
        with self.assertRaises(ValueError):
            storage.update(self.history, lambda values: values + ["y"])
        self.assertEqual(len(json.loads(self.history.read_text())), storage.MAX_ENTRIES)

    def test_output_byte_limit(self):
        with self.assertRaises(ValueError):
            storage.update(self.history, lambda _: ["x" * storage.MAX_BYTES])
        self.assertFalse(self.history.exists())

    def test_growth_during_read_is_capped(self):
        with patch.object(safe_io.os, "read", return_value=b"x" * 65536):
            with self.assertRaises(ValueError):
                safe_io.read_bytes(self.victim, storage.MAX_BYTES)

    def test_dump_missing_state_and_preserved_positions(self):
        self.assertEqual(storage.dump(self.state / 'missing'), {'history': [], 'pins': []})
        entries = [{"type": "unknown"}, {"type": "text", "text": "hello"}]
        self.history.write_text(json.dumps(entries))
        self.assertEqual(storage.dump(self.state), {'history': entries, 'pins': []})

    def test_pins_validation_and_limit(self):
        pins = self.state / 'clip-pins.json'
        pins.write_text('[1]')
        with self.assertRaises(ValueError):
            storage.dump(self.state)
        pins.write_text(json.dumps(['text:' + str(i) for i in range(storage.MAX_ENTRIES)]))
        with self.assertRaises(ValueError):
            storage.mutate(self.state, 'pin', {'identity': 'text:new'})
        self.assertEqual(len(json.loads(pins.read_text())), storage.MAX_ENTRIES)

    def test_stdin_cap(self):
        with self.assertRaises(ValueError):
            storage.read_payload(io.BytesIO(b'"' + b'x' * storage.MAX_STDIN_BYTES + b'"'))
        self.assertEqual(storage.read_payload(io.BytesIO(b'{"identity":"text:x"}\n')), {'identity': 'text:x'})

    def test_installer_copy_and_backup_refuse_links(self):
        self.history.symlink_to(self.victim)
        with self.assertRaises(ValueError):
            install.install_file(self.victim, self.history)
        with self.assertRaises(ValueError):
            install.backup(self.history)
        backup = self.victim.with_name(self.victim.name + '.clip-backup-' + install.STAMP)
        backup.symlink_to(self.victim)
        with self.assertRaises(ValueError):
            install.backup(self.victim)
        self.assertEqual(self.victim.read_text(), '["untouched"]')

    def test_installer_preserves_executable_mode_and_private_backup(self):
        self.victim.chmod(0o755)
        install.install_file(self.victim, self.history)
        self.assertEqual(self.history.stat().st_mode & 0o777, 0o755)
        install.backup(self.history)
        backup = self.history.with_name(self.history.name + '.clip-backup-' + install.STAMP)
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        self.assertEqual(backup.read_bytes(), self.victim.read_bytes())

    def test_installer_config_read_cap(self):
        self.history.write_bytes(b'x' * (install.MAX_CONFIG_BYTES + 1))
        with self.assertRaises(ValueError):
            install.backup(self.history)


if __name__ == '__main__':
    unittest.main()
