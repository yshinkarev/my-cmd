@echo off

if %errorlevel% NEQ 0 (
	call beep.cmd	 
	echo Error level: %errorlevel%
	pause
	exit %errorlevel%
)