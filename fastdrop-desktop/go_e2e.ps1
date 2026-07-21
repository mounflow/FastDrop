$env:GOFLAGS = $null
Set-Location "D:\Tools\AboutUniversal\FastDrop\fastdrop-desktop"

Write-Output "=== Building Go binary ==="
go build -o fastdrop.exe ./cmd/fastdrop/
if ($LASTEXITCODE -ne 0) { Write-Output "BUILD FAILED"; exit 1 }
Write-Output "BUILD OK"

Write-Output "=== Starting server ==="
$proc = Start-Process -FilePath ".\fastdrop.exe" -PassThru -NoNewWindow
Start-Sleep -Seconds 2

Write-Output "=== Running E2E tests ==="
powershell -ExecutionPolicy Bypass -File ".\e2e-test.ps1"
$e2eExit = $LASTEXITCODE

Write-Output "=== Stopping server ==="
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue

exit $e2eExit
