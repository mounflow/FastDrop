package com.fastdrop.fastdrop_mobile

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.Environment
import android.os.PowerManager
import android.os.StatFs
import android.provider.MediaStore
import android.provider.Settings
import android.webkit.MimeTypeMap
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.Inet4Address

class MainActivity : FlutterActivity() {
    private val networkInfoChannelName = "fastdrop/network_info"
    private val platformChannelName = "fastdrop/platform"
    private val wifiNamePermissionRequest = 9527
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, networkInfoChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCurrentNetwork" -> result.success(currentNetworkInfo())
                    "requestWifiNamePermission" -> requestWifiNamePermission(result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, platformChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startKeepAlive" -> {
                        FastDropKeepAliveService.start(applicationContext)
                        result.success(null)
                    }
                    "stopKeepAlive" -> {
                        FastDropKeepAliveService.stop(applicationContext)
                        result.success(null)
                    }
                    "saveToPublicStorage" -> {
                        // 产品决策 B：接收文件默认落盘到公共媒体目录（scoped
                        // storage 安全）。图片/视频进相册集合，其他进 Downloads；
                        // MediaStore 对重名自动追加 "(1)"（对齐 rename 策略）。
                        val fileName = call.argument<String>("fileName")!!
                        val mimeType = call.argument<String>("mimeType")
                            ?: "application/octet-stream"
                        val sourcePath = call.argument<String>("sourcePath")!!
                        try {
                            result.success(
                                saveToPublicStorage(fileName, mimeType, sourcePath)
                            )
                        } catch (e: Exception) {
                            result.error("SAVE_FAILED", e.message, null)
                        }
                    }
                    "openFile" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("INVALID_PATH", "Path is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            openWithViewer(path)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("OPEN_FAILED", e.message, null)
                        }
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        // 问题 9（小改档）：各厂商后台存活的第一道门槛是电池
                        // 优化白名单，这里只做检测与跳转，不做任何绕过。
                        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                        result.success(pm.isIgnoringBatteryOptimizations(packageName))
                    }
                    "openBatteryOptimizationSettings" -> {
                        try {
                            val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("OPEN_FAILED", e.message, null)
                        }
                    }
                    "getAvailableSpace" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("INVALID_PATH", "Storage path is required", null)
                        } else {
                            try {
                                result.success(StatFs(path).availableBytes)
                            } catch (error: IllegalArgumentException) {
                                result.error("INVALID_PATH", error.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// 产品决策 B：经 MediaStore 把 .part 内容写入公共媒体目录。
    /// 图片 → Pictures/FastDrop（相册可见），视频 → Movies/FastDrop，
    /// 其他 → Downloads/FastDrop。返回实际落盘路径（DATA 列）。
    private fun saveToPublicStorage(fileName: String, mimeType: String, sourcePath: String): String {
        val source = File(sourcePath)
        if (!source.exists()) {
            throw IllegalArgumentException("Source part file does not exist: $sourcePath")
        }
        val isImage = mimeType.startsWith("image/")
        val isVideo = mimeType.startsWith("video/")
        val collection: Uri = when {
            isImage -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            isVideo -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            else -> MediaStore.Downloads.EXTERNAL_CONTENT_URI
        }
        val relativePath = when {
            isImage -> Environment.DIRECTORY_PICTURES + "/FastDrop"
            isVideo -> Environment.DIRECTORY_MOVIES + "/FastDrop"
            else -> Environment.DIRECTORY_DOWNLOADS + "/FastDrop"
        }
        val resolver = contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, fileName.substringAfterLast('/'))
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
        }
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("MediaStore insert failed")
        try {
            resolver.openOutputStream(uri)?.use { out ->
                source.inputStream().use { input -> input.copyTo(out) }
            } ?: throw IllegalStateException("MediaStore output stream is null")
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            }
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        // 查询 DATA 列得到真实落盘路径，供历史记录/打开文件使用。
        val dataColumn = MediaStore.MediaColumns.DATA
        resolver.query(
            uri, arrayOf(dataColumn), null, null, null
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val data = cursor.getString(0)
                if (!data.isNullOrEmpty()) return data
            }
        }
        return relativePath + "/" + fileName.substringAfterLast('/')
    }

    /// L15: 用系统查看器打开已接收的文件。路径必须经 FileProvider 暴露，
    /// 否则 Android 7+ 会抛 FileUriExposedException。若路径不在已配置的
    /// FileProvider 根内（如第二块存储上的自定义目录），退化为拷贝到
    /// cache 后分享副本，保证"打开"始终可用。
    private fun openWithViewer(path: String) {
        val file = File(path)
        if (!file.exists()) {
            throw IllegalArgumentException("File does not exist: $path")
        }
        val uri = try {
            FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        } catch (e: IllegalArgumentException) {
            val cacheCopy = File(cacheDir, "open/${file.name}")
            cacheCopy.parentFile?.mkdirs()
            file.copyTo(cacheCopy, overwrite = true)
            FileProvider.getUriForFile(this, "$packageName.fileprovider", cacheCopy)
        }
        val ext = file.extension.lowercase()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            ?: "application/octet-stream"
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, mime)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }

    private fun requestWifiNamePermission(result: MethodChannel.Result) {
        if (hasWifiNamePermission()) {
            result.success(currentNetworkInfo())
            return
        }
        if (pendingPermissionResult != null) {
            result.error("PERMISSION_IN_PROGRESS", "Wi-Fi name permission is already pending", null)
            return
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION),
            wifiNamePermissionRequest,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != wifiNamePermissionRequest) return
        pendingPermissionResult?.success(currentNetworkInfo())
        pendingPermissionResult = null
    }

    private fun currentNetworkInfo(): Map<String, Any?> {
        val connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = connectivity.activeNetwork
        val capabilities = network?.let(connectivity::getNetworkCapabilities)
        val type = when {
            capabilities == null -> "offline"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
            else -> "lan"
        }
        val addresses = network
            ?.let(connectivity::getLinkProperties)
            ?.linkAddresses
            ?.map { it.address }
            ?.filterIsInstance<Inet4Address>()
            ?.filter { !it.isLoopbackAddress && it.isSiteLocalAddress }
            ?.mapNotNull { it.hostAddress }
            ?.distinct()
            ?: emptyList()
        val wifiName = if (type == "wifi" && hasWifiNamePermission()) currentWifiName(capabilities) else null
        return mapOf(
            "type" to type,
            "name" to wifiName,
            "localAddresses" to addresses,
            "permissionRequired" to (type == "wifi" && wifiName == null && !hasWifiNamePermission()),
        )
    }

    @Suppress("DEPRECATION")
    private fun currentWifiName(capabilities: NetworkCapabilities?): String? {
        val info = capabilities?.transportInfo as? WifiInfo
            ?: (applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager).connectionInfo
        val ssid = info.ssid?.trim('"')
        return ssid?.takeUnless { it.isBlank() || it == WifiManager.UNKNOWN_SSID }
    }

    private fun hasWifiNamePermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
    }
}
