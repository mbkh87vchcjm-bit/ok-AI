#!/usr/bin/env python3
"""Temporary CI audit: export the resolved public dependency lockfile."""
import base64
from pathlib import Path
import zlib

encoded = base64.b64encode(zlib.compress(Path('pubspec.lock').read_bytes())).decode('ascii')
parts = [encoded[i:i + 3500] for i in range(0, len(encoded), 3500)]
for i, part in enumerate(parts):
    print(f'::notice title=Resolved lock {i + 1} of {len(parts)}::{part}')
