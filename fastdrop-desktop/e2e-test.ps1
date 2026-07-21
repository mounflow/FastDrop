$base = 'http://127.0.0.1:9527/api/v1'
$pass = 0; $fail = 0

function Check($name, $ok) {
    if ($ok) { $script:pass++; Write-Output "  PASS  $name" }
    else { $script:fail++; Write-Output "  FAIL  $name" }
}

Write-Output '========== FastDrop E2E Test Suite =========='
Write-Output ''

# --- System ---
Write-Output '[System]'
$h = Invoke-RestMethod -Uri "$base/health"
Check 'health' ($h.status -eq 'ok')
$info = Invoke-RestMethod -Uri "$base/server/info"
Check 'server/info' ($info.platform -eq 'windows' -and $info.port -eq 9527)
$cap = Invoke-RestMethod -Uri "$base/capabilities"
Check 'capabilities' ($cap.chunkSize -eq 4194304 -and $cap.maxConcurrentChunks -eq 3 -and $cap.maxConcurrentFiles -eq 2 -and $cap.maxGlobalHTTP -eq 6)

# --- Web UI ---
Write-Output '[Web UI]'
$web = Invoke-WebRequest -Uri 'http://127.0.0.1:9527/' -UseBasicParsing
Check 'index.html served' ($web.StatusCode -eq 200 -and $web.Content -match 'FastDrop')

# --- Pairing ---
Write-Output '[Pairing]'
$qr = Invoke-RestMethod -Uri "$base/pair/qr"
Check 'QR payload' ($qr.pairId -ne '' -and $qr.token -ne '' -and $qr.port -eq 9527 -and $qr.protocol -eq 'fastdrop')

# Bad token
try {
    $badBody = @{ pairId=$qr.pairId; token='wrong-token'; device=@{ deviceId='x'; deviceName='x'; platform='x' } } | ConvertTo-Json -Depth 3
    Invoke-RestMethod -Uri "$base/pair/request" -Method POST -Body $badBody -ContentType 'application/json'
    Check 'bad token rejected' $false
} catch { Check 'bad token rejected' $true }

# Good token
$pairBody = @{ pairId=$qr.pairId; token=$qr.token; device=@{ deviceId='e2e-phone'; deviceName='E2E Phone'; platform='android'; appVersion='0.1.0' } } | ConvertTo-Json -Depth 3
$pr = Invoke-RestMethod -Uri "$base/pair/request" -Method POST -Body $pairBody -ContentType 'application/json'
Check 'pair request created' ($pr.status -eq 'waiting_confirmation')

# Token is single-use
try {
    Invoke-RestMethod -Uri "$base/pair/request" -Method POST -Body $pairBody -ContentType 'application/json'
    Check 'token single-use' $false
} catch { Check 'token single-use' $true }

# List pending
$pending = Invoke-RestMethod -Uri "$base/pair/requests"
Check 'list pending requests' ($pending.requests.Count -ge 1)

# Accept
$acc = Invoke-RestMethod -Uri "$base/pair/requests/$($pr.requestId)/accept" -Method POST
Check 'pair accept' ($acc.status -eq 'accepted' -and $acc.session.sessionId -ne '' -and $acc.session.accessToken -ne '')
$sid = $acc.session.sessionId; $tok = $acc.session.accessToken
$hdr = @{ 'Authorization'="Bearer $tok"; 'X-Session-Id'=$sid }

# --- Session ---
Write-Output '[Session]'
$sess = Invoke-RestMethod -Uri "$base/session" -Headers $hdr
Check 'session get' ($sess.sessionId -eq $sid)

# Bad auth
try {
    Invoke-RestMethod -Uri "$base/session" -Headers @{ 'Authorization'='Bearer bad'; 'X-Session-Id'='bad' }
    Check 'bad auth rejected' $false
} catch { Check 'bad auth rejected' $true }

# --- Transfer: small file (1 chunk) ---
Write-Output '[Transfer: small file]'
$body = @{ offerId='small'; direction='client_to_server'; files=@(@{ clientFileId='sf1'; name='small.txt'; size=11; mimeType='text/plain' }) } | ConvertTo-Json -Depth 3
$tr = Invoke-RestMethod -Uri "$base/transfers" -Method POST -Body $body -ContentType 'application/json' -Headers $hdr
Check 'create transfer' ($tr.transferId -ne '' -and $tr.files[0].totalChunks -eq 1)
$tid = $tr.transferId; $fid = $tr.files[0].fileId

