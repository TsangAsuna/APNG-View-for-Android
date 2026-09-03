import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
/// APNG 文件信息
class ApngInfo {
  final String fileName;
  final String filePath;
  final int width;
  final int height;
  final int frameCount;
  final int loopCount;
  final List<int> frameDurations; // 每帧显示毫秒
  final int fileSize;

  ApngInfo({
    required this.fileName,
    required this.filePath,
    required this.width,
    required this.height,
    required this.frameCount,
    required this.loopCount,
    required this.frameDurations,
    required this.fileSize,
  });

  /// 总时长（毫秒）
  int get totalDuration => frameDurations.fold(0, (sum, d) => sum + d);

  bool get isAnimated => frameCount > 1;
}

/// 解码完成的 APNG 帧数据
///
/// 内存优化：只保留压缩后的 PNG 字节（通常比 RGBA 小 10~20 倍），
/// 渲染时由 Flutter 引擎按需解码为纹理，避免大 APNG 全量 RGBA 常驻内存导致闪退。
class ApngFrame {
  final Uint8List pngBytes; // PNG 压缩字节（内存友好）
  final int width;
  final int height;
  final int durationMs;

  ApngFrame({
    required this.pngBytes,
    required this.width,
    required this.height,
    required this.durationMs,
  });
}

/// APNG 解码器 - 基于纯 Dart image 库
///
/// 大体积 APNG 加速策略（需求 1）：
/// 1. 快速路径：PngDecoder.startDecode 只扫 chunk 头，不整体解压；
///    全尺寸 source 帧（绝大多数 APNG）逐帧独立解码，无合成依赖，可安全并行。
/// 2. 多 isolate 并行解码 + 并行 PngEncoder 压缩（默认按 CPU 核数，最多 4 路）。
/// 3. 复杂帧（偏移/叠加/背景清除）回退到原串行 decodeImage，保证正确性。
/// 4. 解码进度通过 ReceivePort 实时上报（大图不再只有空白转圈）。
class ApngDecoder {
  /// 兼容旧调用：串行解码（convert_page 预览等小图场景继续使用）。
  static ApngDecodeResult? decode(Uint8List bytes, {String filePath = ''}) {
    try {
      final img.Image? decoded = img.decodeImage(bytes);
      if (decoded == null) return null;

      final frames = <ApngFrame>[];
      final durations = <int>[];
      final encoder = img.PngEncoder(level: 1);

      final allFrames = decoded.frames;
      for (final frame in allFrames) {
        final img.Image frameImg = frame;
        final rgba = frameImg.numChannels != 4
            ? frameImg.convert(numChannels: 4)
            : frameImg;
        final png = encoder.encode(rgba);
        final dur = frame.frameDuration > 0 ? frame.frameDuration : 100;
        frames.add(ApngFrame(
          pngBytes: png,
          width: frameImg.width,
          height: frameImg.height,
          durationMs: dur,
        ));
        durations.add(dur);
      }

      return ApngDecodeResult(
        frames: frames,
        width: decoded.width,
        height: decoded.height,
        loopCount: decoded.loopCount,
        durations: durations,
      );
    } catch (e) {
      return null;
    }
  }

