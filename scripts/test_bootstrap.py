import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('bootstrap', Path(__file__).with_name('bootstrap.py'))
bootstrap = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bootstrap)


class BootstrapTests(unittest.TestCase):
    def test_generates_only_android_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'project'
            root.mkdir()
            (root / 'pubspec.yaml').write_text('name: user_project\n')
            (root / 'lib').mkdir()
            source = root / 'lib/main.dart'
            source.write_text('user code must remain\n')

            def fake_flutter(args, check):
                self.assertTrue(check)
                generated = Path(args[-1]) / 'android'
                (generated / 'app/src/main').mkdir(parents=True)
                (generated / 'gradle/wrapper').mkdir(parents=True)
                (generated / 'app/src/main/AndroidManifest.xml').write_text(
                    '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
                    '    <application\n        android:label="personal_agent"/>\n</manifest>\n')
                (generated / 'app/build.gradle').write_text(
                    'minSdk = flutter.minSdkVersion\nsigningConfig = signingConfigs.debug\n')
                (generated / 'settings.gradle').write_text(
                    'id "com.android.application" version "8.1.0" apply false\n')
                (generated / 'gradle/wrapper/gradle-wrapper.properties').write_text(
                    'distributionUrl=https\\://services.gradle.org/distributions/gradle-8.3-all.zip\n')

            with patch.object(bootstrap, 'ROOT', root), patch.object(bootstrap, 'ANDROID', root / 'android'), \
                 patch.object(bootstrap.shutil, 'which', return_value='/opt/flutter/bin/flutter'), \
                 patch.object(bootstrap.subprocess, 'run', side_effect=fake_flutter) as run:
                self.assertEqual(bootstrap.main(), 0)
                self.assertEqual(source.read_text(), 'user code must remain\n')
                manifest = (root / 'android/app/src/main/AndroidManifest.xml').read_text()
                self.assertIn('android.permission.INTERNET', manifest)
                self.assertIn('android:allowBackup="false"', manifest)
                self.assertIn('android:usesCleartextTraffic="false"', manifest)
                self.assertIn('minSdk = 23', (root / 'android/app/build.gradle').read_text())
                self.assertIn('8.6.1', (root / 'android/settings.gradle').read_text())
                self.assertIn('distributionSha256Sum=', (root / 'android/gradle/wrapper/gradle-wrapper.properties').read_text())
                self.assertEqual(bootstrap.main(), 0)
                self.assertEqual(run.call_count, 1)

    def test_refuses_insecure_existing_manifest_without_modifying_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'pubspec.yaml').write_text('name: x\n')
            folder = root / 'android/app/src/main'
            folder.mkdir(parents=True)
            manifest = folder / 'AndroidManifest.xml'
            manifest.write_text('<manifest><application /></manifest>')
            with patch.object(bootstrap, 'ROOT', root), patch.object(bootstrap, 'ANDROID', root / 'android'):
                with self.assertRaises(SystemExit):
                    bootstrap.main()
            self.assertEqual(manifest.read_text(), '<manifest><application /></manifest>')

    def test_refuses_to_overwrite_incomplete_android(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'pubspec.yaml').write_text('name: x\n')
            (root / 'android').mkdir()
            (root / 'android/keep.txt').write_text('keep')
            with patch.object(bootstrap, 'ROOT', root), patch.object(bootstrap, 'ANDROID', root / 'android'):
                with self.assertRaises(SystemExit):
                    bootstrap.main()
            self.assertEqual((root / 'android/keep.txt').read_text(), 'keep')


if __name__ == '__main__':
    unittest.main()
