@set dir=%1
@set arcname=%dir%/.archive.tar

::call adb shell "su -c 'tar cvf %arcname% %dir%'"
call adb shell "tar cvf %arcname% %dir%"

