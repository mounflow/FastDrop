package com.fastdrop.fastdrop_mobile

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address

class MainActivity : FlutterActivity() {
    private val channelName = "fastdrop/network_info"
    private val wifiNamePermissionRequest = 9527
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCurrentNetwork" -> result.success(currentNetworkInfo())
                    "requestWifiNamePermission" -> requestWifiNamePermission(result)
                    else -> result.notImplemented()
                }
            }
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
