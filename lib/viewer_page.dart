import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
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

class _ViewerPageState extends State<ViewerPage> {
  Future<ApngDecodeResult>? _future;
  ApngPlayer? _player;
  bool _fullscreen = false;
  double _speed = 1.0;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<ApngDecodeResult> _load() async {
    final bytes = await File(widget.path).readAsBytes();
    final result = ApngDecoder.decode(bytes, filePath: widget.path);
    if (result == null) {
      throw Exception('decode failed');
    }
    if (mounted) {
      _player?.dispose();
      _player = ApngPlayer(result);
    }
    return result;
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
              title: Text(
                widget.fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.fullscreen),
                  tooltip: '全屏',
                  onPressed: () => setState(() => _fullscreen = true),
                ),
              ],
            ),
      body: FutureBuilder<ApngDecodeResult>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
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

          final result = snapshot.data!;
          // 播放器尚未初始化（首次加载时 _load 异步完成）
          if (_player == null) {
            return const Center(child: CircularProgressIndicator());
          }

          // 启动播放（仅动画时）
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (result.isAnimated && !_player!.playing) {
              _player!.play();
            }
          });

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
      // 静态大图：支持双指缩放
      return PhotoView(
        imageProvider: MemoryImage(getFirstFrameBytes(result)),
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        minScale: PhotoViewComputedScale.contained,
        maxScale: PhotoViewComputedScale.covered * 4,
        heroAttributes: const PhotoViewHeroAttributes(tag: 'apng-view'),
      );
    }

    // 动画：显示当前帧（跟随播放器）
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
              rgbaBytes: f.rgbaBytes,
              width: f.width,
              height: f.height,
            ),
          ),
        );
      },
    );
  }

  Uint8List getFirstFrameBytes(ApngDecodeResult result) {
    // 使用第一帧的 RGBA 构造 PNG 工具图片（MemImage 可接受原始字节）
    // 这里直接复用第一帧的原始 APNG 文件字节更简单——但已被整体解码，
    // 因此从 result 第一帧构造缓存图片。
    final f = result.frames.first;
    // 用 image 包重新编码为 PNG 以便 MemoryImage 解码
    img.Image im = img.Image.fromBytes(
      width: f.width,
      height: f.height,
      bytes: f.rgbaBytes.buffer,
      numChannels: 4,
    );
    final png = img.encodePng(im);
    return png;
  }

  Widget _buildControlBar(ApngDecodeResult result) {
    // 动画控制栏
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
                  // 进度条
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
                            value: _player!.currentFrame.toDouble(),
                            max: (_player!.frameCount - 1).toDouble(),
                            onChanged: (v) => _player!.gotoFrame(v.round()),
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
                      // 速度控制
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
                    Text(
                      '${result.width}×${result.height}',
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    Text(
                      '${result.frames.length} 帧',
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    if (result.isAnimated)
                      Text(
                        _formatDuration(result),
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12),
                      ),
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
    final totalMs =
        result.frames.fold<int>(0, (sum, f) => sum + f.durationMs);
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
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
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