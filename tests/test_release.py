"""The deployment boundary rejects unvalidated, changed, or private runtime content."""
import json
from pathlib import Path
import tempfile
import unittest

from scripts.build_release import build, fingerprint, inventory, stamp_shell, verify_release


class ReleaseBoundary(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / 'source'
        for part in ('pipeline', 'server', 'web'):
            (self.source / part).mkdir(parents=True)
            (self.source / part / 'fixture.txt').write_text(part)
        self.proof = self.root / 'validation.json'
        self.write_proof()

    def write_proof(self):
        self.proof.write_text(json.dumps({'ok': True, 'source_sha256': fingerprint(inventory(self.source))}))

    def writable_cleanup(self, root):
        if root.exists():
            root.chmod(0o755)
            for p in root.rglob('*'):
                p.chmod(0o755 if p.is_dir() else 0o644)

    def test_verified_snapshot_reused_and_data_credentials_excluded(self):
        (self.source / '.env').write_text('not-for-release')
        (self.source / 'data').mkdir()
        (self.source / 'data' / 'private.txt').write_text('not-for-release')
        root = self.root / 'releases'
        self.addCleanup(self.writable_cleanup, root)
        release, created = build(self.source, root, self.proof)
        self.assertTrue(created)
        self.assertFalse((release / '.env').exists())
        self.assertTrue((release / 'data').is_dir())
        self.assertEqual(list((release / 'data').iterdir()), [])
        self.assertEqual(verify_release(release)['source_sha256'], fingerprint(inventory(self.source)))
        self.assertEqual(build(self.source, root, self.proof), (release, False))

    def test_changed_source_requires_new_validation(self):
        (self.source / 'web' / 'fixture.txt').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'validation'):
            build(self.source, self.root / 'releases', self.proof)

    def test_private_runtime_file_and_symlink_rejected(self):
        private = self.source / 'server' / '.env'
        private.write_text('secret')
        with self.assertRaisesRegex(ValueError, 'private'):
            inventory(self.source)
        private.unlink()
        (self.source / 'web' / 'outside').symlink_to(self.proof)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            inventory(self.source)

    def test_tampering_refuses_existing_release_reuse(self):
        root = self.root / 'releases'
        self.addCleanup(self.writable_cleanup, root)
        release, _ = build(self.source, root, self.proof)
        path = release / 'web' / 'fixture.txt'
        path.chmod(0o644)
        path.write_text('changed live files')
        with self.assertRaisesRegex(ValueError, 'manifest'):
            build(self.source, root, self.proof)

    def test_root_directory_symlink_is_rejected(self):
        (self.source / 'pipeline').rename(self.root / 'outside')
        (self.source / 'pipeline').symlink_to(self.root / 'outside', target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            inventory(self.source)

    def test_worker_stamp_changes_for_assets_and_logic_not_downloads(self):
        worker = self.source / 'web/sw.js'
        worker.write_text("const SHELL = 'yedu-shell-v4';\n// worker logic\n")
        first = stamp_shell(self.source)
        self.assertEqual(first, stamp_shell(self.source))
        (self.source / 'web/fixture.txt').write_text('changed JavaScript or CSS')
        second = stamp_shell(self.source)
        self.assertNotEqual(first, second)
        self.assertEqual(second, stamp_shell(self.source))
        downloads = self.source / 'web/download'
        downloads.mkdir()
        (downloads / 'app.apk').write_bytes(b'new APK is not shell content')
        self.assertEqual(second, stamp_shell(self.source))
        worker.write_text(worker.read_text() + '// changed worker logic\n')
        self.assertNotEqual(second, stamp_shell(self.source))


if __name__ == '__main__':
    unittest.main()
