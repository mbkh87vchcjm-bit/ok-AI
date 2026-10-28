#!/usr/bin/env python3
"""Generate only the Android scaffold, without overwriting project source.

Run with the Flutter version pinned in the Android workflow. Existing Android
scaffolds are never overwritten; review them and remove them manually if they
need to be regenerated. No API credentials are required.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
ANDROID = ROOT / "android"


def main() -> int:
    if not (ROOT / "pubspec.yaml").is_file():
        raise SystemExit("Run this script from a project containing pubspec.yaml")
    if ANDROID.exists():
        if not (ANDROID / "app/src/main/AndroidManifest.xml").is_file():
            raise SystemExit("android/ already exists but is incomplete; it was not modified")
        print("android/ already exists; leaving it unchanged")
        return 0
    flutter = shutil.which("flutter")
    if not flutter:
        raise SystemExit("Flutter is not on PATH. Install Flutter 3.27.4 first.")
    with tempfile.TemporaryDirectory(prefix="personal-agent-flutter-") as tmp:
        generated = Path(tmp) / "personal_agent"
        subprocess.run(
            [flutter, "create", "--no-pub", "--platforms=android",
             "--project-name=personal_agent", "--org=dev.okai", str(generated)],
            check=True,
        )
        android = generated / "android"
        manifest = android / "app/src/main/AndroidManifest.xml"
        text = manifest.read_text(encoding="utf-8")
        needle = '    <application\n'
        if text.count(needle) != 1:
            raise SystemExit("Unexpected Flutter Android template; refusing to patch it")
        text = text.replace(
            needle,
            '    <uses-permission android:name="android.permission.INTERNET" />\n'
            '    <application\n'
            '        android:allowBackup="false"\n'
            '        android:usesCleartextTraffic="false"\n',
            1,
        ).replace('android:label="personal_agent"', 'android:label="OK AI"')
        manifest.write_text(text, encoding="utf-8")
        gradle = android / "app/build.gradle"
        text = gradle.read_text(encoding="utf-8")
        needle = "minSdk = flutter.minSdkVersion"
        if text.count(needle) != 1 or "signingConfig = signingConfigs.debug" not in text:
            raise SystemExit("Unexpected Gradle template; refusing to patch it")
        gradle.write_text(text.replace(needle, "minSdk = 23", 1), encoding="utf-8")
        # Copy only the platform scaffold. The application's lib/, pubspec,
        # tests and workflow remain untouched.
        shutil.copytree(android, ANDROID)
    print("Generated android/ with HTTPS-only traffic and Android backups disabled.")
    print("The template's release build uses a DEBUG signing key; it is not a production signature.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
