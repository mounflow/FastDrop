$env:PATH = "D:\Tools\flutter\bin;" + $env:PATH
$env:ANDROID_HOME = "D:\Tools\AboutCode\AndroidStudio\Sdk"
$env:JAVA_HOME = "D:\Tools\AboutCode\AndroidStudio\jbr"
$adb = "$env:ANDROID_HOME\platform-tools\adb.exe"
Set-Location "D:\Tools\AboutUniversal\FastDrop\fastdrop-mobile"

Write-Host "=== Building APK ==="
flutter build apk --release 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "BUILD FAILED"
    exit 1
}
Write-Host "BUILD OK"

Write-Host "=== Uninstalling old app ==="
& $adb uninstall com.fastdrop.fastdrop_mobile 2>&1

Write-Host "=== Installing fresh APK ==="
& $adb install "build\app\outputs\flutter-apk\app-release.apk" 2>&1
Write-Host "INSTALL DONE"
