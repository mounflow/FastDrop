@echo off
REM Build the Vue UI and copy the output into cmd/fastdrop/webdist/ so
REM the Go //go:embed picks it up. Run from the fastdrop-desktop root.
setlocal
pushd "%~dp0"
call npm run build
if errorlevel 1 (
  echo build failed
  popd
  exit /b 1
)
if exist "..\cmd\fastdrop\webdist" rmdir /s /q "..\cmd\fastdrop\webdist"
xcopy /e /i /y "dist" "..\cmd\fastdrop\webdist" > nul
popd
echo webdist updated.
