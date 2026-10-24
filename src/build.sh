#!/bin/bash
# Rebuilds install.sh from the pieces in src/. Run after editing any of them, then commit install.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
t = open("src/install-template.sh").read()
t = t.replace("@@YTDL_SH@@", open("src/ytdl.sh").read().rstrip("\n"))
t = t.replace("@@APP_APPLESCRIPT@@", open("src/app.applescript").read().rstrip("\n"))
open("install.sh", "w").write(t)
PY
chmod +x install.sh
echo "Rebuilt install.sh"
