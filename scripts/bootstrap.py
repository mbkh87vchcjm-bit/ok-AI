#!/usr/bin/env python3
"""Generate only the Android scaffold, without overwriting project source.

Run with the Flutter version pinned in the Android workflow. Existing Android
scaffolds are never overwritten; review them and remove them manually if they
need to be regenerated. No API credentials are required.
"""
from pathlib import Path
import shutil
import re
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
        # Newer AndroidX WebKit requires AGP >= 8.1.1. Pair AGP 8.6.1
        # with its supported Gradle 8.7 and verify the distribution checksum.
        settings = android / "settings.gradle"
        settings_text = settings.read_text(encoding="utf-8")
        settings_text, count = re.subn(
            r'(id "com\.android\.application" version ")[^"]+(" apply false)',
            r'\g<1>8.6.1\g<2>', settings_text,
        )
        if count != 1:
            raise SystemExit("Unexpected Android plugin template; refusing to patch it")
        settings.write_text(settings_text, encoding="utf-8")
        wrapper = android / "gradle/wrapper/gradle-wrapper.properties"
        wrapper_text = wrapper.read_text(encoding="utf-8")
        wrapper_text, count = re.subn(
            r'distributionUrl=.*',
            lambda _: r'distributionUrl=https\://services.gradle.org/distributions/gradle-8.7-bin.zip',
            wrapper_text,
        )
        if count != 1 or "distributionSha256Sum=" in wrapper_text:
            raise SystemExit("Unexpected Gradle wrapper template; refusing to patch it")
        # https://gradle.org/release-checksums/ (8.7 binary distribution)
        wrapper_text += "\ndistributionSha256Sum=544c35d6bd849ae8a5ed0bcea39ba677dc40f49df7d1835561582da2009b961d\n"
        wrapper.write_text(wrapper_text, encoding="utf-8")
        # Copy only the platform scaffold. The application's lib/, pubspec,
        # tests and workflow remain untouched.
        shutil.copytree(android, ANDROID)
    print("Generated android/ with HTTPS-only traffic and Android backups disabled.")
    print("The template's release build uses a DEBUG signing key; it is not a production signature.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
