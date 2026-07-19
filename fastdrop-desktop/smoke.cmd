@echo off
REM End-to-end smoke test against a running FastDrop server.
setlocal enabledelayedexpansion

set BASE=http://127.0.0.1:9527/api/v1

echo === 1. /health ===
curl.exe -s %BASE%/health
echo.

echo === 2. /pair/qr ===
curl.exe -s %BASE%/pair/qr > qr.json
type qr.json
echo.

REM Extract fields via PowerShell (cmd has no native JSON parser).
for /f "delims=" %%i in ('powershell -NoProfile -Command "(Get-Content qr.json | ConvertFrom-Json).pairId"') do set PAIR_ID=%%i
for /f "delims=" %%i in ('powershell -NoProfile -Command "(Get-Content qr.json | ConvertFrom-Json).token"') do set PAIR_TOKEN=%%i

echo pairId=!PAIR_ID!
echo token=!PAIR_TOKEN!

echo === 3. POST /pair/request (correct token) ===
curl.exe -s -X POST -H "Content-Type: application/json" ^
  -d "{\"pairId\":\"!PAIR_ID!\",\"token\":\"!PAIR_TOKEN!\",\"device\":{\"deviceId\":\"android-1\",\"deviceName\":\"Pixel\",\"platform\":\"android\"}}" ^
  %BASE%/pair/request > pair_res.json
type pair_res.json
echo.

for /f "delims=" %%i in ('powershell -NoProfile -Command "(Get-Content pair_res.json | ConvertFrom-Json).requestId"') do set REQ_ID=%%i

echo === 4. POST /pair/requests/!REQ_ID!/accept ===
curl.exe -s -X POST %BASE%/pair/requests/!REQ_ID!/accept
echo.

echo === 5. GET /pair/requests/!REQ_ID! (expect accepted) ===
curl.exe -s %BASE%/pair/requests/!REQ_ID! > accepted.json
type accepted.json
echo.

for /f "delims=" %%i in ('powershell -NoProfile -Command "(Get-Content accepted.json | ConvertFrom-Json).session.sessionId"') do set SID=%%i
for /f "delims=" %%i in ('powershell -NoProfile -Command "(Get-Content accepted.json | ConvertFrom-Json).session.accessToken"') do set TOK=%%i

echo sessionId=!SID!
echo accessToken=!TOK!

echo === 6. POST /transfers (file: hello.txt = 11 bytes) ===
curl.exe -s -X POST -H "Content-Type: application/json" ^
  -H "Authorization: Bearer !TOK!" -H "X-Session-Id: !SID!" ^
  -d "{\"offerId\":\"o1\",\"direction\":\"client_to_server\",\"files\":[{\"clientFileId\":\"c1\",\"name\":\"hello.txt\",\"size\":11}]}" ^
  %BASE%/transfers > tx.json
type tx.json
echo.

for /f "delims=" %%i in ('powershell -NoProfile -Command "(Get-Content tx.json | ConvertFrom-Json).transferId"') do set TX=%%i
for /f "delims=" %%i in ('powershell -NoProfile -Command "(Get-Content tx.json | ConvertFrom-Json).files[0].fileId"') do set FID=%%i

echo === 7. PUT chunk 0 ===
echo hello world> hello.txt
curl.exe -s -X PUT -H "Content-Type: application/octet-stream" ^
  -H "Authorization: Bearer !TOK!" -H "X-Session-Id: !SID!" ^
  --data-binary "@hello.txt" ^
  %BASE%/transfers/!TX!/files/!FID!/chunks/0
echo.

echo === 8. POST /complete ===
curl.exe -s -X POST -H "Content-Type: application/json" ^
  -H "Authorization: Bearer !TOK!" -H "X-Session-Id: !SID!" ^
  -d "{\"size\":11,\"sha256\":\"b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9\"}" ^
  %BASE%/transfers/!TX!/files/!FID!/complete
echo.

echo === 9. Negative: bad token ===
curl.exe -s -o nul -w "HTTP_STATUS=%%{http_code}\n" -X POST -H "Content-Type: application/json" ^
  -d "{\"pairId\":\"!PAIR_ID!\",\"token\":\"WRONG\",\"device\":{\"deviceId\":\"x\",\"deviceName\":\"y\",\"platform\":\"android\"}}" ^
  %BASE%/pair/request

endlocal
