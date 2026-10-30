@echo off
title Library Management System
cd /d "%~dp0"
where python >nul 2>nul
if errorlevel 1 (
    echo Python 3 is required. Download it from https://www.python.org/downloads/
    pause
    exit /b 1
)
python library.py %*
pause
