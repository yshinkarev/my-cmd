@echo off

set pkgname=%1
set arcname=sdcard/%pkgname%-%2.tar

echo Restore data/data from %arcname% to %pkgname%...
call adb shell "su -c 'tar xvf %arcname%'"

set newowner=%3

if "%newowner%" == "" (
	goto end
)

set dir=/data/data/%pkgname%
set ug=%newowner%:%newowner%

call adb shell "su -c 'chown %ug% %dir%/'"
call adb shell "su -c 'chown %ug% %dir%/*'"

call adb shell "su -c 'chown %ug% %dir%/app_webview/*'"
call adb shell "su -c 'chown %ug% %dir%/cache/*'"
call adb shell "su -c 'chown %ug% %dir%/databases/*'"
call adb shell "su -c 'chown %ug% %dir%/files/*'"
call adb shell "su -c 'chown %ug% %dir%/shared_prefs/*'"

:end