$data = [System.Text.Encoding]::UTF8.GetBytes('hello world')
$cr = Invoke-RestMethod -Uri "$base/transfers/$tid/files/$fid/chunks/0" -Method PUT -Body $data -ContentType 'application/octet-stream' -Headers $hdr
Check 'upload chunk' ($cr.completedChunks -eq 1)

$comp = Invoke-RestMethod -Uri "$base/transfers/$tid/files/$fid/complete" -Method POST -Body (@{ size=11; sha256='' } | ConvertTo-Json) -ContentType 'application/json' -Headers $hdr
Check 'complete file' ($comp.sha256 -ne '' -and $comp.savedPath -match 'small.*\.txt')

$ft = Invoke-RestMethod -Uri "$base/transfers/$tid" -Headers $hdr
Check 'transfer completed' ($ft.Status -eq 'completed')
Check 'transferredBytes correct' ($ft.TransferredBytes -eq 11)

# Download
$req = [System.Net.HttpWebRequest]::Create("$base/transfers/$tid/files/$fid/content")
$req.Headers.Add('Authorization', "Bearer $tok"); $req.Headers.Add('X-Session-Id', $sid)
$resp = $req.GetResponse()
$sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
Check 'download content' ($sr.ReadToEnd() -eq 'hello world')
$resp.Close()

# --- Transfer: multi-chunk (8MB = 2 chunks) ---
Write-Output '[Transfer: multi-chunk 8MB]'
$sz = 8388608
$body2 = @{ offerId='big'; direction='client_to_server'; files=@(@{ clientFileId='bf1'; name='big.bin'; size=$sz; mimeType='application/octet-stream' }) } | ConvertTo-Json -Depth 3
$tr2 = Invoke-RestMethod -Uri "$base/transfers" -Method POST -Body $body2 -ContentType 'application/json' -Headers $hdr
Check 'create 8MB transfer' ($tr2.files[0].totalChunks -eq 2)
$tid2 = $tr2.transferId; $fid2 = $tr2.files[0].fileId

$c0 = New-Object byte[] 4194304; (New-Object Random).NextBytes($c0)
Invoke-RestMethod -Uri "$base/transfers/$tid2/files/$fid2/chunks/0" -Method PUT -Body $c0 -ContentType 'application/octet-stream' -Headers $hdr | Out-Null
$c1 = New-Object byte[] 4194304; (New-Object Random).NextBytes($c1)
Invoke-RestMethod -Uri "$base/transfers/$tid2/files/$fid2/chunks/1" -Method PUT -Body $c1 -ContentType 'application/octet-stream' -Headers $hdr | Out-Null
$chunks = Invoke-RestMethod -Uri "$base/transfers/$tid2/files/$fid2/chunks" -Headers $hdr
Check 'all chunks received' ($chunks.completedChunks.Count -eq 2 -and $chunks.missingChunks.Count -eq 0)

Invoke-RestMethod -Uri "$base/transfers/$tid2/files/$fid2/complete" -Method POST -Body (@{ size=$sz; sha256='' } | ConvertTo-Json) -ContentType 'application/json' -Headers $hdr | Out-Null
$ft2 = Invoke-RestMethod -Uri "$base/transfers/$tid2" -Headers $hdr
Check '8MB completed' ($ft2.Status -eq 'completed' -and $ft2.TransferredBytes -eq $sz)

# Range download
$req2 = [System.Net.HttpWebRequest]::Create("$base/transfers/$tid2/files/$fid2/content")
$req2.Headers.Add('Authorization', "Bearer $tok"); $req2.Headers.Add('X-Session-Id', $sid)
$req2.AddRange(0, 99)
$resp2 = $req2.GetResponse()
Check 'range download 206' ($resp2.StatusCode -eq 'PartialContent')
Check 'content-range header' ($resp2.Headers['Content-Range'] -eq "bytes 0-99/$sz")
$resp2.Close()

# --- Transfer list ---
Write-Output '[Transfer list]'
$list = Invoke-RestMethod -Uri "$base/transfers" -Headers $hdr
Check 'list transfers' ($list.transfers.Count -ge 2)
$active = Invoke-RestMethod -Uri "$base/transfers/active" -Headers $hdr
Check 'active transfers empty after completion' ($active.transfers.Count -eq 0)

# --- Cancel ---
Write-Output '[Cancel]'
$body3 = @{ offerId='cancel-test'; direction='client_to_server'; files=@(@{ clientFileId='cf1'; name='cancel.txt'; size=100; mimeType='text/plain' }) } | ConvertTo-Json -Depth 3
$tr3 = Invoke-RestMethod -Uri "$base/transfers" -Method POST -Body $body3 -ContentType 'application/json' -Headers $hdr
$cancel = Invoke-RestMethod -Uri "$base/transfers/$($tr3.transferId)/cancel" -Method POST -Headers $hdr
Check 'cancel transfer' ($cancel.status -eq 'cancelled')

