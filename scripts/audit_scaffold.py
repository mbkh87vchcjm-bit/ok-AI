#!/usr/bin/env python3
"""Temporary CI audit: export generated public Android files in small notices."""
import base64
import io
from pathlib import Path
import sys
import zipfile

root = Path('android')
archive = io.BytesIO()
with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as z:
    for path in sorted(root.rglob('*')):
        if path.is_file() and path.name != 'local.properties' and '.gradle' not in path.parts:
            z.writestr(path.as_posix(), path.read_bytes())
encoded = base64.b64encode(archive.getvalue()).decode('ascii')
parts = [encoded[i:i + 3500] for i in range(0, len(encoded), 3500)]
if len(parts) > 32:
    raise SystemExit('Generated scaffold exceeds audit size limit')
group = int(sys.argv[1])
for i in range(group * 8, min((group + 1) * 8, len(parts))):
    print(f'::notice title=Android scaffold {i + 1} of {len(parts)}::{parts[i]}')
