@echo off
call adb shell "su -c 'rm -r /data/data/%1/databases/*'"
call adb shell "su -c 'rm -r /data/data/%1/shared_prefs/%1_preferences.xml'"