  /// 并行解码（viewer 大图入口）。
  /// [onProgress] 收到 (已处理帧数, 总帧数) 进度回调。
  static Future<ApngDecodeResult?> decodeAsync(
    Uint8List bytes, {
    String filePath = '',
    void Function(int done, int total)? onProgress,
  }) async {
    try {
      // 第一步：快速扫 chunk 头，判断是否走并行快速路径
      final decoder = img.PngDecoder();
      final info = decoder.startDecode(bytes);
      if (info == null) return null;

      final canvasW = info.width;
      final canvasH = info.height;
      final pngInfo = info as img.PngInfo;

      // 收集帧元数据；全尺寸 source 帧才可并行独立解码
      final frames = pngInfo.frames;

      // 安全防护：APNG 允许第一帧无 fcTL（IDAT 默认图），此时
      // frames.length 可能 != numFrames，跳帧索引会越界抛异常。
      // 这类文件直接回退串行 decode()，保证能显示。
      final frameCount = frames.length;
      if (frameCount == 0 || frameCount != pngInfo.numFrames) {
        final r = decode(bytes, filePath: filePath);
        onProgress?.call(r?.frames.length ?? 0, r?.frames.length ?? 0);
        return r;
      }

      final fast = frameCount > 1 &&
          frames.every((f) =>
              f.xOffset == 0 &&
              f.yOffset == 0 &&
              f.width == canvasW &&
              f.height == canvasH &&
              f.blend == img.PngBlendMode.source);

      // 复杂动画（部分区域更新/混合/清除）回退原串行实现，保证帧合成正确
      if (!fast) {
        final r = decode(bytes, filePath: filePath);
        onProgress?.call(r?.frames.length ?? 0, r?.frames.length ?? 0);
        return r;
      }

      // 第二步：并行逐帧解码 + 并行 PNG 压缩
      // 帧时长在主子 isolate 由 delayNum/delayDen 计算（decodeFrame 不设置时长）
      final frameDurations = <int>[];
      for (final f in frames) {
        var d = 0;
        if (f.delayNum > 0 && f.delayDen > 0) {
          d = (f.delayNum * 1000 / f.delayDen).round();
        }
        frameDurations.add(d > 0 ? d : 100);
      }

      final workerCount = _workerCount(frameCount);
      final batches = <List<int>>[];
      for (var i = 0; i < frameCount; i += workerCount) {
        batches.add(List.generate(
            i + workerCount <= frameCount ? workerCount : frameCount - i,
            (k) => i + k));
      }

      // 用 TransferableTypedData 零拷贝传递帧字节，避免每帧拷贝整个文件
      final transferable = TransferableTypedData.fromList([bytes]);

      final results = List<ApngFrame?>.filled(frameCount, null);
      final doneCount = _ProgressCounter();
      for (final batch in batches) {
        final futures = <Future<void>>[];
        for (final idx in batch) {
          futures.add(Future(() async {
            final frame = await _decodeOneFrame(
                transferable, idx, canvasW, canvasH, frameDurations[idx]);
            results[idx] = frame;
            final done = doneCount.add();
            onProgress?.call(done, frameCount);
          }));
        }
        await Future.wait(futures);
      }

      // 收集（保持原始帧序）；任一帧失败则整体回退串行解码，
      // 保证任何 APNG 都能显示而不是返回 null
      final out = <ApngFrame>[];
      final durations = <int>[];
      for (final f in results) {
        if (f == null) {
          final r = decode(bytes, filePath: filePath);
          onProgress?.call(r?.frames.length ?? 0, r?.frames.length ?? 0);
          return r;
        }
        out.add(f);
        durations.add(f.durationMs);
      }

      // loopCount：acTL 的 num_plays（0 = 无限循环）
      final loopCount = info is img.PngInfo ? info.repeat : 0;

      return ApngDecodeResult(
        frames: out,
        width: canvasW,
        height: canvasH,
        loopCount: loopCount,
        durations: durations,
      );
    } catch (e) {
      // 任何意外错误回退串行解码，兜底保证可预览
      final r = decode(bytes, filePath: filePath);
      onProgress?.call(r?.frames.length ?? 0, r?.frames.length ?? 0);
      return r;
    }
  }

  static int _workerCount(int n) {
    // 默认 4 路并行；帧数少时用帧数（避免空转）
    if (n < 2) return 1;
    return n < 4 ? n : 4;
  }

  /// 在后台 isolate 中解码第 [idx] 帧并压缩为 PNG（快速路径帧）
  static Future<ApngFrame?> _decodeOneFrame(
      TransferableTypedData bytes, int idx, int w, int h, int durationMs) async {
    return await compute(_frameWorker, <Object>[bytes, idx, w, h, durationMs]);
  }

  /// isolate worker：独立 decoder 解码单帧 + level1 压缩
  static ApngFrame? _frameWorker(List<Object> args) {
    try {
      final data = args[0] as TransferableTypedData;
      final bytes = data.materialize().asUint8List();
      final idx = args[1] as int;
      final w = args[2] as int;
      final h = args[3] as int;
      final durationMs = args[4] as int;
      final decoder = img.PngDecoder();
      final info = decoder.startDecode(bytes);
      if (info == null) return null;
      // 防御：帧索引越界（无 fcTL 第一帧等情况）直接失败，
      // 由上层整体回退串行解码
      final pngInfo = info as img.PngInfo;
      if (idx < 0 || idx >= pngInfo.frames.length) return null;
      final image = decoder.decodeFrame(idx);
      if (image == null) return null;
      final rgba = image.numChannels != 4
          ? image.convert(numChannels: 4)
          : image;
      final png = img.PngEncoder(level: 1).encode(rgba);
      return ApngFrame(
        pngBytes: png,
        width: w,
        height: h,
        durationMs: durationMs,
      );
    } catch (e) {
      return null;
    }
  }
}

/// 线程安全进度计数（主 isolate 内单线程，仅累加）
class _ProgressCounter {
  int _v = 0;
  int add() => ++_v;
}

class ApngDecodeResult {
  final List<ApngFrame> frames;
  final int width;
  final int height;
  final int loopCount;
  final List<int> durations;

  ApngDecodeResult({
    required this.frames,
    required this.width,
    required this.height,
    required this.loopCount,
    required this.durations,
  });

  bool get isAnimated => frames.length > 1;

  /// 总时长（毫秒）
  int get totalDurationMs =>
      frames.fold<int>(0, (sum, f) => sum + f.durationMs);
}
