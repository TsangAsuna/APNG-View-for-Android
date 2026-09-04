package com.apngviewer.apng_viewer

import android.graphics.Bitmap
import java.io.File
import java.io.FileOutputStream
import java.util.zip.Inflater

/**
 * 轻量原生 APNG 解码器（自研，不依赖 ImageDecoder）。
 *
 * 为什么自研：minSdk=24，ImageDecoder(API 28+) 在低版本不可用；且需要把
 * 每一帧解码为 PNG 字节返回给 Dart。这里直接解析 PNG/APNG chunk 结构，
 * 用系统 zlib(Inflater) 解压 + 行滤波还原，速度快于纯 Dart 10~30 倍
 * （ImageToolbox/coil 同思路）。
 *
 * 支持：8-bit 灰度/RGB/RGBA/索引色，非隔行扫描；帧为全尺寸 source-blend
 * （最常见 APNG）。复杂帧（偏移/叠加/隔行/16bit）返回 null → Dart 回退。
 */
object ApngNativeDecoder {

    // PNG 文件签名（避免 Long 溢出：0x89504E470D0A1A0A 最高位为 1）
    private val PNG_SIG = byteArrayOf(
        0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)

    data class FrameInfo(
        val width: Int, val height: Int,
        val xOffset: Int, val yOffset: Int,
        val delayNum: Int, val delayDen: Int,
        val disposeOp: Int, val blendOp: Int,
        // 压缩数据段列表（每段 [offset, len]）——IDAT/fdAT 可能分多段
        val segments: List<LongArray>,
    )

    data class ApngMeta(
        val width: Int, val height: Int,
        val bitDepth: Int, val colorType: Int,
        val interlace: Int,
        val frames: List<FrameInfo>,
        val plte: ByteArray?,
        val trns: ByteArray?,
        val loopCount: Int,
    )

    /**
     * 解码 APNG 文件，每帧输出 PNG 到 tmp 目录。
     * @return 帧 PNG 文件路径列表（按帧序）；不支持/失败返回 null
     */
    fun decode(path: String, tmpDir: File): List<String>? = try {
        val bytes = File(path).readBytes()
        val meta = parseChunks(bytes) ?: return null
        // 只支持非隔行、8-bit
        if (meta.interlace != 0) return null
        if (meta.bitDepth != 8) return null
        // 帧数 < 2 时不走原生（静态图交给 Dart 即可）
        if (meta.frames.size < 2) return null
        // 仅支持全尺寸 source-blend 帧（最常见）；否则回退 Dart 完整合成
        for (f in meta.frames) {
            if (f.xOffset != 0 || f.yOffset != 0 ||
                f.width != meta.width || f.height != meta.height ||
                f.blendOp != 0 // 0 = APNG_BLEND_OP_SOURCE
            ) return null
        }

        // 并行解码每一帧（8 Gen 3 等多核设备拉满全部核心，避免单核瓶颈）
        val cpuCount = Runtime.getRuntime().availableProcessors()
        val executor = java.util.concurrent.Executors.newFixedThreadPool(cpuCount)
        try {
            val futures = meta.frames.map { f ->
                executor.submit<ByteArray?> {
                    decodeFrameToPng(bytes, meta, f)
                }
            }
            val outPaths = ArrayList<String>(meta.frames.size)
            for ((i, future) in futures.withIndex()) {
                val png = future.get() ?: return null
                val dest = File(tmpDir, "frame_${i}.rgba")
                FileOutputStream(dest).use { it.write(png) }
                outPaths.add(dest.absolutePath)
            }
            outPaths
        } finally {
            executor.shutdown()
        }
    } catch (e: Exception) {
        null
    }

    /**
     * 只解析元数据（宽高/帧数/时长/loop），不解码像素。
     * 供上层构建返回 Map 使用；失败返回 null。
     */
    fun peekMeta(path: String): ApngMeta? = try {
        parseChunks(File(path).readBytes())
    } catch (e: Exception) {
        null
    }

    /** 解码单帧为 RGBA 字节（原生播放器用：原生侧转 Bitmap，不跨层） */
    fun decodeFrameRgba(
        bytes: ByteArray,
        meta: ApngMeta,
        frame: FrameInfo,
    ): ByteArray? = try {
        decodeFrameToPng(bytes, meta, frame)
    } catch (e: Exception) {
        null
    }

