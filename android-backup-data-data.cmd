@echo off

set pkgname=%1
set arcname=sdcard/%pkgname%-%2.tar

echo Backup data/data of %pkgname% to %arcname%...

call adb shell rm %arcname%
call adb shell "su -c 'tar cvf %arcname% /data/data/%pkgname%/*'"