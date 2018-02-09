@echo off

SET rasd=%WINDIR%\system32\rasdial
SET serv=schumi-home

if "%1" == "on" (
	echo WIFI = [On]
	adb shell svc wifi enable
	call check-error-level.cmd
	exit /B 0
)

if "%1" == "off" (
	echo WIFI = [Off]
	adb shell svc wifi disable
	call check-error-level.cmd
	exit /B 0
)

if "%1" == "switch" (
	echo WIFI = [Switch]
	adb shell am start -a android.intent.action.MAIN -n com.android.settings/.wifi.WifiSettings > nul
	adb shell input keyevent 19
	adb shell input keyevent 23
	adb shell input keyevent 4	
	call check-error-level.cmd
	exit /B 0
)

echo Use arg: on^|off^|switch
exit /B 1