import Foundation
import Compression
import ImageIO
import UniformTypeIdentifiers

/// 轻量原生 APNG 解码器。
///
/// 解码走系统 ImageIO（CGImageSource 逐帧），输出每帧 PNG 到缓存目录；
/// 元数据（帧数/延迟/尺寸）仍用自研 parseChunks（与 Android 一致）。
/// 自研 zlib 路径仅作兜底（ImageIO 对极少数编码器返回 count=1 时）。
enum ApngNativeDecoder {

    struct FrameInfo {
        var width: Int
        var height: Int
        var xOffset: Int
        var yOffset: Int
        var delayNum: Int
        var delayDen: Int
        var disposeOp: Int
        var blendOp: Int
        // 压缩数据段列表（IDAT/fdAT 可能分多段）
        var segments: [(offset: Int, len: Int)]
    }

    struct ApngMeta {
        var width: Int
        var height: Int
        var bitDepth: Int
        var colorType: Int
        var interlace: Int
        var frames: [FrameInfo]
        var plte: Data?
        var trns: Data?
        var loopCount: Int
    }

    /// 解码 APNG 文件，每帧输出 PNG 到 tmp，返回路径列表；不支持返回 nil
    static func decode(path: String, tmpDir: URL) -> [String]? {
        guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            NSLog("[ApngNativeDecoder] FAIL: cannot read file")
            return nil
        }
        guard let meta = parseChunks(bytes) else {
            NSLog("[ApngNativeDecoder] FAIL: parseChunks nil")
            return nil
        }
        guard meta.frames.count >= 2 else {
            NSLog("[ApngNativeDecoder] FAIL: frames=\(meta.frames.count) (<2)")
            return nil
        }
        NSLog("[ApngNativeDecoder] decode start frames=\(meta.frames.count) size=\(meta.width)x\(meta.height)")

        // 主路径：系统 ImageIO 逐帧解码（支持 APNG 帧枚举、blend/dispose 合成）
        if let paths = decodeViaImageIO(bytes: bytes, frameCount: meta.frames.count, tmpDir: tmpDir) {
            NSLog("[ApngNativeDecoder] decode done (ImageIO) frames=\(paths.count) dir=\(tmpDir.path)")
            return paths
        }
        NSLog("[ApngNativeDecoder] ImageIO unavailable, fallback self-decoder")

