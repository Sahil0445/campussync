@echo off
REM CampusSync — one-command start on Windows. Needs Python 3.10+.
cd /d "%~dp0backend"
if not exist .venv (
  echo Creating Python environment...
  python -m venv .venv || (echo Python 3.10+ is required: https://www.python.org/downloads/ & pause & exit /b 1)
)
call .venv\Scripts\activate.bat
python -m pip install -q --upgrade pip >nul
python -m pip install -q -r requirements.txt || (echo Could not install packages. & pause & exit /b 1)
if not exist "..\frontend\dist\index.html" (
  echo Building the frontend...
  pushd ..\frontend && call npm install && call npm run build && popd
)
echo.
echo  CampusSync is starting at http://localhost:8000
echo  Phones on the same Wi-Fi: http://YOUR-LAPTOP-IP:8000  (find it with: ipconfig)
echo  Reset demo data anytime at http://localhost:8000/demo
echo.
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
