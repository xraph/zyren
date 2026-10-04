import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import planet


class PlanetCommandTest(unittest.TestCase):
    def test_provider_is_forwarded_to_every_build_and_launcher(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'provider.json'
            config.write_text(json.dumps({'ZYREN_CESIUM_ION_TOKEN': 'fixture-token'}))
            for command in [['run', '-d', 'macos'], ['build', 'ios', '--release'],
                            ['build', 'apk', '--release'], ['drive', '-d', 'macos']]:
                with self.subTest(command=command), patch.object(planet.subprocess, 'run') as run:
                    run.return_value.returncode = 0
                    self.assertEqual(planet.main(['--provider-config', str(config), *command]), 0)
                    invoked = run.call_args.args[0]
                    self.assertEqual(invoked[:2], ['fvm', 'flutter'])
                    self.assertEqual(invoked[2:-1], command)
                    self.assertEqual(invoked[-1], f'--dart-define-from-file={config.resolve()}')
                    self.assertNotIn('fixture-token', ' '.join(invoked))
                    self.assertEqual(run.call_args.kwargs['cwd'], planet.ROOT / 'examples/planet')

    def test_missing_empty_and_malformed_config_prevent_a_credentialless_build(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'provider.json'
            for contents in [None, '{}', '[]', 'private-invalid-json',
                             '{"ZYREN_CESIUM_ION_TOKEN": " "}',
                             '{"ZYREN_CESIUM_ION_TOKEN": 123}']:
                if contents is not None:
                    config.write_text(contents)
                with self.subTest(contents=contents), patch.object(planet.subprocess, 'run') as run:
                    error = io.StringIO()
                    with contextlib.redirect_stderr(error), self.assertRaises(SystemExit):
                        planet.main(['--provider-config', str(config), 'build', 'apk'])
                    run.assert_not_called()
                    self.assertNotIn('private-invalid-json', error.getvalue())

    def test_offline_is_explicit_and_preserves_flutter_failures(self):
        with patch.object(planet.subprocess, 'run') as run:
            run.return_value.returncode = 7
            result = planet.main(['--offline', '--flutter', '/sdk/flutter', 'build', 'ios'])
            self.assertEqual(result, 7)
            self.assertEqual(run.call_args.args[0], ['/sdk/flutter', 'build', 'ios'])

    def test_provider_overrides_cannot_silently_clear_the_token(self):
        for flags in [['--dart-define=ZYREN_CESIUM_ION_TOKEN='],
                      ['--dart-define', 'ZYREN_GOOGLE_MAPS_KEY='],
                      ['--dart-define-from-file=another.json']]:
            with self.subTest(flags=flags), patch.object(planet.subprocess, 'run') as run:
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                    planet.main(['--offline', 'build', 'apk', *flags])
                run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
