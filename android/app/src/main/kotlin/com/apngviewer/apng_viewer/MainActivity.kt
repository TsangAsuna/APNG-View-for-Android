package com.apngviewer.apng_viewer

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val channelName = "com.apngviewer.apng_viewer/file"
    private val nativeDecodeChannel = "com.apngviewer.apng_viewer/native_decode"
    private val pickSingleCode = 1001
    private val pickMultiCode = 1002
    private val pickTreeCode = 1003
    private val saveFileCode = 1004

    private var pendingResult: MethodChannel.Result? = null
    private var pendingPath: String? = null
    private var pendingSaveData: ByteArray? = null
    private var pendingSaveMime: String? = null
    private var _treeUri: Uri? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                pendingResult = result
                when (call.method) {
                    "pickApngFile" -> openFilePicker(single = true)
                    "pickImages" -> openFilePicker(single = false)
                    "pickDirectory" -> openDirectoryPicker()
                    "saveFileDialog" -> {
                        val name = call.argument<String>("fileName") ?: "export.png"
                        val mime = call.argument<String>("mime") ?: "image/png"
                        val data = call.argument<ByteArray>("data") ?: byteArrayOf()
                        pendingSaveData = data
                        pendingSaveMime = mime
                        openSaveDialog(name, mime)
                    }
                    "writeToDirectory" -> {
                        val fileName = call.argument<String>("fileName") ?: "file.png"
                        val mime = call.argument<String>("mime") ?: "image/png"
                        val data = call.argument<ByteArray>("data") ?: byteArrayOf()
                        try {
                            val uri = createFileInTree(mime, fileName)
                            if (uri != null) {
                                contentResolver.openOutputStream(uri)?.use { it.write(data) }
                                result.success(true)
                            } else {
                                result.success(false)
                            }
                        } catch (e: Exception) {
                            result.error("WRITE_FAILED", e.message, null)
                        }
                    }
                    "getPendingFile" -> {
                        result.success(pendingPath)
                        pendingPath = null
                    }
                    "clearPendingCache" -> {
                        // 只清应用自身复制产生的缓存目录，绝不触碰源文件
                        try {
                            val cacheDir = File(cacheDir, "pending")
                            cacheDir.deleteRecursively()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("CLEAR_CACHE_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        // 原生 APNG 解码通道（独立通道，Dart 端 decodeAsync 优先调用）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, nativeDecodeChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "decodeApng") {
                    handleNativeDecode(call, result)
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun handleNativeDecode(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path") ?: run {
            result.success(null); return
        }
        Thread {
            try {
                val tmpDir = File(cacheDir, "native_frames").apply { mkdirs() }
                val framePaths = ApngNativeDecoder.decode(path, tmpDir)
                if (framePaths == null) {
                    result.success(null)
                    return@Thread
                }
                // 解析元数据（时长）
                val durations = ArrayList<Int>()
                val meta = ApngNativeDecoder.peekMeta(path)
                if (meta != null) {
                    for (f in meta.frames) {
                        var d = 0
                        if (f.delayNum > 0 && f.delayDen > 0) {
                            d = (f.delayNum * 1000 / f.delayDen).toInt()
                        }
                        durations.add(if (d > 0) d else 100)
                    }
                }
                val resultMap = HashMap<String, Any>()
                resultMap["paths"] = framePaths
                resultMap["durations"] = durations
                resultMap["width"] = meta?.width ?: 0
                resultMap["height"] = meta?.height ?: 0
                resultMap["loopCount"] = meta?.loopCount ?: 0
                result.success(resultMap)
            } catch (e: Exception) {
                result.success(null)
            }
        }.start()
    }

    private fun openFilePicker(single: Boolean) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "image/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf("image/png", "image/jpeg", "image/webp", "image/gif", "image/bmp", "image/apng", "image/x-apng")
            )
            if (!single) putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        try {
            startActivityForResult(intent, if (single) pickSingleCode else pickMultiCode)
        } catch (e: Exception) {
            pendingResult?.error("PICKER_UNAVAILABLE", e.message, null)
            pendingResult = null
        }
    }

    private fun openDirectoryPicker() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        try {
            startActivityForResult(intent, pickTreeCode)
        } catch (e: Exception) {
            pendingResult?.error("PICKER_UNAVAILABLE", e.message, null)
            pendingResult = null
        }
    }

    private fun openSaveDialog(fileName: String, mime: String) {
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mime
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        try {
            startActivityForResult(intent, saveFileCode)
        } catch (e: Exception) {
            pendingResult?.error("SAVE_UNAVAILABLE", e.message, null)
            pendingResult = null
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            pickSingleCode -> {
                if (resultCode == Activity.RESULT_OK && data?.data != null) {
                    pendingResult?.success(resolveOrCache(data.data!!))
                } else {
                    pendingResult?.success(null)
                }
                pendingResult = null
            }
            pickMultiCode -> {
                if (resultCode == Activity.RESULT_OK) {
                    val paths = mutableListOf<String>()
                    data?.clipData?.let { clip ->
                        for (i in 0 until clip.itemCount) {
                            paths.add(resolveOrCache(clip.getItemAt(i).uri))
                        }
                    }
                    if (paths.isEmpty()) data?.data?.let { paths.add(resolveOrCache(it)) }
                    pendingResult?.success(paths)
                } else {
                    pendingResult?.success(null)
                }
                pendingResult = null
            }
            pickTreeCode -> {
                if (resultCode == Activity.RESULT_OK && data?.data != null) {
                    val uri = data.data!!
                    _treeUri = uri
                    try {
                        contentResolver.takePersistableUriPermission(
                            uri,
                            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                        )
                    } catch (e: Exception) { /* ignore */ }
                    pendingResult?.success(uri.toString())
                } else {
                    pendingResult?.success(null)
                }
                pendingResult = null
            }
            saveFileCode -> {
                if (resultCode == Activity.RESULT_OK && data?.data != null) {
                    val uri = data.data!!
                    val bytes = pendingSaveData
                    if (bytes != null) {
                        try {
                            contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                            pendingResult?.success(true)
                        } catch (e: Exception) {
                            pendingResult?.error("SAVE_FAILED", e.message, null)
                        }
                    } else {
                        pendingResult?.success(false)
                    }
                } else {
                    pendingResult?.success(false)
                }
                pendingSaveData = null
                pendingSaveMime = null
                pendingResult = null
            }
        }
    }

    private fun createFileInTree(mime: String, fileName: String): Uri? {
        val treeUri = _treeUri ?: return null
        val docId = DocumentsContract.getTreeDocumentId(treeUri)
        return DocumentsContract.createDocument(contentResolver, treeUri, mime, fileName)
    }

    /** 优先返回源文件真实路径（不产生本地缓存），无法解析时才回退复制到缓存 */
    private fun resolveOrCache(uri: Uri): String {
        resolveRealPath(uri)?.let { return it }
        return copyToCache(uri)
    }

    private fun resolveRealPath(uri: Uri): String? {
        if (uri.scheme == "file") return uri.path
        if (uri.scheme == "content") {
            try {
                val isMedia = uri.authority?.contains("media") == true ||
                    uri.toString().contains("media/external")
                if (isMedia) {
                    contentResolver.query(
                        uri,
                        arrayOf(MediaStore.Images.Media.DATA),
                        null, null, null
                    )?.use { c ->
                        if (c.moveToFirst()) {
                            val idx = c.getColumnIndex(MediaStore.Images.Media.DATA)
                            if (idx >= 0) {
                                val p = c.getString(idx)
                                if (!p.isNullOrEmpty() && File(p).exists()) return p
                            }
                        }
                    }
                }
            } catch (e: Exception) { /* ignore */ }
        }
        return null
    }

    private fun copyToCache(uri: Uri): String {
        val cacheDir = File(cacheDir, "pending")
        cacheDir.mkdirs()
        var fileName = "pending_${System.currentTimeMillis()}.png"
        try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) {
                        val name = cursor.getString(idx)
                        if (!name.isNullOrEmpty()) fileName = name
                    }
                }
            }
        } catch (e: Exception) { /* ignore */ }
        val outFile = File(cacheDir, fileName)
        return try {
            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(outFile).use { output -> input.copyTo(output) }
            }
            outFile.absolutePath
        } catch (e: Exception) {
            uri.path ?: ""
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action ?: return
        if (action == Intent.ACTION_VIEW || action == Intent.ACTION_SEND) {
            val uri: Uri? = if (action == Intent.ACTION_SEND) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM)
            } else {
                intent.data
            }
            uri ?: return
            pendingPath = resolveOrCache(uri)
        }
    }
}
