@echo off

set argC=0
for %%x in (%*) do Set /A argC+=1

if %argC% NEQ 2 (
goto error
)

SET PKGNAME=%2
SET ARCNAME=.%PKGNAME%-debug-resources.7z

if "%1" == "remove" (
	echo ***** Remove debug resources of package %PKGNAME% to archive %ARCNAME% *****
	call 7z-normal.cmd a -bb1 -ssw -sdel -t7z %ARCNAME% -ir!src\debug*.java -ir!res\layout\debug*.xml -ir!res\xml\debug*.xml
	call check-error-level.cmd
	exit /B 0
)

if "%1" == "restore" (
	echo ***** Restore debug resources of package %PKGNAME% from archive %ARCNAME% *****
	call 7z-normal.cmd x -bb1 %ARCNAME%
	call check-error-level.cmd
	exit /B 0
)

:error
call beep
echo Invalid argument
echo Use: remove^|restore package-name
exit /B 1