        // 兜底：自研 zlib + 行滤波（全尺寸 source-blend 帧）
        guard meta.interlace == 0, meta.bitDepth == 8 else {
            NSLog("[ApngNativeDecoder] FAIL: self-decoder interlace/bitDepth unsupported")
            return nil
        }
        for f in meta.frames {
            if f.xOffset != 0 || f.yOffset != 0 ||
                f.width != meta.width || f.height != meta.height ||
                f.blendOp != 0 {
                NSLog("[ApngNativeDecoder] FAIL: self-decoder complex frame (fallback Dart)")
                return nil
            }
        }
        var outPaths = [String](repeating: "", count: meta.frames.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: meta.frames.count) { i in
            if let png = selfDecodeFrameToPng(bytes, meta, meta.frames[i]) {
                let dest = tmpDir.appendingPathComponent("frame_\(i).png")
                do {
                    try png.write(to: dest)
                    lock.lock()
                    outPaths[i] = dest.path
                    lock.unlock()
                } catch {
                    NSLog("[ApngNativeDecoder] FAIL: write frame_\(i) err=\(error)")
                }
            } else {
                NSLog("[ApngNativeDecoder] FAIL: selfDecodeFrameToPng frame_\(i)")
            }
        }
        if outPaths.contains("") {
            NSLog("[ApngNativeDecoder] FAIL: incomplete frames \(outPaths.filter { $0 == "" }.count)/\(outPaths.count)")
            return nil
        }
        NSLog("[ApngNativeDecoder] decode done (self) frames=\(outPaths.count) dir=\(tmpDir.path)")
        return outPaths
    }

    /// 系统 ImageIO 逐帧解码 → 每帧 PNG 文件（.png，与 Android 缓存格式一致）
    private static func decodeViaImageIO(bytes: Data, frameCount: Int, tmpDir: URL) -> [String]? {
        guard let src = CGImageSourceCreateWithData(bytes as CFData, nil) else {
            NSLog("[ApngNativeDecoder] ImageIO: cannot create source")
            return nil
        }
        let ioCount = CGImageSourceGetCount(src)
        NSLog("[ApngNativeDecoder] ImageIO count=\(ioCount) parsed=\(frameCount)")
        // ImageIO 若把 APNG 当静态图（count=1）则放弃，走自研兜底
        guard ioCount == frameCount, ioCount >= 2 else {
            return nil
        }
        var outPaths = [String](repeating: "", count: ioCount)
        let lock = NSLock()
        // CGImageSource 读取线程安全（索引随机访问），并行写 PNG
        DispatchQueue.concurrentPerform(iterations: ioCount) { i in
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else {
                NSLog("[ApngNativeDecoder] ImageIO: frame \(i) nil")
                return
            }
            let dest = tmpDir.appendingPathComponent("frame_\(i).png") as CFURL
            guard let dst = CGImageDestinationCreateWithURL(dest, UTType.png.identifier as CFString, 1, nil) else {
                NSLog("[ApngNativeDecoder] ImageIO: create destination \(i) nil")
                return
            }
            CGImageDestinationAddImage(dst, cg, nil)
            if CGImageDestinationFinalize(dst) {
                lock.lock()
                outPaths[i] = tmpDir.appendingPathComponent("frame_\(i).png").path
                lock.unlock()
            } else {
                NSLog("[ApngNativeDecoder] ImageIO: finalize frame \(i) failed")
            }
        }
        if outPaths.contains("") {
            NSLog("[ApngNativeDecoder] ImageIO: incomplete \(outPaths.filter { $0 == "" }.count)/\(outPaths.count)")
            return nil
        }
        return outPaths
    }

    /// 只解析元数据（宽高/帧数/时长/loop）
    static func peekMeta(path: String) -> ApngMeta? {
        guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return parseChunks(bytes)
    }

    // MARK: - Chunk 解析

    private static func parseChunks(_ bytes: Data) -> ApngMeta? {
        guard bytes.count >= 8 else { return nil }
        let sig: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        if Array(bytes.prefix(8)) != sig { return nil }

        var off = 8
        var width = 0, height = 0, bitDepth = 8, colorType = 0, interlace = 0
        var plte: Data?, trns: Data?
        var numFrames = 0, loopCount = 0
        var frames: [FrameInfo] = []

        var curW = 0, curH = 0, curX = 0, curY = 0
        var curDelayNum = 0, curDelayDen = 0, curDispose = 0, curBlend = 0
        // 当前帧的压缩数据段（IDAT/fdAT 分多段）
        var curSegments: [(offset: Int, len: Int)] = []

        func flushFrame() {
            if !curSegments.isEmpty {
                frames.append(FrameInfo(
                    width: curW, height: curH, xOffset: curX, yOffset: curY,
                    delayNum: curDelayNum, delayDen: curDelayDen,
                    disposeOp: curDispose, blendOp: curBlend,
                    segments: curSegments))
            }
        }

        while off + 8 <= bytes.count {
            let len = readInt(bytes, off)
            guard let type = String(data: bytes.subdata(in: (off + 4)..<(off + 8)), encoding: .ascii) else { return nil }
            let dataOff = off + 8
            let dataEnd = dataOff + len
            guard dataEnd + 4 <= bytes.count else { return nil }

            switch type {
            case "IHDR":
                guard len >= 13 else { return nil }
                width = readInt(bytes, dataOff)
                height = readInt(bytes, dataOff + 4)
                bitDepth = Int(bytes[dataOff + 8])
                colorType = Int(bytes[dataOff + 9])
                interlace = Int(bytes[dataOff + 12])
            case "acTL":
                if len >= 8 {
                    numFrames = readInt(bytes, dataOff)
                    loopCount = readInt(bytes, dataOff + 4)
                }
            case "fcTL":
                if len >= 26 {
                    flushFrame()
                    curW = readInt(bytes, dataOff + 4)
                    curH = readInt(bytes, dataOff + 8)
                    curX = readInt(bytes, dataOff + 12)
                    curY = readInt(bytes, dataOff + 16)
                    curDelayNum = readShort(bytes, dataOff + 20)
                    curDelayDen = readShort(bytes, dataOff + 22)
                    curDispose = Int(bytes[dataOff + 24])
                    curBlend = Int(bytes[dataOff + 25])
                    curSegments = []
                }
            case "IDAT":
                curSegments.append((offset: dataOff, len: len))
            case "fdAT":
                // 跳过 4 字节 sequence number
                curSegments.append((offset: dataOff + 4, len: len - 4))
            case "PLTE":
                plte = bytes.subdata(in: dataOff..<dataEnd)
            case "tRNS":
                trns = bytes.subdata(in: dataOff..<dataEnd)
            case "IEND":
                flushFrame()
                return ApngMeta(width: width, height: height, bitDepth: bitDepth,
                                colorType: colorType, interlace: interlace,
                                frames: frames, plte: plte, trns: trns,
                                loopCount: loopCount)
            default:
                break
            }
            off = dataEnd + 4
        }
        return nil
    }

    // MARK: - 兜底：自研逐帧解码（保留旧实现，ImageIO 不可用时使用）

    private static func selfDecodeFrameToPng(_ bytes: Data, _ meta: ApngMeta, _ frame: FrameInfo) -> Data? {
        let w = frame.width, h = frame.height
        let channels: Int
        switch meta.colorType {
        case 0: channels = 1
        case 2: channels = 3
        case 3: channels = 1
        case 4: channels = 2
        case 6: channels = 4
        default: return nil
        }
        let rowBytes = w * channels

        var compressed = Data()
        for seg in frame.segments {
            compressed.append(bytes.subdata(in: seg.offset..<(seg.offset + seg.len)))
        }
        guard let raw = inflate(compressed, minOutput: h * (rowBytes + 1)) else { return nil }
        guard raw.count >= h * (rowBytes + 1) else { return nil }

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        var src = 0
        var prevRow = [UInt8](repeating: 0, count: rowBytes)
        var rawArr = [UInt8](raw)

        for y in 0..<h {
            guard src < rawArr.count else { return nil }
            let filter = Int(rawArr[src]); src += 1
            guard src + rowBytes <= rawArr.count else { return nil }
            var row = Array(rawArr[src..<(src + rowBytes)]); src += rowBytes
            unfilter(filter, &row, prevRow, channels)
            fillPixels(meta, row, &pixels, y, w)
            prevRow = row
        }
        return Data(pixels)
    }

    private static func fillPixels(_ meta: ApngMeta, _ row: [UInt8], _ pixels: inout [UInt8], _ y: Int, _ w: Int) {
        var px = y * w * 4
        switch meta.colorType {
        case 6: // rgba
            for x in 0..<w {
                pixels[px] = row[x * 4]
                pixels[px + 1] = row[x * 4 + 1]
                pixels[px + 2] = row[x * 4 + 2]
                pixels[px + 3] = row[x * 4 + 3]
                px += 4
            }
        case 2: // rgb
            for x in 0..<w {
                pixels[px] = row[x * 3]
                pixels[px + 1] = row[x * 3 + 1]
                pixels[px + 2] = row[x * 3 + 2]
                pixels[px + 3] = 255
                px += 4
            }
        case 0: // grayscale
            for x in 0..<w {
                pixels[px] = row[x]
                pixels[px + 1] = row[x]
                pixels[px + 2] = row[x]
                pixels[px + 3] = 255
                px += 4
            }
        case 4: // gray+alpha
            for x in 0..<w {
                pixels[px] = row[x * 2]
                pixels[px + 1] = row[x * 2]
                pixels[px + 2] = row[x * 2]
                pixels[px + 3] = row[x * 2 + 1]
                px += 4
            }
        case 3: // indexed
            guard let plte = meta.plte else { return }
            let trns = meta.trns
            for x in 0..<w {
                let idx = Int(row[x])
                let pi = idx * 3
                guard pi + 2 < plte.count else { return }
                pixels[px] = plte[plte.startIndex + pi]
                pixels[px + 1] = plte[plte.startIndex + pi + 1]
                pixels[px + 2] = plte[plte.startIndex + pi + 2]
                pixels[px + 3] = (trns != nil && idx < trns!.count) ? trns![trns!.startIndex + idx] : 255
                px += 4
            }
        default:
            break
        }
    }

    /// PNG 行滤波还原
    private static func unfilter(_ filter: Int, _ row: inout [UInt8], _ prev: [UInt8], _ bpp: Int) {
        let n = row.count
        switch filter {
        case 0: break
        case 1:
            for x in bpp..<n {
                row[x] = UInt8((Int(row[x]) + Int(row[x - bpp])) & 0xFF)
            }
        case 2:
            for x in 0..<n {
                row[x] = UInt8((Int(row[x]) + Int(prev[x])) & 0xFF)
            }
        case 3:
            for x in 0..<n {
                let a = x >= bpp ? Int(row[x - bpp]) : 0
                let b = Int(prev[x])
                row[x] = UInt8((Int(row[x]) + ((a + b) >> 1)) & 0xFF)
            }
        case 4:
            for x in 0..<n {
                let a = x >= bpp ? Int(row[x - bpp]) : 0
                let b = Int(prev[x])
                let c = x >= bpp ? Int(prev[x - bpp]) : 0
                let p = a + b - c
                let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                let pr: Int
                if pa <= pb && pa <= pc { pr = a }
                else if pb <= pc { pr = b }
                else { pr = c }
                row[x] = UInt8((Int(row[x]) + pr) & 0xFF)
            }
        default:
            break
        }
    }

    /// 系统 Compression zlib 解压（兜底路径）
    private static func inflate(_ data: Data, minOutput: Int) -> Data? {
        guard !data.isEmpty else { return nil }
        let maxCap = 256 << 20
        var capacity = max(minOutput, data.count * 2)
        while capacity <= maxCap {
            var output = [UInt8](repeating: 0, count: capacity)
            let outputCount = output.count
            let written = output.withUnsafeMutableBytes { dst in
                data.withUnsafeBytes { src in
                    compression_decode_buffer(
                        dst.bindMemory(to: UInt8.self).baseAddress!,
                        outputCount,
                        src.bindMemory(to: UInt8.self).baseAddress!,
                        data.count,
                        nil,
                        COMPRESSION_ZLIB)
                }
            }
            if written >= minOutput {
                return Data(output[0..<written])
            }
            capacity *= 2
        }
        return nil
    }

    private static func readInt(_ b: Data, _ off: Int) -> Int {
        Int(b[off]) << 24 | Int(b[off + 1]) << 16 | Int(b[off + 2]) << 8 | Int(b[off + 3])
    }

    private static func readShort(_ b: Data, _ off: Int) -> Int {
        Int(b[off]) << 8 | Int(b[off + 1])
    }
}