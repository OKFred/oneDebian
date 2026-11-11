"""Evidence writer validation; no Windows execution or user credential access."""
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest import mock

if sys.platform != 'linux':
    raise unittest.SkipTest('The evidence writer requires the configured ordinary Linux account')
spec = importlib.util.spec_from_file_location('agent_evidence',Path(__file__).resolve().parents[1] / 'agent/save-evidence.py')
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)


class EvidenceTests(unittest.TestCase):
    def test_only_two_fixed_artifact_names_are_supported(self):
        self.assertEqual({name:settings[0] for name,settings in evidence.ARTIFACTS.items()},
                         {'screenshot':'verification.png','cookie':'verification-cookie.json'})
        with self.assertRaises(ValueError):
            evidence.validate('../../arbitrary-path',b'anything')

    def test_root_is_refused_before_reading_configuration_or_input(self):
        with mock.patch.object(evidence.os,'geteuid',return_value=0), \
             mock.patch.object(evidence.Path,'lstat') as metadata:
            with self.assertRaisesRegex(RuntimeError,'ordinary agent'):
                evidence.save('screenshot',io.BytesIO(b'not a PNG'))
        metadata.assert_not_called()

    def test_cookie_accepts_only_the_synthetic_record_shape(self):
        valid = {'boot_id':'12345678-abcd-abcd-abcd-0123456789ab','value':'a'*64}
        evidence.validate('cookie',json.dumps(valid).encode())
        for invalid in [dict(valid,token='must-not-store'),dict(valid,value='real site cookie'),
                        {'boot_id':valid['boot_id'],'value':['a'*64]},['cookie']]:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                evidence.validate('cookie',json.dumps(invalid).encode())

    def test_screenshot_requires_png_header_and_bounded_dimensions(self):
        header = b'\x89PNG\r\n\x1a\n' + struct.pack('>I',13) + b'IHDR'
        evidence.validate('screenshot',header + struct.pack('>II',1600,900))
        for invalid in [b'executable bytes',header + struct.pack('>II',0,900),header + struct.pack('>II',2**31,900)]:
            with self.assertRaises(ValueError):
                evidence.validate('screenshot',invalid)

    def test_private_state_symlink_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            protected = directory / 'protected'; protected.write_text('not-a-viewer-token')
            (directory / 'viewer-token').symlink_to(protected)
            with mock.patch.object(evidence,'user_directory',return_value=directory):
                with self.assertRaises(OSError):
                    evidence.read_state('read-token')
            self.assertEqual(protected.read_text(),'not-a-viewer-token')

    def test_private_state_owner_and_token_shape_are_validated(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            token = directory / 'viewer-token'; token.write_text('a'*43+'\n'); token.chmod(0o600)
            with mock.patch.object(evidence,'user_directory',return_value=directory):
                self.assertEqual(evidence.read_state('read-token'),'a'*43)
                with mock.patch.object(evidence.os,'geteuid',return_value=os.getuid()+1):
                    with self.assertRaisesRegex(RuntimeError,'Unsafe private'):
                        evidence.read_state('read-token')
                token.write_text('invalid')
                with self.assertRaisesRegex(ValueError,'Invalid viewer'):
                    evidence.read_state('read-token')


if __name__ == '__main__':
    unittest.main()
