package com.apngviewer.apng_viewer

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import android.graphics.SurfaceTexture
import android.os.Handler
import android.os.Looper
import android.view.Surface
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.concurrent.Executors

/**
 * 原生 APNG 播放器（对齐 ImageToolbox 架构）。
 *
 * 解码与渲染全在原生侧：系统 ImageDecoder(API 28+) 或自研解码器
 * 把每帧解码为 Bitmap，通过 SurfaceTexture 逐帧绘制到 Flutter Texture。
 * Dart 只拿到 textureId 显示 + 播放控制，零 RGBA 跨层传输
 * （字节序/内存/闪退问题彻底消失）。
 */
class ApngNativePlayer(
    private val engine: FlutterEngine,
    private val textureRegistry: TextureRegistry,
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val decodeExecutor = Executors.newFixedThreadPool(4)

    private var frames: List<Bitmap> = emptyList()
    private var durations: List<Int> = emptyList()
    private var loopCount = 0
    private var currentFrame = 0
    private var playing = false
    private var completedLoops = 0
    private var playedMs = 0L

    private var surface: Surface? = null
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var frameRunnable: Runnable? = null

    private var startedAt = 0L
    private var frameBaseMs = 0L
    private var speed = 1.0

    /** 打开并解码 APNG，返回 textureId + 元数据；失败返回 null */
    fun open(
        path: String,
        result: MethodChannel.Result,
    ) {
        decodeExecutor.execute {
            try {
                val meta = ApngNativeDecoder.peekMeta(path)
                val frameCount = meta?.frames?.size ?: 0
                if (meta == null || frameCount < 2) {
                    mainHandler.post { result.success(null) }
                    return@execute
                }
                // 全尺寸 source-blend 帧检查（与解码器一致）
                for (f in meta.frames) {
                    if (f.xOffset != 0 || f.yOffset != 0 ||
                        f.width != meta.width || f.height != meta.height ||
                        f.blendOp != 0
                    ) {
                        mainHandler.post { result.success(null) }
                        return@execute
                    }
                }
                // 逐帧解码（自研解码器：系统 ImageDecoder 无逐帧 API，
                    // API 28+ 也仅解静态图；自研 + 原生侧字节序转换与 ImageToolbox 的
                    // oupson 库同思路）
                    val bitmaps = decodeWithSelf(path, meta)
                    if (bitmaps == null || bitmaps.size != frameCount) {
                        mainHandler.post { result.success(null) }
                        return@execute
                    }
                frames = bitmaps
                durations = meta.frames.map { f ->
                    val d = if (f.delayNum > 0 && f.delayDen > 0)
                        (f.delayNum * 1000 / f.delayDen) else 0
                    if (d > 0) d else 100
                }
                loopCount = meta.loopCount
                currentFrame = 0
                completedLoops = 0
                playedMs = 0

                // 创建 SurfaceTexture 纹理
                textureEntry?.let { it.release() }
                textureEntry = textureRegistry.createSurfaceTexture()
                val tex = textureEntry!!.surfaceTexture()
                tex.setDefaultBufferSize(meta.width, meta.height)
                surface = Surface(tex)

                // 绘制第一帧
                drawFrame(0)

                val map = HashMap<String, Any>()
                map["textureId"] = textureEntry!!.id()
                map["width"] = meta.width
                map["height"] = meta.height
                map["frameCount"] = frameCount
                map["durations"] = durations
                map["loopCount"] = loopCount
                mainHandler.post { result.success(map) }
            } catch (e: Exception) {
                mainHandler.post { result.success(null) }
            }
        }
    }

    /** 自研解码器逐帧（系统 ImageDecoder 无逐帧 API，API 24+ 全覆盖） */
    private fun decodeWithSelf(
        path: String,
        meta: ApngNativeDecoder.ApngMeta,
    ): List<Bitmap>? = try {
        val bytes = File(path).readBytes()
        val tmpDir = File(
            android.os.Environment.getExternalStorageDirectory()?.absolutePath
                ?: "/data/local/tmp",
            "apng_decoded"
        ).apply { mkdirs() }
        val rgbaPaths = ApngNativeDecoder.decode(path, tmpDir) ?: return null
        val list = ArrayList<Bitmap>(rgbaPaths.size)
        for ((i, p) in rgbaPaths.withIndex()) {
            val rgba = File(p).readBytes()
            val f = meta.frames[i]
            val bmp = Bitmap.createBitmap(f.width, f.height, Bitmap.Config.ARGB_8888)
            val buf = java.nio.ByteBuffer.wrap(rgba).order(java.nio.ByteOrder.nativeOrder())
            bmp.copyPixelsFromBuffer(buf)
            list.add(bmp)
        }
        list
    } catch (e: Exception) {
        null
    }

    /** 把第 i 帧绘制到 Surface */
    private fun drawFrame(i: Int) {
        if (i >= frames.size) return
        val s = surface ?: return
        val bmp = frames[i]
        try {
            val canvas = s.lockHardwareCanvas()
            canvas.drawColor(android.graphics.Color.BLACK)
            canvas.drawBitmap(
                bmp, null,
                Rect(0, 0, canvas.width, canvas.height), null
            )
            s.unlockCanvasAndPost(canvas)
        } catch (_: Exception) {
            try {
                val canvas = s.lockCanvas(null)
                canvas.drawColor(android.graphics.Color.BLACK)
                canvas.drawBitmap(
                    bmp, null,
                    Rect(0, 0, canvas.width, canvas.height), null
                )
                s.unlockCanvasAndPost(canvas)
            } catch (_: Exception) {
            }
        }
        // unlockCanvasAndPost 后 SurfaceTexture 有新帧，Flutter 引擎通过
        // setOnFrameAvailableListener 自动重绘 Texture，无需手动 markDirty
    }

    fun play() {
        if (frames.isEmpty() || playing) return
        playing = true
        startedAt = System.currentTimeMillis()
        frameBaseMs = playedMs
        frameRunnable?.let { mainHandler.removeCallbacks(it) }
        frameRunnable = object : Runnable {
            override fun run() {
                if (!playing) return
                val now = ((System.currentTimeMillis() - startedAt) * speed).toLong() + frameBaseMs
                var idx = currentFrame
                var acc = 0L
                for (i in 0 until durations.size) {
                    acc += durations[i]
                    if (now < acc) {
                        idx = i
                        break
                    }
                    idx = i
                }
                if (now >= acc && durations.isNotEmpty()) {
                    // 一轮结束
                    completedLoops++
                    if (loopCount > 0 && completedLoops >= loopCount) {
                        playing = false
                        idx = 0
                        drawFrame(0)
                        return
                    }
                    playedMs = 0
                    startedAt = System.currentTimeMillis()
                    idx = 0
                }
                if (idx != currentFrame) {
                    currentFrame = idx
                    drawFrame(idx)
                }
                mainHandler.postDelayed(this, 16)
            }
        }
        mainHandler.post(frameRunnable!!)
    }

    fun pause() {
        if (!playing) return
        playing = false
        frameRunnable?.let { mainHandler.removeCallbacks(it) }
        playedMs = System.currentTimeMillis() - startedAt + frameBaseMs
    }

    fun setSpeed(s: Double) {
        speed = s.coerceIn(0.25, 4.0)
        if (playing) {
            // 重新计时, 让倍速即时生效
            playedMs = ((System.currentTimeMillis() - startedAt) * speed).toLong() + frameBaseMs
            startedAt = System.currentTimeMillis()
            frameBaseMs = playedMs
        }
    }

    fun seekTo(frame: Int) {
        if (frame < 0 || frame >= frames.size) return
        currentFrame = frame
        playedMs = 0
        startedAt = System.currentTimeMillis()
        drawFrame(frame)
    }

    fun nextFrame() = seekTo((currentFrame + 1).coerceAtMost(frames.size - 1))
    fun prevFrame() = seekTo((currentFrame - 1).coerceAtLeast(0))

    fun getState(): Map<String, Any> {
        val map = HashMap<String, Any>()
        map["currentFrame"] = currentFrame
        map["frameCount"] = frames.size
        map["playing"] = playing
        map["playedMs"] = playedMs
        map["completedLoops"] = completedLoops
        return map
    }

    /** 当前帧编码为 PNG 字节（保存当前帧用） */
    fun getCurrentFramePng(): ByteArray? {
        if (frames.isEmpty()) return null
        val bmp = frames[currentFrame]
        val out = java.io.ByteArrayOutputStream()
        if (!bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out)) {
            return null
        }
        return out.toByteArray()
    }

    fun dispose() {
        playing = false
        frameRunnable?.let { mainHandler.removeCallbacks(it) }
        frames.forEach { it.recycle() }
        frames = emptyList()
        try { surface?.release() } catch (_: Exception) {}
        textureEntry?.let { it.release() }
        textureEntry = null
    }
}
