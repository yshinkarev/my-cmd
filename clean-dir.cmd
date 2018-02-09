@echo off
::http://stackoverflow.com/questions/1965787/how-to-delete-files-subfolders-in-a-specific-directory-at-command-prompt-in-wind
echo Clean folder: %1

FOR /D %%p IN ("%1\*.*") DO (
::rmdir "%%p" /s /q
echo %%p
rmdir "%%p" /s /q
)

del %1\*.* /s /q