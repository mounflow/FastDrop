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

echo === Preparing Windows icon resources ===
where windres >nul 2>nul
if %ERRORLEVEL% equ 0 (
    pushd "%~dp0resources\windows"
    windres -i "fastdrop.rc" -o "%~dp0cmd\fastdrop\fastdrop_windows_amd64.syso" -O coff
    if errorlevel 1 (
        popd
        echo ERROR: Windows resource build failed
        exit /b 1
    )
    popd
) else if not exist "%~dp0cmd\fastdrop\fastdrop_windows_amd64.syso" (
    echo ERROR: windres is unavailable and the prebuilt Windows resource is missing
    exit /b 1
) else (
    echo INFO: windres not found; using the checked-in Windows resource
)

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
