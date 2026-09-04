import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';

import 'apng/apng_decoder.dart';
import 'apng/apng_player.dart';
import 'apng/apng_frame_view.dart';
import 'apng/native_apng_player.dart';
import 'platform_file_gateway.dart';

class ViewerPage extends StatefulWidget {
  final String path;
  final String fileName;

  const ViewerPage({
    super.key,
    required this.path,
    required this.fileName,
  });

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  Future<ApngDecodeResult?>? _future;
  ApngPlayer? _player;
  NativeApngPlayer? _nativePlayer;
  bool _fullscreen = false;
  double _speed = 1.0;
  bool _saving = false;
  String _decodeStatus = '';

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<ApngDecodeResult?> _load() async {
    // 原生播放器优先（对齐 ImageToolbox：原生解码+渲染到 Texture，秒开）
    final native = NativeApngPlayer();
    final ok = await native.open(widget.path);
    if (ok) {
      _nativePlayer = native;
      if (mounted) setState(() {});
      return null; // 原生模式不产生 Dart 帧数据
    }
    await native.dispose();
    _nativePlayer = null;
    // 回退纯 Dart 解码（原生不支持时保证可用）
    try {
      final bytes = await File(widget.path).readAsBytes();
      return await ApngDecoder.decodeAsync(
        bytes,
        filePath: widget.path,
        onProgress: (done, total) {
          if (mounted) {
            setState(() => _decodeStatus = '正在解码 $done/$total 帧');
          }
        },
      );
    } catch (_) {
      return null;
    }
  }

