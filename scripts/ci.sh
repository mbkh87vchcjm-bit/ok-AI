#!/usr/bin/env bash
# Preserve useful, bounded failure diagnostics as a GitHub annotation as well
# as the normal log. No secrets should be passed as command arguments.
set -uo pipefail
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
"$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
if [ "$status" -ne 0 ]; then
  python3 - "$log" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text(encoding='utf-8', errors='replace')
text = '\n'.join(text.splitlines()[-80:])[-8000:]
text = text.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
print(f'::error title=Command failed::{text}')
PY
fi
exit "$status"
