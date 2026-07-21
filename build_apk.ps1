$env:PUB_CACHE = "D:\pub-cache"
$env:ANDROID_HOME = "D:\Tools\AboutCode\AndroidStudio\Sdk"
$env:GRADLE_USER_HOME = "D:\gradle-home"
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
$env:PATH = "D:\Tools\flutter\bin;D:\Tools\AboutCode\AndroidStudio\Sdk\platform-tools;" + $env:PATH

Set-Location "D:\Tools\AboutUniversal\FastDrop\fastdrop-mobile"
Write-Host "=== Flutter build APK ==="
flutter build apk --debug --target-platform android-arm64
if ($LASTEXITCODE -ne 0) {
    Write-Host "BUILD FAILED"
    exit 1
}
Write-Host "=== BUILD OK ==="

$adb = "D:\Tools\AboutCode\AndroidStudio\Sdk\platform-tools\adb.exe"
$pkg = "com.fastdrop.fastdrop_mobile"
$apk = "build\app\outputs\flutter-apk\app-debug.apk"

Write-Host "=== Force stopping app ==="
& $adb shell am force-stop $pkg

Write-Host "=== Installing APK ==="
& $adb install -r $apk
if ($LASTEXITCODE -ne 0) { Write-Host "INSTALL FAILED"; exit 1 }
Write-Host "=== INSTALL OK ==="
