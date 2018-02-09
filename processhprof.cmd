for /R %%i in (*.hprof) do (
hprof-conv.exe %%i %%i.hprof
copy /Y "%%i".hprof "%%i"
del /Q "%%i".hprof
)
@pause