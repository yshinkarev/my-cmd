@echo off

if "%1" == "mute" (
	nircmd.exe mutesysvolume 1
	exit /B 0
)

if "%1" == "unmute" (
	nircmd.exe mutesysvolume 0
	exit /B 0
)

if "%1" == "work" (
	call nircmd.exe setsysvolume 20000
	exit /B 0
)

if "%1" == "full" (
	call nircmd.exe setsysvolume 65535
	exit /B 0
)

call beep
echo Invalid argument. Use: mute, unmute, full, work.
pause
exit /B 1