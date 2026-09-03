import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';

import 'apng/apng_decoder.dart';
import 'apng/apng_player.dart';
import 'apng/apng_frame_view.dart';

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

/// 后台 isolate 解码入口：大 APNG 不阻塞 UI 线程
ApngDecodeResult? _decodeWorker(List<Object> args) {
  final path = args[0] as String;
  try {
    final bytes = File(path).readAsBytesSync();
    return ApngDecoder.decode(bytes, filePath: path);
  } catch (_) {
    return null;
  }
}

class _ViewerPageState extends State<ViewerPage> {
  Future<ApngDecodeResult?>? _future;
  ApngPlayer? _player;
  bool _fullscreen = false;
  double _speed = 1.0;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<ApngDecodeResult?> _load() async {
    // 后台 isolate 解码，避免大 APNG 阻塞 UI
    return await compute(_decodeWorker, <Object>[widget.path]);
  }

  @override
  void dispose() {
    _player?.dispose();
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
            return const Center(child: CircularProgressIndicator());
          }
          final result = snapshot.data;
          if (result == null) {
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
            _player = ApngPlayer(result);
            if (result.isAnimated) {
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

  Widget _buildViewer(ApngDecodeResult result) {
    if (!result.isAnimated) {
      // 第一帧已经是压缩后的 PNG 字节，直接交给引擎解码，
      // 避免在 UI 线程同步 encodePng 卡死界面（大图时尤为严重）
      return PhotoView(
        imageProvider: MemoryImage(result.frames.first.pngBytes),
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
              pngBytes: f.pngBytes,
            ),
          ),
        );
      },
    );
  }

  Widget _buildControlBar(ApngDecodeResult result) {
    return AnimatedBuilder(
      animation: _player!,
      builder: (context, _) {
        final isAnimated = result.isAnimated;
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
                      '静态图片 · ${result.width}×${result.height} · 双指缩放预览',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Text('${result.width}×${result.height}',
                        style:
                            const TextStyle(color: Colors.white54, fontSize: 12)),
                    Text('${result.frames.length} 帧',
                        style:
                            const TextStyle(color: Colors.white54, fontSize: 12)),
                    if (result.isAnimated)
                      Text(_formatDuration(result),
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

  String _formatDuration(ApngDecodeResult result) {
    final totalMs = result.totalDurationMs;
    final sec = (totalMs / 1000).toStringAsFixed(1);
    return '时长 ${sec}s';
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
