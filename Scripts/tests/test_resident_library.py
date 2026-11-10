import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_public_surface import check_resident_library


class ResidentLibraryTests(unittest.TestCase):
    def test_build_hash_and_resource_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'OpenDuckFrame.app'
            resources = app / 'Contents/Resources'
            resources.mkdir(parents=True)
            library = resources / 'gap-fill.metallib'
            sidecar = resources / 'gap-fill.sha256'
            library.write_bytes(b'compiled resident kernel')
            digest = hashlib.sha256(library.read_bytes()).hexdigest()
            sidecar.write_text(digest + '\n')
            check_resident_library(app)
            library.write_bytes(b'compiled resident kerneL')
            with self.assertRaises(SystemExit):
                check_resident_library(app)
            library.write_bytes(b'compiled resident kernel')
            for malformed in [digest, digest + '\r\n', digest + '\n\n',
                              ' ' + digest + '\n', digest.upper() + '\n', 'g' * 64 + '\n']:
                sidecar.write_text(malformed)
                with self.assertRaises(SystemExit):
                    check_resident_library(app)
            sidecar.unlink()
            with self.assertRaises(SystemExit):
                check_resident_library(app)


if __name__ == '__main__':
    unittest.main()