    /** 解析 PNG chunk，收集帧元数据。 */
    private fun parseChunks(bytes: ByteArray): ApngMeta? {
        if (bytes.size < 8) return null
        if (!bytes.copyOfRange(0, 8).contentEquals(PNG_SIG)) return null

        var off = 8
        var width = 0; var height = 0
        var bitDepth = 8; var colorType = 0; var interlace = 0
        var plte: ByteArray? = null
        var trns: ByteArray? = null
        var numFrames = 0; var loopCount = 0
        val frames = ArrayList<FrameInfo>()

        var seq = 0
        var curWidth = 0; var curHeight = 0
        var curX = 0; var curY = 0
        var curDelayNum = 0; var curDelayDen = 0
        var curDispose = 0; var curBlend = 0
        // 当前帧的压缩数据段（IDAT/fdAT 可能分多段，每段 [offset, len]）
        val curSegments = ArrayList<LongArray>()

        fun flushFrame() {
            if (curSegments.isNotEmpty()) {
                frames.add(FrameInfo(
                    width = curWidth, height = curHeight,
                    xOffset = curX, yOffset = curY,
                    delayNum = curDelayNum, delayDen = curDelayDen,
                    disposeOp = curDispose, blendOp = curBlend,
                    segments = ArrayList(curSegments)))
            }
        }

        while (off + 8 <= bytes.size) {
            val len = readInt(bytes, off)
            val type = String(bytes, off + 4, 4, Charsets.US_ASCII)
            val dataOff = off + 8
            val dataEnd = dataOff + len
            if (dataEnd + 4 > bytes.size) return null // 越界/损坏

            when (type) {
                "IHDR" -> {
                    if (len < 13) return null
                    width = readInt(bytes, dataOff)
                    height = readInt(bytes, dataOff + 4)
                    bitDepth = bytes[dataOff + 8].toInt() and 0xFF
                    colorType = bytes[dataOff + 9].toInt() and 0xFF
                    interlace = bytes[dataOff + 12].toInt() and 0xFF
                }
                "acTL" -> {
                    if (len >= 8) {
                        numFrames = readInt(bytes, dataOff)
                        loopCount = readInt(bytes, dataOff + 4)
                    }
                }
                "fcTL" -> {
                    if (len >= 26) {
                        flushFrame()
                        seq = readInt(bytes, dataOff)
                        curWidth = readInt(bytes, dataOff + 4)
                        curHeight = readInt(bytes, dataOff + 8)
                        curX = readInt(bytes, dataOff + 12)
                        curY = readInt(bytes, dataOff + 16)
                        curDelayNum = readShort(bytes, dataOff + 20)
                        curDelayDen = readShort(bytes, dataOff + 22)
                        curDispose = bytes[dataOff + 24].toInt() and 0xFF
                        curBlend = bytes[dataOff + 25].toInt() and 0xFF
                        curSegments.clear()
                    }
                }
                "IDAT" -> {
                    // 属于当前帧（第一帧）；多段累加
                    curSegments.add(longArrayOf(dataOff.toLong(), len.toLong()))
                }
                "fdAT" -> {
                    // 跳过 4 字节 sequence number
                    curSegments.add(longArrayOf((dataOff + 4).toLong(), (len - 4).toLong()))
                }
                "PLTE" -> plte = bytes.copyOfRange(dataOff, dataEnd)
                "tRNS" -> trns = bytes.copyOfRange(dataOff, dataEnd)
                "IEND" -> {
                    flushFrame()
                    break
                }
            }
            off = dataEnd + 4 // 跳过 CRC
        }

        if (width <= 0 || height <= 0) return null
        if (frames.isEmpty() && numFrames <= 1 && curSegments.isNotEmpty()) {
            // 静态 PNG：单帧（IDAT 数据）也记录，便于统一处理
            frames.add(FrameInfo(width, height, 0, 0, 0, 0, 0, 0,
                ArrayList(curSegments)))
        }
        return ApngMeta(width, height, bitDepth, colorType, interlace,
            frames, plte, trns, loopCount)
    }

