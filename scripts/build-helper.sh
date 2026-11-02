#!/bin/bash
# Freezes helper/spoof_helper.py with its own Python into helper/build/dist/spoof-helper, one file.
set -euo pipefail
cd "$(dirname "$0")/../helper"
venv=build/venv
[ -x "$venv/bin/python" ] || { python3 -m venv "$venv"; "$venv/bin/pip" -q install -r requirements.txt pyinstaller; }
"$venv/bin/pyinstaller" --noconfirm --clean --onefile --name spoof-helper --log-level WARN \
    --distpath build/dist --workpath build/work --specpath build \
    --collect-all pymobiledevice3 --collect-all developer_disk_image --collect-all pmd_pytcp \
    --collect-all pmd_net_addr --collect-data certifi --recursive-copy-metadata pymobiledevice3 spoof_helper.py
