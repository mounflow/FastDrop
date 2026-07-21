$env:GOFLAGS = $null
Set-Location "D:\Tools\AboutUniversal\FastDrop\fastdrop-desktop"

# Copy latest Vue build into the //go:embed directory (web/dist → cmd/fastdrop/webdist)
Remove-Item -Path "cmd\fastdrop\webdist\*" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item -Path "web\dist\*" -Destination "cmd\fastdrop\webdist" -Recurse -Force

go build -o fastdrop.exe ./cmd/fastdrop/
if ($LASTEXITCODE -ne 0) { Write-Host "GO BUILD FAILED"; exit 1 }
Write-Host "=== GO BUILD OK ==="
Stop-Process -Name fastdrop -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
$env:APPDATA = "C:\Temp\fastdrop-test"
Start-Process -FilePath ".\fastdrop.exe" -RedirectStandardOutput "C:\Temp\fastdrop-test\server.log" -RedirectStandardError "C:\Temp\fastdrop-test\server_err.log" -NoNewWindow -PassThru | Select-Object Id, ProcessName
Start-Sleep -Seconds 2
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:9527/api/v1/health" -UseBasicParsing -TimeoutSec 5
    Write-Host "Health: $($r.StatusCode) $($r.Content)"
} catch {
    Write-Host "Health check failed: $_"
}