  /// 保存当前帧为 PNG（进度条拖到哪一帧就提取哪一帧）
  Future<void> _saveCurrentFrame() async {
    final frame = _player?.currentFrameData;
    final native = _nativePlayer;
    if (frame == null && native == null) return;
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final base = widget.fileName.replaceAll(RegExp(r'\\.(apng|png)$', caseSensitive: false), '');
      final idx = (_player?.currentFrame ?? 0);
      final name = '${base}_frame_${idx + 1}.png';
      Uint8List? data;
      if (native != null) {
        // 原生模式：从原生侧取当前帧 PNG（原生编码，无 Dart 帧数据）
        data = await native.getCurrentFramePng();
      } else {
        data = frame?.exportPng;
      }
      if (data == null || data.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前帧不可用')),
        );
        return;
      }
      final ok = await FileGateway.writeExport(
        fileName: name,
        mime: 'image/png',
        data: data,
        useCustomDir: false,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? '已保存第 ${idx + 1} 帧' : '保存已取消')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 保存原始 APNG 文件（保留动画与原始字节，不转码不压缩）
  Future<void> _saveOriginalFile() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final bytes = await File(widget.path).readAsBytes();
      final ok = await FileGateway.writeExport(
        fileName: widget.fileName,
        mime: 'image/apng',
        data: bytes,
        useCustomDir: false,
        keepOriginal: true,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? '已保存原文件' : '保存已取消')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    _nativePlayer?.dispose();
    _nativePlayer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _fullscreen
          ? null
          : AppBar(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              title: Text(widget.fileName,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(
                  icon: const Icon(Icons.save_alt),
                  tooltip: '保存原文件（完整动画）',
                  onPressed: _saving ? null : _saveOriginalFile,
                ),
                IconButton(
                  icon: const Icon(Icons.fullscreen),
                  tooltip: '全屏',
                  onPressed: () => setState(() => _fullscreen = true),
                ),
              ],
            ),
      body: FutureBuilder<ApngDecodeResult?>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(
                    _decodeStatus.isEmpty
                        ? '正在解码 APNG… 大图可能需要几秒'
                        : _decodeStatus,
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            );
          }
          final result = snapshot.data;
          // 原生模式：result 为 null 但 _nativePlayer 已就绪（解码渲染在原生侧）
          if (result == null && _nativePlayer == null) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.broken_image,
                      size: 64, color: Colors.white54),
                  const SizedBox(height: 12),
                  const Text('无法打开该图片',
                      style: TextStyle(color: Colors.white70)),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('返回'),
                  ),
                ],
              ),
            );
          }

          // 确保播放器已初始化（后台解码完成后）
          if (_player == null) {
            _player = ApngPlayer(result, native: _nativePlayer);
            if (_nativePlayer != null) {
              // 原生模式：帧数/时长/尺寸来自原生元数据
              if (mounted) {
                setState(() {
                  _decodeStatus = '${_nativePlayer!.frameCount} 帧';
                });
              }
            }
            if (result?.isAnimated == true || _nativePlayer != null) {
              // 不能在 build 期间直接 play()（会触发 markNeedsBuild during build，
              // iOS 上表现为首帧渲染异常/白屏），延后到本帧绘制完成后再播放。
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _player != null) {
                  _player!.play();
                }
              });
            }
          }

          return Column(
            children: [
              Expanded(
                child: GestureDetector(
                  onDoubleTap: () => setState(() => _fullscreen = !_fullscreen),
                  child: _buildViewer(result),
                ),
              ),
              _buildControlBar(result),
            ],
          );
        },
      ),
    );
  }

  Widget _buildViewer(ApngDecodeResult? result) {
    // 原生播放器模式：直接显示原生纹理（解码渲染全在原生侧）
    if (_nativePlayer != null) {
      return InteractiveViewer(
        minScale: 0.5,
        maxScale: 8.0,
        child: Center(
          child: _nativePlayer!.buildTexture(),
        ),
      );
    }
    if (result == null || !result.isAnimated) {
      // 第一帧已经是压缩后的 PNG 字节，直接交给引擎解码，
      // 避免在 UI 线程同步 encodePng 卡死界面（大图时尤为严重）
      final staticFrame = result?.frames.isNotEmpty == true
          ? result!.frames.first
          : null;
      if (staticFrame == null) {
        return const Center(child: Text('无法解码静态图', style: TextStyle(color: Colors.white70)));
      }
      return PhotoView(
        imageProvider: MemoryImage(staticFrame.exportPng),
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        minScale: PhotoViewComputedScale.contained,
        maxScale: PhotoViewComputedScale.covered * 4,
        heroAttributes: const PhotoViewHeroAttributes(tag: 'apng-view'),
      );
    }

    return AnimatedBuilder(
      animation: _player!,
      builder: (context, _) {
        final f = _player!.currentFrameData;
        if (f == null) return const SizedBox.shrink();
        return InteractiveViewer(
          minScale: 0.5,
          maxScale: 8.0,
          child: Center(
            child: ApngFrameView(
              rgbaPath: f.rgbaPath,
              rgbaLoader: f.loadRgbaBytes,
              pngBytes: f.pngBytes,
              rgbaWidth: f.width,
              rgbaHeight: f.height,
            ),
          ),
        );
      },
    );
  }

  Widget _buildControlBar(ApngDecodeResult? result) {
    return AnimatedBuilder(
      animation: _player!,
      builder: (context, _) {
        final isAnimated = result?.isAnimated == true || _nativePlayer != null;
        // 原生模式尺寸/帧数来自原生播放器
        final dispW = _nativePlayer?.width ?? result?.width ?? 0;
        final dispH = _nativePlayer?.height ?? result?.height ?? 0;
        final dispFrames = _nativePlayer?.frameCount ?? result?.frames.length ?? 0;
        return Container(
          color: const Color(0xFF1A1A1A),
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isAnimated) ...[
                  Row(
                    children: [
                      Text(
                        '${_player!.currentFrame + 1}/${_player!.frameCount}',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12),
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 2,
                            thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6),
                            overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 12),
                          ),
                          child: Slider(
                            // 用时间进度驱动，帧时长不均匀时进度条也匀速
                            value: (_player!.progress *
                                    (_player!.frameCount - 1))
                                .clamp(0, _player!.frameCount - 1),
                            max: (_player!.frameCount - 1).toDouble(),
                            onChanged: (v) {
                              _player!.gotoFrame(v.round());
                            },
                          ),
                        ),
                      ),
                      // 保存当前帧：进度条拖到哪一帧就提取哪一帧
                      IconButton(
                        icon: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white70),
                              )
                            : const Icon(Icons.save_alt,
                                color: Colors.white, size: 20),
                        tooltip: '保存当前帧',
                        onPressed: _saving ? null : _saveCurrentFrame,
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.skip_previous,
                            color: Colors.white),
                        tooltip: '上一帧',
                        onPressed: () => _player!.prevFrame(),
                      ),
                      IconButton(
                        iconSize: 44,
                        icon: Icon(
                          _player!.playing
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_fill,
                          color: const Color(0xFF4FC3F7),
                        ),
                        tooltip: _player!.playing ? '暂停' : '播放',
                        onPressed: () => _player!.togglePlay(),
                      ),
                      IconButton(
                        icon: const Icon(Icons.skip_next, color: Colors.white),
                        tooltip: '下一帧',
                        onPressed: () => _player!.nextFrame(),
                      ),
                      const SizedBox(width: 8),
                      _SpeedButton(
                        speed: _speed,
                        onChanged: (s) {
                          setState(() => _speed = s);
                          _player!.setSpeed(s);
                        },
                      ),
                    ],
                  ),
                ] else ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      '静态图片 · $dispW×$dispH · 双指缩放预览',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Text('$dispW×$dispH',
                        style:
                            const TextStyle(color: Colors.white54, fontSize: 12)),
                    Text('$dispFrames 帧',
                        style:
                            const TextStyle(color: Colors.white54, fontSize: 12)),
                    if (isAnimated)
                      Text(_formatDuration(dispFrames),
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12)),
                    _fullscreen
                        ? IconButton(
                            icon: const Icon(Icons.fullscreen_exit,
                                color: Colors.white54, size: 20),
                            onPressed: () =>
                                setState(() => _fullscreen = false),
                          )
                        : IconButton(
                            icon: const Icon(Icons.fullscreen,
                                color: Colors.white54, size: 20),
                            onPressed: () =>
                                setState(() => _fullscreen = true),
                          ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatDuration(int frameCount) {
    int totalMs;
    if (_nativePlayer != null) {
      totalMs = _nativePlayer!.durations.fold(0, (a, b) => a + b);
    } else {
      totalMs = _player?.result?.totalDurationMs ?? 0;
    }
    if (totalMs <= 0) totalMs = 0;
    final sec = (totalMs / 1000).toStringAsFixed(1);
    return '时长 $sec s';
  }
}

class _SpeedButton extends StatelessWidget {
  final double speed;
  final ValueChanged<double> onChanged;

  const _SpeedButton({required this.speed, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<double>(
      initialValue: speed,
      tooltip: '播放速度',
      onSelected: onChanged,
      icon: Text(
        '${speed.toStringAsFixed(speed == speed.roundToDouble() ? 0 : 1)}×',
        style:
            const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
      ),
      itemBuilder: (context) => const [
        PopupMenuItem(value: 0.25, child: Text('0.25× 慢速')),
        PopupMenuItem(value: 0.5, child: Text('0.5×')),
        PopupMenuItem(value: 1.0, child: Text('1× 正常')),
        PopupMenuItem(value: 2.0, child: Text('2× 快速')),
        PopupMenuItem(value: 4.0, child: Text('4× 极速')),
      ],
    );
  }
}
