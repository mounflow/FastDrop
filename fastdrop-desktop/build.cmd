@echo off
REM FastDrop Windows build script
REM 1. Builds Vue frontend
REM 2. Copies dist/ to Go embed directory
REM 3. Builds Go binary

setlocal

echo === Building Vue frontend ===
cd /d "%~dp0web"
call npm run build
if %ERRORLEVEL% neq 0 (
    echo ERROR: Vue build failed
    exit /b 1
)

echo === Copying dist to embed path ===
cd /d "%~dp0"
if exist "cmd\fastdrop\webdist" (
    rmdir /s /q "cmd\fastdrop\webdist"
)
xcopy /e /i "web\dist" "cmd\fastdrop\webdist"
echo OK: webdist prepared

echo === Building Windows desktop app ===
cd /d "%~dp0"
set GOFLAGS=
set GOCACHE=%~dp0.gocache
if not exist "build\bin" mkdir "build\bin"
go build -tags desktop,production -ldflags "-w -s -H windowsgui" -o "build\bin\FastDrop.exe" ./cmd/fastdrop/
if %ERRORLEVEL% neq 0 (
    echo ERROR: Go build failed
    exit /b 1
)

echo === Build complete: build\bin\FastDrop.exe ===
