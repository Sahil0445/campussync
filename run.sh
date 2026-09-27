#!/usr/bin/env bash
# CampusSync — one-command start on macOS/Linux. Needs Python 3.10+.
set -e
cd "$(dirname "$0")/backend"
[ -d .venv ] || python3 -m venv .venv
. .venv/bin/activate
python -m pip install -q --upgrade pip
python -m pip install -q -r requirements.txt
if [ ! -f ../frontend/dist/index.html ]; then (cd ../frontend && npm install && npm run build); fi
echo
echo " CampusSync is starting at http://localhost:8000"
echo " Phones on the same Wi-Fi: http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo YOUR-IP):8000"
echo " Reset demo data anytime at http://localhost:8000/demo"
echo
exec python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
