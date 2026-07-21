$env:GOFLAGS = $null
Set-Location "D:\Tools\AboutUniversal\FastDrop\fastdrop-desktop"

Write-Output "=== go build ==="
go build ./...
if ($LASTEXITCODE -ne 0) { Write-Output "BUILD FAILED"; exit 1 }
Write-Output "BUILD OK"

Write-Output ""
Write-Output "=== go test ==="
go test ./...
if ($LASTEXITCODE -ne 0) { Write-Output "TESTS FAILED"; exit 1 }
Write-Output "ALL TESTS PASSED"
