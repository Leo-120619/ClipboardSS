package com.leolml.clipboard_companion

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import androidx.core.content.FileProvider
import java.io.File
import android.util.Base64

class MainActivity : FlutterActivity() {
    private val permissionsChannelName = "clipboard_companion/permissions"
    private val imagesChannelName = "clipboard_companion/images"
    private val nearbyWifiRequestCode = 4107
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, permissionsChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestNearbyWifiPermission" -> requestNearbyWifiPermission(result)
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, imagesChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "copyImageToClipboard" -> copyImageToClipboard(call.argument("imageBase64"), call.argument("extension"), result)
                else -> result.notImplemented()
            }
        }
    }

    private fun copyImageToClipboard(imageBase64: String?, extension: String?, result: MethodChannel.Result) {
        if (imageBase64.isNullOrBlank()) {
            result.error("missing_image", "No image bytes were supplied.", null)
            return
        }

        try {
            val safeExtension = when (extension?.lowercase()) {
                "jpg", "jpeg" -> "jpg"
                "webp" -> "webp"
                else -> "png"
            }
            val imageBytes = Base64.decode(imageBase64, Base64.DEFAULT)
            val directory = File(cacheDir, "shared_images")
            directory.mkdirs()
            val imageFile = File(directory, "clipboard-image.$safeExtension")
            imageFile.writeBytes(imageBytes)

            val uri: Uri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                imageFile
            )
            val mimeType = when (safeExtension) {
                "jpg" -> "image/jpeg"
                "webp" -> "image/webp"
                else -> "image/png"
            }
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = ClipData.newUri(contentResolver, "ClipboardSS image", uri)
            clip.description.extras = android.os.PersistableBundle().apply {
                putString("android.content.extra.MIME_TYPES", mimeType)
            }
            grantUriPermission(packageName, uri, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
            clipboard.setPrimaryClip(clip)
            result.success(null)
        } catch (e: Exception) {
            result.error("copy_failed", e.localizedMessage, null)
        }
    }

    private fun requestNearbyWifiPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }

        val permission = Manifest.permission.NEARBY_WIFI_DEVICES
        if (checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }

        if (pendingPermissionResult != null) {
            result.error("permission_in_progress", "A nearby device permission request is already running.", null)
            return
        }

        pendingPermissionResult = result
        requestPermissions(arrayOf(permission), nearbyWifiRequestCode)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == nearbyWifiRequestCode) {
            val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        }
    }
}
