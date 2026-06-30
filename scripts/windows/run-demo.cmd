@echo off
rem Double-clickable launcher for the loot-action demo. It runs run-demo.ps1 as an
rem in-memory scriptblock, so Windows execution policy and Mark-of-the-Web (which block
rem running downloaded .ps1 files) never apply -- policy is about script files, not
rem scriptblocks created in memory. No scoop, no policy change, no Unblock-File needed.
pushd "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path $PWD 'run-demo.ps1'))))"
set EC=%ERRORLEVEL%
popd
if not "%EC%"=="0" pause
exit /b %EC%
