package com.leolml.clipboard_companion

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.app.DownloadManager
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Uri
import android.provider.OpenableColumns
import android.provider.MediaStore
import android.content.ContentValues
import android.os.Environment
import android.os.Build
import android.os.StatFs
import android.os.ParcelFileDescriptor
import android.system.Os
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import androidx.core.content.FileProvider
import java.io.File
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.Inet4Address
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
    private val storageChannelName = "clipboard_companion/storage"
    private val networkChannelName = "clipboard_companion/network"
    private val nearbyWifiRequestCode = 4107
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var shareChannel: MethodChannel? = null
    @Volatile private var pendingShare: Map<String, Any>? = null
    /** Total bytes one incoming share batch may stage into the cache before a device is picked. */
    private val maxStagedShareBytes = 4L * 1024L * 1024L * 1024L

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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, storageChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                // Free bytes on the volume holding `path` (incoming file-transfer quota).
                "freeSpace" -> try {
                    result.success(StatFs(call.argument<String>("path") ?: filesDir.path).availableBytes)
                } catch (e: Exception) {
                    result.error("freeSpace", e.message, null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, networkChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                // IPv4 addresses with prefix lengths, flagging the default network (subnet sweep).
                "ipv4Interfaces" -> try {
                    result.success(ipv4Interfaces())
                } catch (e: Exception) {
                    result.error("ipv4Interfaces", e.message, null)
                }
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

    private fun ipv4Interfaces(): List<Map<String, Any>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return emptyList()
        val connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val active = connectivity.activeNetwork
        val interfaces = mutableListOf<Map<String, Any>>()
        @Suppress("DEPRECATION")
        for (network in connectivity.allNetworks) {
            val link = connectivity.getLinkProperties(network) ?: continue
            val name = link.interfaceName ?: continue
            val isDefaultRoute = network == active && link.routes.any { it.isDefaultRoute }
            for (linkAddress in link.linkAddresses) {
                val address = linkAddress.address as? Inet4Address ?: continue
                val host = address.hostAddress ?: continue
                interfaces.add(
                    mapOf(
                        "name" to name,
                        "address" to host,
                        "prefixLength" to linkAddress.prefixLength,
                        "isDefaultRoute" to isDefaultRoute,
                    )
                )
            }
        }
        return interfaces
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
                val saved = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    publishToMediaStoreDownloads(source, fileName, mimeType)
                } else {
                    publishToLegacyDownloads(source, fileName)
                }
                runOnUiThread { result.success(saved) }
            } catch (e: Exception) {
                runOnUiThread {
                    result.error("save_failed", "Could not save the received file to Downloads.", e.message)
                }
            }
        }.start()
    }

    /** MediaStore.Downloads only exists from API 29. */
    @androidx.annotation.RequiresApi(Build.VERSION_CODES.Q)
    private fun publishToMediaStoreDownloads(source: File, fileName: String, mimeType: String?): String {
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, sanitizeFileName(fileName))
            put(MediaStore.Downloads.MIME_TYPE, mimeType ?: "application/octet-stream")
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: error("Could not create the Downloads entry")
        try {
            contentResolver.openOutputStream(uri)?.use { output ->
                source.inputStream().use { input -> input.copyTo(output) }
            } ?: error("Could not write the Downloads entry")
            contentResolver.update(uri, ContentValues().apply {
                put(MediaStore.Downloads.IS_PENDING, 0)
            }, null, null)
            return uri.toString()
        } catch (e: Exception) {
            contentResolver.delete(uri, null, null)
            throw e
        }
    }

    /**
     * Below API 29, use the app's Downloads directory on external storage; writing the shared
     * Downloads folder there would need WRITE_EXTERNAL_STORAGE, which the app does not request.
     */
    private fun publishToLegacyDownloads(source: File, fileName: String): String {
        val directory = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            ?: error("External storage is unavailable")
        directory.mkdirs()
        val destination = uniqueFile(directory, sanitizeFileName(fileName))
        try {
            source.inputStream().use { input -> destination.outputStream().use(input::copyTo) }
        } catch (e: Exception) {
            destination.delete()
            throw e
        }
        return Uri.fromFile(destination).toString()
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
            var stagedBytes = 0L
            val attachments = uris.mapIndexedNotNull { index, uri ->
                var destination: File? = null
                try {
                    val metadata = queryMetadata(uri)
                    val remaining = maxStagedShareBytes - stagedBytes
                    if (metadata.second != null && metadata.second!! > remaining) error("Share too large")
                    val safeName = sanitizeFileName(metadata.first.ifBlank { "shared-$index" })
                    val target = uniqueFile(directory, safeName).also { destination = it }
                    val copied = openShareStream(uri).use { input ->
                        target.outputStream().use { output -> copyCapped(input, output, remaining) }
                    }
                    stagedBytes += copied
                    mapOf(
                        "path" to target.absolutePath,
                        "name" to target.name,
                        "mimeType" to (contentResolver.getType(uri) ?: "application/octet-stream"),
                        "size" to target.length()
                    )
                } catch (_: Exception) {
                    destination?.delete()
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

    /**
     * Opens a shared URI for reading, refusing anything that could exfiltrate this app's own
     * files: `file://` URIs, our own provider, and any descriptor that resolves inside our
     * data directories. The stream is read from the same descriptor that was checked.
     */
    private fun openShareStream(uri: Uri): InputStream {
        if (uri.scheme != ContentResolver.SCHEME_CONTENT) error("Only content:// shares are accepted")
        if (uri.authority == "$packageName.fileprovider") error("Refusing the app's own files")
        val descriptor = try {
            contentResolver.openFileDescriptor(uri, "r")
        } catch (_: FileNotFoundException) {
            null
        }
        if (descriptor == null) {
            // Streaming providers (pipes) have no backing path to check.
            return contentResolver.openInputStream(uri) ?: error("Unreadable shared file")
        }
        try {
            // Fail closed: a descriptor we cannot resolve is not staged.
            val resolved = File(Os.readlink("/proc/self/fd/${descriptor.fd}")).canonicalPath
            if (isInsideAppStorage(resolved)) error("Refusing the app's own files")
        } catch (e: Exception) {
            descriptor.close()
            throw e
        }
        return ParcelFileDescriptor.AutoCloseInputStream(descriptor)
    }

    private fun isInsideAppStorage(path: String): Boolean {
        val roots = listOfNotNull(
            applicationInfo.dataDir,
            filesDir.parent,
            "/data/data/$packageName",
            "/data/user/0/$packageName",
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) dataDir.path else null,
            getExternalFilesDir(null)?.parent
        ).mapNotNull { runCatching { File(it).canonicalPath }.getOrNull() }.toSet()
        return roots.any { root -> path == root || path.startsWith("$root/") }
    }

    /** Copies at most [limit] bytes; throws if the source holds more. */
    private fun copyCapped(input: InputStream, output: OutputStream, limit: Long): Long {
        val buffer = ByteArray(64 * 1024)
        var total = 0L
        while (true) {
            val read = input.read(buffer)
            if (read < 0) return total
            total += read
            if (total > limit) error("Share too large")
            output.write(buffer, 0, read)
        }
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
