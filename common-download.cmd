@echo off

if "%1" == "" (
 echo "Args: url [type:sha1/sha256/md5] [hash]"
 exit
)

set url=%1
for /f "tokens=*" %%i in ('basename %url%') do set filename=%%i
echo Url: %url%
echo Filename: %filename%

wget --no-check-certificate -O %filename% %url%

if %errorlevel% NEQ 0 goto on_error

if "%2" == "" exit

if "%3" == "" (
echo set type of hash and hash arguments
goto on_error
)

set type=%2
set hash=%3

if "%type%" == "sha1" (
set sumcmd=sha1sum
goto calc
)


if "%type%" == "md5" (
set sumcmd=md5sum
goto calc
) 

if "%type%" == "sha256" (
set sumcmd=sha256sum
goto calc
)

echo Unknown type [%type%]. Supported: sha1, sha256, md5.
goto on_error

:calc
echo Check %type%...
echo %hash% *%filename% | %sumcmd% --check

call check-error-level
exit

:on_error
call beep
pause
exit /b 1