# --- Ownership isolation ---
Write-Output '[Security]'
try {
    Invoke-RestMethod -Uri "$base/transfers/$tid" -Headers @{ 'Authorization'="Bearer $tok"; 'X-Session-Id'='fake-session' }
    Check 'cross-session blocked' $false
} catch { Check 'cross-session blocked' $true }

# --- Filename sanitization ---
Write-Output '[Filename sanitization]'
$qr2 = Invoke-RestMethod -Uri "$base/pair/qr"
$pb2 = @{ pairId=$qr2.pairId; token=$qr2.token; device=@{ deviceId='sanitize-phone'; deviceName='Sanitize'; platform='android' } } | ConvertTo-Json -Depth 3
$pr2 = Invoke-RestMethod -Uri "$base/pair/request" -Method POST -Body $pb2 -ContentType 'application/json'
$acc2 = Invoke-RestMethod -Uri "$base/pair/requests/$($pr2.requestId)/accept" -Method POST
$hdr2 = @{ 'Authorization'="Bearer $($acc2.session.accessToken)"; 'X-Session-Id'=$acc2.session.sessionId }

$evilName = '..\..\..\Windows\System32\evil.exe'
$evilBody = @{ offerId='evil'; direction='client_to_server'; files=@(@{ clientFileId='ef1'; name=$evilName; size=4; mimeType='application/octet-stream' }) } | ConvertTo-Json -Depth 3
$trE = Invoke-RestMethod -Uri "$base/transfers" -Method POST -Body $evilBody -ContentType 'application/json' -Headers $hdr2
$fidE = $trE.files[0].fileId
Invoke-RestMethod -Uri "$base/transfers/$($trE.transferId)/files/$fidE/chunks/0" -Method PUT -Body ([byte[]]@(1,2,3,4)) -ContentType 'application/octet-stream' -Headers $hdr2 | Out-Null
$compE = Invoke-RestMethod -Uri "$base/transfers/$($trE.transferId)/files/$fidE/complete" -Method POST -Body (@{ size=4; sha256='' } | ConvertTo-Json) -ContentType 'application/json' -Headers $hdr2
Check 'path traversal sanitized' ($compE.savedPath -notmatch 'System32' -and $compE.savedPath -match 'FastDrop')

# --- Session revoke ---
Write-Output '[Session lifecycle]'
$del = Invoke-RestMethod -Uri "$base/session" -Method DELETE -Headers $hdr
Check 'session revoke' ($del.status -eq 'revoked')
try {
    Invoke-RestMethod -Uri "$base/session" -Headers $hdr
    Check 'revoked session rejected' $false
} catch { Check 'revoked session rejected' $true }

# --- Delete transfer (use a fresh session since $hdr was revoked above) ---
Write-Output '[Cleanup]'
$qr3 = Invoke-RestMethod -Uri "$base/pair/qr"
$pb3 = @{ pairId=$qr3.pairId; token=$qr3.token; device=@{ deviceId='cleanup-phone'; deviceName='Cleanup'; platform='android' } } | ConvertTo-Json -Depth 3
$pr3 = Invoke-RestMethod -Uri "$base/pair/request" -Method POST -Body $pb3 -ContentType 'application/json'
$acc3 = Invoke-RestMethod -Uri "$base/pair/requests/$($pr3.requestId)/accept" -Method POST
$hdr3 = @{ 'Authorization'="Bearer $($acc3.session.accessToken)"; 'X-Session-Id'=$acc3.session.sessionId }
# Create a transfer under this session, then delete it
$delBody = @{ offerId='del-test'; direction='client_to_server'; files=@(@{ clientFileId='d1'; name='del.txt'; size=5; mimeType='text/plain' }) } | ConvertTo-Json -Depth 3
$trD = Invoke-RestMethod -Uri "$base/transfers" -Method POST -Body $delBody -ContentType 'application/json' -Headers $hdr3
$delTr = Invoke-RestMethod -Uri "$base/transfers/$($trD.transferId)" -Method DELETE -Headers $hdr3
Check 'delete transfer' ($delTr.status -eq 'deleted')

Write-Output ''
Write-Output "========== Results: $pass passed, $fail failed =========="
if ($fail -gt 0) { exit 1 }
