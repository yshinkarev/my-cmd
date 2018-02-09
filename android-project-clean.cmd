@echo off

echo Delete logs files (tests)...
del tracks-*.log /F /Q /S

echo Delete class-files...
del *.class /F /Q /S

echo Delete classes.dex...
del classes.dex /F /Q /S

echo Delete resources.ap_...
del resources.ap_ /F /Q /S

echo Delete R.txt...
del R.txt /F /Q /S

echo Delete jarlist.cache...
del jarlist.cache /F /Q /S

call beep.cmd
call check-error-level.cmd