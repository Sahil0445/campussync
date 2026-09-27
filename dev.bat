@echo off
REM Development mode: API with auto-reload on :8000, Vite dev server on :5173 (hot reload).
cd /d "%~dp0"
start "CampusSync API" cmd /k "cd backend && .venv\Scripts\activate.bat && python -m uvicorn app.main:app --reload --port 8000"
cd frontend
if not exist node_modules call npm install
call npm run dev
