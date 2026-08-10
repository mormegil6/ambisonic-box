@echo off
rem Windows entry point. There is no second implementation here on purpose:
rem this finds a shell and hands over to scripts/setup.sh, which stays the only
rem thing that knows what setup does.
rem
rem WHY NOT just tell people to run `bash scripts/setup.sh`: on Windows `bash`
rem is not Git Bash. Verified on Windows 11 build 26200: `where bash` returns
rem C:\Windows\System32\bash.exe, the WSL launcher, while Git's bash.exe lives
rem in Git\bin which the default installer does NOT put on PATH. So the obvious
rem command silently reaches a different machine, or hangs waiting for a WSL
rem distro that was never installed.
rem
rem This file must stay CRLF. .gitattributes forces LF repo-wide, which is right
rem for everything that runs in a Linux container and wrong for a batch file:
rem cmd.exe mis-parses LF-only scripts around labels and goto. There is an
rem explicit *.cmd rule next to the blanket one.

setlocal
set "RC=1"
cd /d "%~dp0"

set "GITBASH="
if exist "%ProgramFiles%\Git\bin\bash.exe" set "GITBASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined GITBASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "GITBASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined GITBASH if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" set "GITBASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"

if defined GITBASH goto :run

echo.
echo Could not find Git Bash, which this needs to run the setup script.
echo.
echo You almost certainly have it already: it ships with Git for Windows, and
echo you needed Git to clone this repository. If Git was installed some other
echo way, reinstall it from https://git-scm.com/download/win and re-run this.
echo.
echo Or set the two credentials by hand, which is all the stack needs to start:
echo   1. copy .env.example .env
echo   2. open .env and change RTMP_OWNER_KEY and LOOP_SOURCE_KEY to any
echo      random strings of about 30 letters and digits
echo   3. docker compose up -d
echo.
echo That skips the owner SRT route on UDP 8891. To get it too, also copy
echo docker-compose.override.yml.example to docker-compose.override.yml and
echo set SRT_OWNER_PASSPHRASE in .env.
echo.
goto :held

:run
"%GITBASH%" scripts/setup.sh %*
set "RC=%ERRORLEVEL%"

:held
rem Double-clicking in Explorer runs this in a window that closes the instant it
rem exits, taking the generated OBS URL with it. Explorer launches us as
rem `cmd /c ""<full path>" "`, so cmdcmdline contains this file's FULL path only
rem then; typing `setup` in a shell does not. Matching on /c instead would pause
rem on every `cmd /c`, including over ssh.
echo %cmdcmdline% | find /i "%~f0" >nul && pause
exit /b %RC%