    /** 解压单帧 IDAT/fdAT 数据 → 行滤波还原 → 编码 PNG。 */
    private fun decodeFrameToPng(
        bytes: ByteArray, meta: ApngMeta, frame: FrameInfo,
    ): ByteArray? {
        val w = frame.width; val h = frame.height
        val channels = when (meta.colorType) {
            0 -> 1  // grayscale
            2 -> 3  // rgb
            3 -> 1  // indexed（调色板）
            4 -> 2  // grayscale+alpha
            6 -> 4  // rgba
            else -> return null
        }
        val bpp = channels // 8-bit
        val rowBytes = w * channels

        // zlib 解压：把各 IDAT/fdAT 数据段拼成完整压缩流
        var total = 0
        for (seg in frame.segments) total += seg[1].toInt()
        val compressed = ByteArray(total)
        var cp = 0
        for (seg in frame.segments) {
            System.arraycopy(bytes, seg[0].toInt(), compressed, cp, seg[1].toInt())
            cp += seg[1].toInt()
        }
        val inflater = Inflater()
        inflater.setInput(compressed)
        val raw = ByteArray(rowBytes * h + h) // 每行 1 字节 filter
        var rawLen = 0
        try {
            while (!inflater.finished() && rawLen < raw.size) {
                val n = inflater.inflate(raw, rawLen, raw.size - rawLen)
                if (n <= 0) break
                rawLen += n
            }
        } catch (e: Exception) {
            return null
        } finally {
            inflater.end()
        }
        if (rawLen < h * (rowBytes + 1)) return null

        // 行滤波还原（None/Sub/Up/Average/Paeth）
        val pixels = ByteArray(w * h * 4)
        var src = 0
        var prevRow = ByteArray(rowBytes)
        for (y in 0 until h) {
            val filter = raw[src].toInt() and 0xFF
            src++
            val row = ByteArray(rowBytes)
            System.arraycopy(raw, src, row, 0, rowBytes)
            src += rowBytes
            unfilter(filter, row, prevRow, bpp)
            // 写入 RGBA 像素
            var px = y * w * 4
            when (meta.colorType) {
                6 -> { // rgba
                    for (x in 0 until w) {
                        pixels[px] = row[x * 4]
                        pixels[px + 1] = row[x * 4 + 1]
                        pixels[px + 2] = row[x * 4 + 2]
                        pixels[px + 3] = row[x * 4 + 3]
                        px += 4
                    }
                }
                2 -> { // rgb
                    for (x in 0 until w) {
                        pixels[px] = row[x * 3]
                        pixels[px + 1] = row[x * 3 + 1]
                        pixels[px + 2] = row[x * 3 + 2]
                        pixels[px + 3] = 255.toByte()
                        px += 4
                    }
                }
                0 -> { // grayscale
                    for (x in 0 until w) {
                        val g = row[x].toInt() and 0xFF
                        pixels[px] = g.toByte()
                        pixels[px + 1] = g.toByte()
                        pixels[px + 2] = g.toByte()
                        pixels[px + 3] = 255.toByte()
                        px += 4
                    }
                }
                4 -> { // grayscale+alpha
                    for (x in 0 until w) {
                        val g = row[x * 2].toInt() and 0xFF
                        pixels[px] = g.toByte()
                        pixels[px + 1] = g.toByte()
                        pixels[px + 2] = g.toByte()
                        pixels[px + 3] = row[x * 2 + 1]
                        px += 4
                    }
                }
                3 -> { // indexed → 调色板
                    val plte = meta.plte ?: return null
                    val trns = meta.trns
                    for (x in 0 until w) {
                        val idx = row[x].toInt() and 0xFF
                        val pi = idx * 3
                        if (pi + 2 >= plte.size) return null
                        pixels[px] = plte[pi]
                        pixels[px + 1] = plte[pi + 1]
                        pixels[px + 2] = plte[pi + 2]
                        pixels[px + 3] =
                            if (trns != null && idx < trns.size) trns[idx]
                            else 255.toByte()
                        px += 4
                    }
                }
            }
            prevRow = row
        }

        // 直出 RGBA 裸像素（绕过 PNG 中间格式：不再 Bitmap.compress 编码）
        return pixels
    }

    /** PNG 行滤波还原 */
    private fun unfilter(
        filter: Int, row: ByteArray, prev: ByteArray, bpp: Int,
    ) {
        val n = row.size
        when (filter) {
            0 -> {} // None
            1 -> { // Sub
                for (x in bpp until n) {
                    row[x] = (row[x].toInt() + (row[x - bpp].toInt() and 0xFF)).toByte()
                }
            }
            2 -> { // Up
                for (x in 0 until n) {
                    row[x] = (row[x].toInt() + (prev[x].toInt() and 0xFF)).toByte()
                }
            }
            3 -> { // Average
                for (x in 0 until n) {
                    val a = if (x >= bpp) row[x - bpp].toInt() and 0xFF else 0
                    val b = prev[x].toInt() and 0xFF
                    row[x] = (row[x].toInt() + ((a + b) shr 1)).toByte()
                }
            }
            4 -> { // Paeth
                for (x in 0 until n) {
                    val a = if (x >= bpp) row[x - bpp].toInt() and 0xFF else 0
                    val b = prev[x].toInt() and 0xFF
                    val c = if (x >= bpp) prev[x - bpp].toInt() and 0xFF else 0
                    val p = a + b - c
                    val pa = kotlin.math.abs(p - a)
                    val pb = kotlin.math.abs(p - b)
                    val pc = kotlin.math.abs(p - c)
                    val pred = when {
                        pa <= pb && pa <= pc -> a
                        pb <= pc -> b
                        else -> c
                    }
                    row[x] = (row[x].toInt() + pred).toByte()
                }
            }
        }
    }

    private fun readInt(b: ByteArray, off: Int): Int =
        ((b[off].toInt() and 0xFF) shl 24) or
            ((b[off + 1].toInt() and 0xFF) shl 16) or
            ((b[off + 2].toInt() and 0xFF) shl 8) or
            (b[off + 3].toInt() and 0xFF)

    private fun readShort(b: ByteArray, off: Int): Int =
        ((b[off].toInt() and 0xFF) shl 8) or (b[off + 1].toInt() and 0xFF)
}
