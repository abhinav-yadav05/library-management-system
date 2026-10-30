@echo off
title Athenaeum Library Portal
cd /d "%~dp0"
where python >nul 2>nul || (echo Python 3 is required: https://www.python.org/downloads/ & pause & exit /b 1)
start "" http://localhost:8100
python portal.py %*
