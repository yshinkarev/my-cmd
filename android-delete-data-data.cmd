@echo off
call adb shell "su -c 'rm -r /data/data/%1/*'"