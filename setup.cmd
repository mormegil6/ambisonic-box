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

rem pushd rather than `cd /d`: cmd.exe refuses a UNC path as a working directory
rem and would leave us wherever we started, with every relative path below
rem quietly pointing somewhere else. pushd maps the share to a drive letter.
pushd "%~dp0" || goto :notrepo
if not exist "scripts\setup.sh" goto :notrepo

rem --- find a bash -----------------------------------------------------------
rem The three default install locations first: this is the branch that was
rem tested on real Windows, and it spawns no processes.
set "GITBASH="
if exist "%ProgramFiles%\Git\bin\bash.exe" set "GITBASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined GITBASH if exist "%ProgramW6432%\Git\bin\bash.exe" set "GITBASH=%ProgramW6432%\Git\bin\bash.exe"
if not defined GITBASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "GITBASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined GITBASH if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" set "GITBASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"

rem Git installed somewhere else entirely, which the installer allows and which
rem people with a small system drive do (D:\Git). Its installer records the
rem location under HKCU for a per-user install and HKLM for a machine-wide one,
rem and reads that same key back when it upgrades itself, so it is a supported
rem contract rather than an implementation detail. This is also the only lookup
rem that finds the "Git Bash only" install option, which adds nothing to PATH.
if not defined GITBASH call :from_registry HKCU
if not defined GITBASH call :from_registry HKLM

rem Last resort: under either of the installer's other two PATH options git
rem itself is on PATH as INSTALLDIR\cmd\git.exe, so bash is one directory over.
rem This also declines correctly for the MinGit that GitHub Desktop bundles,
rem which is a real git with no bash.exe anywhere near it.
if not defined GITBASH for /f "delims=" %%I in ('where git 2^>nul') do call :try_bash "%%~dpI..\bin\bash.exe"

if not defined GITBASH goto :no_bash

rem Handed over as a RELATIVE path with forward slashes on purpose. setup.sh
rem does `cd "$(dirname "$0")/.."`, and the MSYS coreutils in Git Bash treat a
rem backslash as an ordinary filename character, so a Windows-style absolute
rem path here would make dirname return "." and send the script hunting for the
rem repo one directory above wherever it happened to start.
"%GITBASH%" scripts/setup.sh %*
set "RC=%ERRORLEVEL%"
goto :held

:no_bash
rem No shell on this machine, but Docker is already a hard prerequisite of this
rem stack, so borrow one from it rather than dead-ending. Still the same
rem scripts/setup.sh, against the same folder: nothing is reimplemented here
rem either. The image is the one rtmp-ingest already builds on, read out of its
rem Dockerfile so the two cannot drift apart.
docker version >nul 2>&1 || goto :manual
set "SETUP_IMG="
for /f "tokens=2" %%I in ('findstr /b /c:"FROM alpine:" services\rtmp-ingest\Dockerfile 2^>nul') do set "SETUP_IMG=%%I"
if not defined SETUP_IMG goto :manual
echo.
echo No Git Bash on this machine, so setup runs inside %SETUP_IMG% instead.
echo One part of it cannot come along: the warning about ports another program
echo already holds, which a container has no way to see. If "docker compose up"
echo later complains about a port, that is what it would have caught.
echo.
docker run --rm -v "%CD%:/repo" -w /repo %SETUP_IMG% sh scripts/setup.sh
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" goto :manual
goto :held

:manual
echo.
echo Could not run the setup script here: no Git Bash found, and Docker is not
echo installed or not running either.
echo.
echo Git Bash ships with Git for Windows, and you needed Git to clone this
echo repository, so it was probably installed some other way. Installing it
echo from https://git-scm.com/download/win and re-running this is the short
echo path.
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

:notrepo
echo.
echo This belongs in the ambisonic-box folder, next to scripts\setup.sh, and it
echo cannot see that from where it is now. Move it back into your clone, or run
echo scripts/setup.sh from Git Bash instead.
echo.
goto :held

:held
popd
rem Double-clicking in Explorer runs this in a window that closes the instant it
rem exits, taking the generated OBS URL with it. Explorer launches us through
rem `cmd /c` with this file's FULL path on the command line, so cmdcmdline
rem contains that path only then; typing setup.cmd in a shell does not. Matching
rem on /c instead would pause on every `cmd /c`, including over ssh.
rem
rem DELAYED expansion, and quoting is not a substitute for it. cmdcmdline holds
rem the whole command line that started this window, quotes and all, so a normal
rem %cmdcmdline% is pasted into the line before cmd parses it and every operator
rem inside is then read as syntax. Wrapping it in quotes does not help, because
rem the value carries its own quotes which close the ones you added. Measured on
rem Windows 11 rather than reasoned about: the quoted version re-invoked this
rem file through the `&&` in its own command line and died at
rem "BATCH RECURSION exceeds STACK limits", 248 deep, after a successful setup.
rem With ! expansion the substitution happens after parsing, so the value is
rem data and cannot be executed. Scoped to this one line so that a clone path
rem containing an exclamation mark cannot be mangled anywhere else.
rem
rem find.exe by full path, because a bare `find` is not reliably Windows' find:
rem Git's third PATH option ("optional Unix tools from the Command Prompt")
rem puts usr\bin ahead of it, where find is the POSIX one, which reads /i as a
rem directory to search and exits nonzero. The window would then shut on every
rem double-click, which is the one thing this line exists to prevent.
setlocal enabledelayedexpansion
echo !cmdcmdline! | "%SystemRoot%\System32\find.exe" /i "%~f0" >nul && pause
endlocal
exit /b %RC%

rem --- subroutines, past the exit above so nothing can fall into them ---------

:from_registry
rem find.exe by full path, for the reason given at the pause line above.
for /f "tokens=2,*" %%A in ('reg query "%~1\Software\GitForWindows" /v InstallPath 2^>nul ^| "%SystemRoot%\System32\find.exe" /i "InstallPath"') do call :try_bash "%%B\bin\bash.exe"
goto :eof

:try_bash
if defined GITBASH goto :eof
rem %~f1 rather than %1: it resolves the ..\ that the `where git` caller passes.
if exist "%~f1" set "GITBASH=%~f1"
goto :eof
