import Foundation
import UIKit
import CoreVideo
import QuartzCore
import Flutter

/// 原生 APNG 播放器（iOS，对齐 ImageToolbox 架构）。
///
/// 解码与渲染全在原生侧：自研解码器把每帧解码为 CGImage，
/// 转 CVPixelBuffer 后通过 FlutterTexture 逐帧上屏，
/// CADisplayLink 驱动播放。Dart 只拿 textureId 显示 + 控制，
/// 零 RGBA 跨层传输（字节序/内存/闪退问题彻底消失）。
class ApngNativePlayer: NSObject, FlutterTexture {
    private let registry: FlutterTextureRegistry
    private var textureId: Int64 = -1
    private var pixelBufferPool: CVPixelBufferPool?
    private var textureBuffer: CVPixelBuffer?

    private var frames: [CGImage] = []
    private var durations: [Int] = []
    private var loopCount = 0
    private var currentFrame = 0
    private var playing = false
    private var completedLoops = 0
    private var playedMs = 0

    private var displayLink: CADisplayLink?
    private var startedAt: CFTimeInterval = 0
    private var frameBaseMs: Int64 = 0
    private var speed: Double = 1.0
    private let lock = NSLock()

    init(registry: FlutterTextureRegistry) {
        self.registry = registry
        super.init()
    }

    // MARK: - FlutterTexture

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        lock.lock()
        defer { lock.unlock() }
        guard let buf = textureBuffer else { return nil }
        return Unmanaged.passRetained(buf)
    }

    // MARK: - 打开/解码

    func open(path: String, result: @escaping FlutterResult) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let meta = ApngNativeDecoder.peekMeta(path: path),
                  meta.frames.count >= 2,
                  let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                DispatchQueue.main.async { result(nil) }
                return
            }
            // 全尺寸 source-blend 检查
            for f in meta.frames {
                if f.xOffset != 0 || f.yOffset != 0 ||
                    f.width != meta.width || f.height != meta.height ||
                    f.blendOp != 0 {
                    DispatchQueue.main.async { result(nil) }
                    return
                }
            }
            // 并行解码每帧为 CGImage（复用自研解码器 RGBA 输出）
            var images = [CGImage?](repeating: nil, count: meta.frames.count)
            DispatchQueue.concurrentPerform(iterations: meta.frames.count) { i in
                if let rgba = ApngNativeDecoder.decodeFrameRgba(
                    bytes: bytes, meta: meta, frame: meta.frames[i]) {
                    images[i] = Self.cgImageFromRgba(rgba, w: meta.frames[i].width, h: meta.frames[i].height)
                }
            }
            let decoded = images.compactMap { $0 }
            guard decoded.count == meta.frames.count else {
                DispatchQueue.main.async { result(nil) }
                return
            }
            self.lock.lock()
            self.frames = decoded
            self.durations = meta.frames.map { f in
                let d = (f.delayNum > 0 && f.delayDen > 0)
                    ? Int(Double(f.delayNum) * 1000 / Double(f.delayDen)) : 0
                return d > 0 ? d : 100
            }
            self.loopCount = meta.loopCount
            self.currentFrame = 0
            self.completedLoops = 0
            self.playedMs = 0
            self.lock.unlock()

            // 创建纹理
            self.textureId = self.registry.register(self)
            let w = meta.width
            let h = meta.height
            // 像素缓冲池（纹理上传用）
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            self.pixelBufferPool = pool

            // 首帧上屏
            self.renderFrame(0)

            var map: [String: Any] = [:]
            map["textureId"] = self.textureId
            map["width"] = w
            map["height"] = h
            map["frameCount"] = meta.frames.count
            map["durations"] = self.durations
            map["loopCount"] = meta.loopCount
            DispatchQueue.main.async { result(map) }
        }
    }

    // MARK: - 播放控制

    func play() {
        lock.lock()
        if frames.isEmpty || playing { lock.unlock(); return }
        playing = true
        startedAt = CACurrentMediaTime()
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.displayLink?.invalidate()
            let link = CADisplayLink(target: self, selector: #selector(self.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60)
            link.add(to: .main, forMode: .common)
            self.displayLink = link
        }
    }

    func pause() {
        lock.lock()
        guard playing else { lock.unlock(); return }
        playing = false
        playedMs += Int64((CACurrentMediaTime() - startedAt) * 1000)
        lock.unlock()
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        lock.lock()
        guard playing, !frames.isEmpty else { lock.unlock(); return }
        let now = playedMs + Int64((CACurrentMediaTime() - startedAt) * 1000 * speed)
        var idx = currentFrame
        var acc = 0
        for (i, d) in durations.enumerated() {
            acc += d
            if now < acc { idx = i; break }
            idx = i
        }
        if now >= acc {
            completedLoops += 1
            if loopCount > 0 && completedLoops >= loopCount {
                playing = false
                idx = 0
            } else {
                playedMs = 0
                startedAt = CACurrentMediaTime()
                idx = 0
            }
        }
        if idx != currentFrame {
            currentFrame = idx
            lock.unlock()
            renderFrame(idx)
            lock.lock()
        }
        lock.unlock()
        registry.textureFrameAvailable(textureId)
    }

    func setSpeed(_ s: Double) {
        lock.lock()
        speed = min(max(s, 0.25), 4.0)
        if playing {
            playedMs += Int64((CACurrentMediaTime() - startedAt) * 1000 * speed)
            startedAt = CACurrentMediaTime()
        }
        lock.unlock()
    }

    func seekTo(frame: Int) {
        lock.lock()
        guard frame >= 0 && frame < frames.count else { lock.unlock(); return }
        currentFrame = frame
        playedMs = 0
        startedAt = CACurrentMediaTime()
        lock.unlock()
        renderFrame(frame)
        registry.textureFrameAvailable(textureId)
    }

    func nextFrame() {
        lock.lock()
        let target = min(currentFrame + 1, frames.count - 1)
        lock.unlock()
        seekTo(frame: target)
    }

    func prevFrame() {
        lock.lock()
        let target = max(currentFrame - 1, 0)
        lock.unlock()
        seekTo(frame: target)
    }

    func getState() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        var map: [String: Any] = [:]
        map["currentFrame"] = currentFrame
        map["frameCount"] = frames.count
        map["playing"] = playing
        map["playedMs"] = playedMs
        map["completedLoops"] = completedLoops
        return map
    }

    /// 当前帧编码为 PNG 字节（保存当前帧用）
    func getCurrentFramePng() -> Data? {
        lock.lock()
        guard currentFrame >= 0 && currentFrame < frames.count else {
            lock.unlock(); return nil
        }
        let image = frames[currentFrame]
        lock.unlock()
        return UIImage(cgImage: image).pngData()
    }

    func dispose() {
        lock.lock()
        playing = false
        frames = []
        textureBuffer = nil
        pixelBufferPool = nil
        lock.unlock()
        displayLink?.invalidate()
        displayLink = nil
        if textureId >= 0 {
            registry.unregisterTexture(textureId)
            textureId = -1
        }
    }

    // MARK: - 渲染

    private func renderFrame(_ i: Int) {
        lock.lock()
        guard i >= 0 && i < frames.count else { lock.unlock(); return }
        let image = frames[i]
        let pool = pixelBufferPool
        lock.unlock()
        guard let pool = pool else { return }

        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let buf = pb else { return }
        CVPixelBufferLockBaseAddress(buf, [])
        if let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buf),
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        lock.lock()
        textureBuffer = buf
        lock.unlock()
    }

    private static func cgImageFromRgba(_ rgba: Data, w: Int, h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    }
}
