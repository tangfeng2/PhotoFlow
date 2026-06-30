package com.example.photo_flow

import android.Manifest
import android.app.RecoverableSecurityException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Size
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "photo_flow/android_photos"
    private val permissionRequestCode = 4207
    private val deleteRequestCode = 4208
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingDeleteResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "scanPhotos" -> scanPhotos(result)
                "readImageBytes" -> {
                    val uri = call.argument<String>("uri")
                    if (uri.isNullOrBlank()) {
                        result.error("missing_uri", "Missing image URI.", null)
                    } else {
                        readImageBytes(uri, result)
                    }
                }
                "readThumbnailBytes" -> {
                    val uri = call.argument<String>("uri")
                    val size = call.argument<Int>("size") ?: 320
                    if (uri.isNullOrBlank()) {
                        result.error("missing_uri", "Missing image URI.", null)
                    } else {
                        readThumbnailBytes(uri, size, result)
                    }
                }
                "getThumbnailPath" -> {
                    val uri = call.argument<String>("uri")
                    val size = call.argument<Int>("size") ?: 224
                    if (uri.isNullOrBlank()) {
                        result.error("missing_uri", "Missing image URI.", null)
                    } else {
                        getThumbnailPath(uri, size, result)
                    }
                }
                "sharePhoto" -> {
                    val uri = call.argument<String>("uri")
                    val name = call.argument<String>("name") ?: "Photo"
                    if (uri.isNullOrBlank()) {
                        result.error("missing_uri", "Missing image URI.", null)
                    } else {
                        sharePhoto(uri, name, result)
                    }
                }
                "copyPhoto" -> {
                    val uri = call.argument<String>("uri")
                    val name = call.argument<String>("name") ?: "Photo"
                    if (uri.isNullOrBlank()) {
                        result.error("missing_uri", "Missing image URI.", null)
                    } else {
                        copyPhoto(uri, name, result)
                    }
                }
                "renamePhoto" -> {
                    val uri = call.argument<String>("uri")
                    val name = call.argument<String>("name")
                    if (uri.isNullOrBlank() || name.isNullOrBlank()) {
                        result.error("missing_args", "Missing image URI or name.", null)
                    } else {
                        renamePhoto(uri, name, result)
                    }
                }
                "deletePhoto" -> {
                    val uri = call.argument<String>("uri")
                    if (uri.isNullOrBlank()) {
                        result.error("missing_uri", "Missing image URI.", null)
                    } else {
                        deletePhoto(uri, result)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun scanPhotos(result: MethodChannel.Result) {
        if (!hasImagePermission()) {
            if (pendingPermissionResult != null) {
                result.error("permission_pending", "Photo permission request is already pending.", null)
                return
            }
            pendingPermissionResult = result
            requestPermissions(arrayOf(imagePermission()), permissionRequestCode)
            return
        }

        result.success(queryImages())
    }

    private fun hasImagePermission(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            checkSelfPermission(imagePermission()) == PackageManager.PERMISSION_GRANTED
    }

    private fun imagePermission(): String {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_IMAGES
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }
    }

    private fun queryImages(): List<Map<String, Any?>> {
        val images = mutableListOf<Map<String, Any?>>()
        val collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        val projection = mutableListOf(
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.DATE_MODIFIED,
            MediaStore.Images.Media.SIZE,
            MediaStore.Images.Media.WIDTH,
            MediaStore.Images.Media.HEIGHT,
            MediaStore.Images.Media.BUCKET_DISPLAY_NAME,
            MediaStore.Images.Media.MIME_TYPE,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            projection.add(MediaStore.Images.Media.RELATIVE_PATH)
        }

        contentResolver.query(
            collection,
            projection.toTypedArray(),
            null,
            null,
            "${MediaStore.Images.Media.DATE_MODIFIED} DESC"
        )?.use { cursor ->
            val idColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
            val nameColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME)
            val modifiedColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_MODIFIED)
            val sizeColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.SIZE)
            val widthColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.WIDTH)
            val heightColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.HEIGHT)
            val bucketColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.BUCKET_DISPLAY_NAME)
            val mimeColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.MIME_TYPE)
            val relativeColumn = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                cursor.getColumnIndex(MediaStore.Images.Media.RELATIVE_PATH)
            } else {
                -1
            }

            while (cursor.moveToNext()) {
                val id = cursor.getLong(idColumn)
                val uri = ContentUris.withAppendedId(collection, id).toString()
                val name = cursor.getString(nameColumn).orEmpty()
                val extension = name.substringAfterLast('.', "").lowercase()
                val relativePath = if (relativeColumn >= 0) {
                    cursor.getString(relativeColumn).orEmpty().trimEnd('/')
                } else {
                    ""
                }
                val album = relativePath.substringAfterLast('/', "").ifBlank {
                    cursor.getString(bucketColumn).orEmpty()
                }
                val mime = cursor.getString(mimeColumn).orEmpty()

                images.add(
                    mapOf(
                        "path" to uri,
                        "name" to name,
                        "extension" to extension.ifBlank { mime.substringAfterLast('/', "") },
                        "modified_ms" to cursor.getLong(modifiedColumn) * 1000L,
                        "size_bytes" to cursor.getLong(sizeColumn),
                        "width" to cursor.getInt(widthColumn),
                        "height" to cursor.getInt(heightColumn),
                        "album" to album,
                    )
                )
            }
        }

        return images
    }

    private fun readImageBytes(uriString: String, result: MethodChannel.Result) {
        try {
            val uri = Uri.parse(uriString)
            val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
            if (bytes == null) {
                result.error("read_failed", "Could not open image URI.", null)
            } else {
                result.success(bytes)
            }
        } catch (error: Exception) {
            result.error("read_failed", error.message, null)
        }
    }

    private fun readThumbnailBytes(uriString: String, size: Int, result: MethodChannel.Result) {
        try {
            val bitmap = loadThumbnailBitmap(Uri.parse(uriString), size)

            if (bitmap == null) {
                result.error("thumbnail_failed", "Could not decode image thumbnail.", null)
                return
            }

            ByteArrayOutputStream().use { stream ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 78, stream)
                result.success(stream.toByteArray())
            }
        } catch (error: Exception) {
            result.error("thumbnail_failed", error.message, null)
        }
    }

    private fun getThumbnailPath(uriString: String, size: Int, result: MethodChannel.Result) {
        try {
            val cacheFile = thumbnailCacheFile(uriString, size)
            if (cacheFile.exists() && cacheFile.length() > 0L) {
                result.success(cacheFile.absolutePath)
                return
            }

            val bitmap = loadThumbnailBitmap(Uri.parse(uriString), size)
            if (bitmap == null) {
                result.error("thumbnail_failed", "Could not decode image thumbnail.", null)
                return
            }

            cacheFile.parentFile?.mkdirs()
            FileOutputStream(cacheFile).use { stream ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 76, stream)
            }
            result.success(cacheFile.absolutePath)
        } catch (error: Exception) {
            result.error("thumbnail_failed", error.message, null)
        }
    }

    private fun loadThumbnailBitmap(uri: Uri, size: Int): Bitmap? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            contentResolver.loadThumbnail(uri, Size(size, size), null)
        } else {
            decodeSampledBitmap(uri, size)
        }
    }

    private fun thumbnailCacheFile(uriString: String, size: Int): File {
        val name = "${size}_${Integer.toHexString(uriString.hashCode())}.jpg"
        return File(File(cacheDir, "photo_thumbs"), name)
    }

    private fun sharePhoto(uriString: String, name: String, result: MethodChannel.Result) {
        try {
            val uri = Uri.parse(uriString)
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "image/*"
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_TITLE, name)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(intent, name))
            result.success(null)
        } catch (error: Exception) {
            result.error("share_failed", error.message, null)
        }
    }

    private fun copyPhoto(uriString: String, name: String, result: MethodChannel.Result) {
        try {
            val uri = Uri.parse(uriString)
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clipboard.setPrimaryClip(ClipData.newUri(contentResolver, name, uri))
            result.success(null)
        } catch (error: Exception) {
            result.error("copy_failed", error.message, null)
        }
    }

    private fun renamePhoto(uriString: String, name: String, result: MethodChannel.Result) {
        try {
            val uri = Uri.parse(uriString)
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            }
            contentResolver.update(uri, values, null, null)
            result.success(mapOf("path" to uriString, "name" to name))
        } catch (error: Exception) {
            result.error("rename_failed", error.message, null)
        }
    }

    private fun deletePhoto(uriString: String, result: MethodChannel.Result) {
        val uri = Uri.parse(uriString)
        try {
            val deleted = contentResolver.delete(uri, null, null)
            if (deleted > 0) {
                result.success(null)
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                requestDelete(uri, result)
            } else {
                result.error("delete_failed", "Media item was not deleted.", null)
            }
        } catch (error: RecoverableSecurityException) {
            pendingDeleteResult = result
            try {
                startIntentSenderForResult(
                    error.userAction.actionIntent.intentSender,
                    deleteRequestCode,
                    null,
                    0,
                    0,
                    0
                )
            } catch (sendError: IntentSender.SendIntentException) {
                pendingDeleteResult = null
                result.error("delete_failed", sendError.message, null)
            }
        } catch (error: SecurityException) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                requestDelete(uri, result)
            } else {
                result.error("delete_failed", error.message, null)
            }
        } catch (error: Exception) {
            result.error("delete_failed", error.message, null)
        }
    }

    private fun requestDelete(uri: Uri, result: MethodChannel.Result) {
        if (pendingDeleteResult != null) {
            result.error("delete_pending", "Delete request is already pending.", null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            result.error("delete_failed", "Delete confirmation is not available.", null)
            return
        }
        pendingDeleteResult = result
        try {
            val intent = MediaStore.createDeleteRequest(contentResolver, listOf(uri))
            startIntentSenderForResult(intent.intentSender, deleteRequestCode, null, 0, 0, 0)
        } catch (error: Exception) {
            pendingDeleteResult = null
            result.error("delete_failed", error.message, null)
        }
    }

    private fun decodeSampledBitmap(uri: Uri, requestedSize: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply {
            inJustDecodeBounds = true
        }
        contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, bounds)
        }

        val decodeOptions = BitmapFactory.Options().apply {
            inSampleSize = calculateInSampleSize(bounds, requestedSize, requestedSize)
        }
        return contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, decodeOptions)
        }
    }

    private fun calculateInSampleSize(
        options: BitmapFactory.Options,
        requestedWidth: Int,
        requestedHeight: Int
    ): Int {
        val height = options.outHeight
        val width = options.outWidth
        var inSampleSize = 1

        if (height > requestedHeight || width > requestedWidth) {
            var halfHeight = height / 2
            var halfWidth = width / 2
            while (
                halfHeight / inSampleSize >= requestedHeight &&
                halfWidth / inSampleSize >= requestedWidth
            ) {
                inSampleSize *= 2
            }
        }

        return inSampleSize
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != permissionRequestCode) return

        val result = pendingPermissionResult ?: return
        pendingPermissionResult = null

        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            result.success(queryImages())
        } else {
            result.error("permission_denied", "Photo permission was denied.", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != deleteRequestCode) return

        val result = pendingDeleteResult ?: return
        pendingDeleteResult = null

        if (resultCode == RESULT_OK) {
            result.success(null)
        } else {
            result.error("delete_cancelled", "Delete was cancelled.", null)
        }
    }
}
