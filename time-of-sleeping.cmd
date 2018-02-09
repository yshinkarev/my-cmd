@echo off
wevtutil qe System /q:"*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter']]]" /rd:true /c:1 /f:text
wmic os get lastbootuptime
powercfg -lastwake
net statistics workstation | findstr после