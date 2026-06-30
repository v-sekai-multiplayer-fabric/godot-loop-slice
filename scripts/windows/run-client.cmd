@echo off
rem Double-clickable launcher for the loop-slice client. Runs run-client.ps1 as an
rem in-memory scriptblock so Windows execution policy / Mark-of-the-Web never block it.
rem It prompts for the server address (host or IP).
pushd "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path $PWD 'run-client.ps1'))))"
set EC=%ERRORLEVEL%
popd
if not "%EC%"=="0" pause
exit /b %EC%
