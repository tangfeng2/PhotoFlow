package com.example.photos_app

import android.Manifest
import android.content.ContentUris
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "photos_app/android_photos"
    private val permissionRequestCode = 4207
    private var pendingPermissionResult: MethodChannel.Result? = null

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
}
