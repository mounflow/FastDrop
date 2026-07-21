# Force rebuild: copy Vue dist → webdist embed dir, then rebuild Go
$env:GOFLAGS = $null
Set-Location "D:\Tools\AboutUniversal\FastDrop\fastdrop-desktop"

$src = "web\dist"
$dst = "cmd\fastdrop\webdist"

Write-Host "=== Step 1: Copy Vue build to embed directory ==="
Write-Host "Source: $src"
Write-Host "Dest:   $dst"

# Remove old embed files
Remove-Item -Path "$dst\*" -Recurse -Force -ErrorAction SilentlyContinue
# Copy new build
Copy-Item -Path "$src\*" -Destination $dst -Recurse -Force
Write-Host "Copied files:"
Get-ChildItem $dst -Recurse -File | ForEach-Object { Write-Host "  $($_.Name) ($($_.Length) bytes)" }

Write-Host ""
Write-Host "=== Step 2: Rebuild Go binary ==="
go build -o fastdrop.exe ./cmd/fastdrop/ 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "GO BUILD FAILED (exit code $LASTEXITCODE)"
    exit 1
}
Write-Host "GO BUILD OK"
Write-Host "Binary timestamp: $((Get-Item fastdrop.exe).LastWriteTime)"

Write-Host ""
Write-Host "=== Step 3: Restart server ==="
Stop-Process -Name fastdrop -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

$env:APPDATA = "C:\Temp\fastdrop-test"
Start-Process -FilePath ".\fastdrop.exe" `
    -RedirectStandardOutput "C:\Temp\fastdrop-test\server.log" `
    -RedirectStandardError "C:\Temp\fastdrop-test\server_err.log" `
    -NoNewWindow -PassThru | Select-Object Id, ProcessName

Start-Sleep -Seconds 2

Write-Host ""
Write-Host "=== Step 4: Verify ==="
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:9527/api/v1/health" -UseBasicParsing -TimeoutSec 5
    Write-Host "Health: $($r.StatusCode) $($r.Content)"
} catch {
    Write-Host "Health check failed: $_"
}

try {
    $html = Invoke-WebRequest -Uri "http://127.0.0.1:9527/" -UseBasicParsing -TimeoutSec 5
    $jsFile = [regex]::Match($html.Content, 'src="/assets/(index-[^"]+\.js)"').Groups[1].Value
    $cssFile = [regex]::Match($html.Content, 'href="/assets/(index-[^"]+\.css)"').Groups[1].Value
    Write-Host "Served JS:  $jsFile"
    Write-Host "Served CSS: $cssFile"
    if ($jsFile -eq "index-8Wa7uE-H.js") {
        Write-Host ">>> SUCCESS: Latest Vue build is being served! <<<"
    } else {
        Write-Host ">>> MISMATCH: Expected index-8Wa7uE-H.js <<<"
    }
} catch {
    Write-Host "Failed to fetch index page: $_"
}
