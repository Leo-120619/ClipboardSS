package com.leolml.clipboard_companion

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.app.DownloadManager
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.OpenableColumns
import android.provider.MediaStore
import android.content.ContentValues
import android.os.Environment
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import androidx.core.content.FileProvider
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.UUID
import android.util.Base64
import android.util.Xml
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlSerializer

class MainActivity : FlutterActivity() {
    private val permissionsChannelName = "clipboard_companion/permissions"
    private val imagesChannelName = "clipboard_companion/images"
    private val shareChannelName = "clipboard_companion/incoming_share"
    private val downloadsChannelName = "clipboard_companion/android_downloads"
    private val nearbyWifiRequestCode = 4107
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var shareChannel: MethodChannel? = null
    @Volatile private var pendingShare: Map<String, Any>? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        removeOversizedLegacyClipHistory()
        super.onCreate(savedInstanceState)
        processShareIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        processShareIntent(intent)
    }

    /** Prevent SharedPreferences from parsing the old, image-heavy clip history into memory. */
    private fun removeOversizedLegacyClipHistory() {
        val prefsFile = File(applicationInfo.dataDir, "shared_prefs/FlutterSharedPreferences.xml")
        if (!prefsFile.isFile || prefsFile.length() < 8L * 1024L * 1024L) return

        val tempFile = File(prefsFile.parentFile, "FlutterSharedPreferences.xml.tmp")
        try {
            val parser = Xml.newPullParser()
            val input = FileInputStream(prefsFile)
            parser.setInput(input, "utf-8")
            val serializer = Xml.newSerializer()
            FileOutputStream(tempFile).use { output ->
                serializer.setOutput(output, "utf-8")
                serializer.startDocument("utf-8", true)
                var event = parser.eventType
                var skippedDepth = 0
                while (event != XmlPullParser.END_DOCUMENT) {
                    if (skippedDepth > 0) {
                        if (event == XmlPullParser.START_TAG) skippedDepth++
                        if (event == XmlPullParser.END_TAG) skippedDepth--
                    } else if (event == XmlPullParser.START_TAG &&
                        parser.name == "string" &&
                        parser.getAttributeValue(null, "name") == "flutter.saved_clips") {
                        skippedDepth = 1
                    } else {
                        when (event) {
                            XmlPullParser.START_TAG -> {
                                serializer.startTag(null, parser.name)
                                for (index in 0 until parser.attributeCount) {
                                    serializer.attribute(null, parser.getAttributeName(index), parser.getAttributeValue(index))
                                }
                            }
                            XmlPullParser.END_TAG -> serializer.endTag(null, parser.name)
                            XmlPullParser.TEXT -> serializer.text(parser.text)
                        }
                    }
                    event = parser.next()
                }
                serializer.endDocument()
            }
            input.close()
            if (!tempFile.renameTo(prefsFile)) tempFile.delete()
        } catch (_: Exception) {
            tempFile.delete()
        }
    }

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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, downloadsChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "publishReceivedFile" -> publishReceivedFile(
                    call.argument("sourcePath"),
                    call.argument("fileName"),
                    call.argument("mimeType"),
                    result
                )
                "openDownloads" -> openDownloads(result)
                else -> result.notImplemented()
            }
        }
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, shareChannelName).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialShare" -> result.success(pendingShare)
                    "completeShare" -> {
                        val id = call.argument<String>("id")
                        if (pendingShare?.get("id") == id) pendingShare = null
                        id?.let { File(cacheDir, "incoming_shares/$it").deleteRecursively() }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun publishReceivedFile(
        sourcePath: String?,
        fileName: String?,
        mimeType: String?,
        result: MethodChannel.Result
    ) {
        if (sourcePath.isNullOrBlank() || fileName.isNullOrBlank()) {
            result.error("invalid_file", "A staged file path and name are required.", null)
            return
        }
        val source = File(sourcePath)
        if (!source.isFile) {
            result.error("missing_file", "The staged received file no longer exists.", null)
            return
        }
        Thread {
            try {
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, sanitizeFileName(fileName))
                    put(MediaStore.Downloads.MIME_TYPE, mimeType ?: "application/octet-stream")
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                        put(MediaStore.Downloads.IS_PENDING, 1)
                    }
                }
                val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                    ?: error("Could not create the Downloads entry")
                try {
                    contentResolver.openOutputStream(uri)?.use { output ->
                        source.inputStream().use { input -> input.copyTo(output) }
                    } ?: error("Could not write the Downloads entry")
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        contentResolver.update(uri, ContentValues().apply {
                            put(MediaStore.Downloads.IS_PENDING, 0)
                        }, null, null)
                    }
                    runOnUiThread { result.success(uri.toString()) }
                } catch (e: Exception) {
                    contentResolver.delete(uri, null, null)
                    throw e
                }
            } catch (e: Exception) {
                runOnUiThread {
                    result.error("save_failed", "Could not save the received file to Downloads.", e.message)
                }
            }
        }.start()
    }

    private fun openDownloads(result: MethodChannel.Result) {
        try {
            startActivity(Intent(DownloadManager.ACTION_VIEW_DOWNLOADS))
            result.success(true)
        } catch (_: Exception) {
            result.success(false)
        }
    }

    private fun processShareIntent(sourceIntent: Intent?) {
        val action = sourceIntent?.action ?: return
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return
        sourceIntent.action = null // Lifecycle redelivery must not stage the same payload twice.
        val uris = if (action == Intent.ACTION_SEND_MULTIPLE) {
            sourceIntent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: arrayListOf()
        } else {
            listOfNotNull(sourceIntent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
        }
        if (uris.isEmpty()) return

        Thread {
            val batchId = UUID.randomUUID().toString()
            val directory = File(cacheDir, "incoming_shares/$batchId").apply { mkdirs() }
            var skipped = 0
            val attachments = uris.mapIndexedNotNull { index, uri ->
                try {
                    val metadata = queryMetadata(uri)
                    val safeName = sanitizeFileName(metadata.first.ifBlank { "shared-$index" })
                    val destination = uniqueFile(directory, safeName)
                    contentResolver.openInputStream(uri)?.use { input ->
                        destination.outputStream().use(input::copyTo)
                    } ?: error("Unreadable shared file")
                    mapOf(
                        "path" to destination.absolutePath,
                        "name" to destination.name,
                        "mimeType" to (contentResolver.getType(uri) ?: "application/octet-stream"),
                        "size" to destination.length()
                    )
                } catch (_: Exception) {
                    skipped++
                    null
                }
            }
            if (attachments.isEmpty()) {
                directory.deleteRecursively()
                return@Thread
            }
            val batch = mapOf<String, Any>(
                "id" to batchId,
                "attachments" to attachments,
                "skippedCount" to skipped
            )
            pendingShare = batch
            runOnUiThread { shareChannel?.invokeMethod("incomingShare", batch) }
        }.start()
    }

    private fun queryMetadata(uri: Uri): Pair<String, Long?> {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val name = cursor.getString(0) ?: "shared-file"
                val size = if (cursor.isNull(1)) null else cursor.getLong(1)
                return name to size
            }
        }
        return (uri.lastPathSegment ?: "shared-file") to null
    }

    private fun sanitizeFileName(name: String): String =
        name.replace(Regex("[\\\\/:*?\"<>|\\u0000-\\u001F]"), "_").take(180)

    private fun uniqueFile(directory: File, name: String): File {
        var candidate = File(directory, name)
        var suffix = 2
        val dot = name.lastIndexOf('.')
        val stem = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        while (candidate.exists()) candidate = File(directory, "$stem ($suffix)$ext").also { suffix++ }
        return candidate
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
