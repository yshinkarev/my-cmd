@echo off

rem set username
echo Username: %1
call itext %1

rem tab to password field
call ikeyevent KEYCODE_TAB

rem set password
echo Password: %2
call itext %2
rem tab to Login/SignIn button and press it
call ikeyevent KEYCODE_TAB
call ikeyevent KEYCODE_SPACE