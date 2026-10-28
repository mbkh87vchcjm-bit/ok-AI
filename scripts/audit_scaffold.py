#!/usr/bin/env python3
"""Temporary CI audit: expose generated public Android files in annotations."""
import base64
import io
from pathlib import Path
import zipfile

root = Path('android')
archive = io.BytesIO()
with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as z:
    for path in sorted(root.rglob('*')):
        if path.is_file() and path.name != 'local.properties' and '.gradle' not in path.parts:
            z.writestr(path.as_posix(), path.read_bytes())
encoded = base64.b64encode(archive.getvalue()).decode('ascii')
parts = [encoded[i:i + 32000] for i in range(0, len(encoded), 32000)]
for i, part in enumerate(parts):
    print(f'::notice title=Android scaffold {i + 1} of {len(parts)}::{part}')
