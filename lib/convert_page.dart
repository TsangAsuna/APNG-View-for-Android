import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'apng/apng_converter.dart';
import 'apng/apng_decoder.dart';
import 'apng/apng_encoder.dart';
import 'apng/apng_frame_view.dart';
import 'apng/apng_player.dart';
import 'platform_file_gateway.dart';

/// 后台 isolate 解码入口
List<DecodedImage> _decodeImagesWorker(List<String> paths) {
  final out = <DecodedImage>[];
  for (final p in paths) {
    final d = ApngConverter.decodeImageFileSync(p);
    if (d != null) out.add(d);
  }
  return out;
}

/// 后台 isolate 解码 APNG（大文件不阻塞 UI）
Future<ApngDecodeResult?> _decodeApngWorker(String path) async {
  try {
    final bytes = await File(path).readAsBytes();
    // 并行解码：大 APNG 多 isolate 同时解压+压缩，速度更快
    return await ApngDecoder.decodeAsync(bytes, filePath: path);
  } catch (_) {
    return null;
  }
}

/// 后台 isolate 编码 APNG（多张大图编码耗时，避免卡 UI）
Uint8List? _encodeApngWorker(List<Object> args) {
  try {
    final raw = args[0] as List<dynamic>;
    final frames = raw.cast<Uint8List>();
    final width = args[1] as int;
    final height = args[2] as int;
    final delay = args[3] as int;
    final loop = args[4] as int;
    // args[5]/args[6]: 每帧实际宽高（尺寸不一也能编码，不会失败）
    final frameWidths = (args.length > 5 ? args[5] as List : const <int>[])
        .cast<int>();
    final frameHeights = (args.length > 6 ? args[6] as List : const <int>[])
        .cast<int>();
    return ApngEncoder.encode(
      frames: frames,
      width: width,
      height: height,
      frameWidths: frameWidths,
      frameHeights: frameHeights,
      frameDurationsMs: List.filled(frames.length, delay),
      loopCount: loop,
    );
  } catch (_) {
    return null;
  }
}

/// 转换功能页：图片 -> APNG / APNG -> 图片
class ConvertPage extends StatefulWidget {
  const ConvertPage({super.key});

  @override
  State<ConvertPage> createState() => _ConvertPageState();
}

class _ConvertPageState extends State<ConvertPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  // 图片 -> APNG
  final List<DecodedImage> _srcImages = [];
  bool _converting = false;
  int _frameDelay = 100;
  int _loopCount = 0;
  Uint8List? _generatedApng;
  ApngPlayer? _previewPlayer;

  // APNG -> 图片
  ApngDecodeResult? _apngResult;
  String? _apngName;
  ApngPlayer? _apngPlayer;

  // 导出目录开关
  bool _useCustomDir = false;
  String? _customDirName;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    _previewPlayer?.dispose();
    _apngPlayer?.dispose();
    super.dispose();
  }

  // ==================== 图片 -> APNG ====================

  Future<void> _pickImages() async {
    try {
      final result = await FileGateway.pickImages();
      if (result == null || result.isEmpty) return;
      setState(() => _converting = true);
      // 后台 isolate 解码，进度条不卡顿
      final images = await compute(
          _decodeImagesWorker, result.toList());
      if (!mounted) return;
      setState(() {
        _srcImages
          ..clear()
          ..addAll(images);
        _generatedApng = null;
        _previewPlayer?.dispose();
        _previewPlayer = null;
        _converting = false;
      });
      if (images.isNotEmpty && images.length > 1) {
        _generateApng();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _converting = false);
      _snack('选择图片失败: $e');
    }
  }

  /// 移除单个图片
  void _removeImageAt(int index) {
    if (index < 0 || index >= _srcImages.length) return;
    setState(() {
      _srcImages.removeAt(index);
      _generatedApng = null;
      _previewPlayer?.dispose();
      _previewPlayer = null;
    });
    _snack('已移除第 ${index + 1} 张图片');
    if (_srcImages.length > 1) {
      _generateApng();
    }
  }

  /// 全部取消
  void _removeAllImages() {
    if (_srcImages.isEmpty) return;
    showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('全部取消'),
        content: Text('确定移除已选的 ${_srcImages.length} 张图片吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('保留'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(c).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('全部取消'),
          ),
        ],
      ),
    ).then((ok) {
      if (ok == true && mounted) {
        setState(() {
          _srcImages.clear();
          _generatedApng = null;
          _previewPlayer?.dispose();
          _previewPlayer = null;
        });
        _snack('已全部取消');
      }
    });
  }

  Future<void> _generateApng() async {
    if (_srcImages.isEmpty) return;
    setState(() => _converting = true);
    // 让编码转圈先渲染出来，避免同步编码时界面无反馈
    await Future.delayed(const Duration(milliseconds: 2));
    final apng = await compute(_encodeApngWorker, <Object>[
      _srcImages.map((e) => e.rgbaBytes).toList(),
      _srcImages.first.width,
      _srcImages.first.height,
      _frameDelay,
      _loopCount,
      _srcImages.map((e) => e.width).toList(),
      _srcImages.map((e) => e.height).toList(),
    ]);
    if (!mounted) return;
    setState(() {
      _converting = false;
      if (apng != null) {
        _generatedApng = apng;
        final result = ApngDecoder.decode(apng);
        _previewPlayer?.dispose();
        _previewPlayer = result != null ? ApngPlayer(result) : null;
      } else {
        _snack('APNG 编码失败');
      }
    });
  }

  void _togglePreview() {
    final p = _previewPlayer;
    if (p == null) return;
    if (p.playing) {
      p.pause();
    } else {
      p.play();
    }
  }

  /// 点击图片弹出小预览（防止选错）
  void _showImagePreview(DecodedImage d) {
    showDialog<void>(
      context: context,
      builder: (c) => Dialog(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            InteractiveViewer(
              maxScale: 6,
              child: Center(
                child: Image.memory(
                  d.thumbnailPng(maxDim: 800),
                  fit: BoxFit.contain,
                ),
              ),
            ),
            Positioned(
              left: 8,
              top: 8,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  d.sourceName,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
            Positioned(
              right: 4,
              top: 4,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(c),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== APNG -> 图片 ====================

  Future<void> _pickApng() async {
    try {
      final path = await FileGateway.pickApngFile();
      if (path == null || path.isEmpty || !File(path).existsSync()) {
        _snack('未选择文件');
        return;
      }
      final result = await _decodeApngWorker(path);
      if (result == null) {
        _snack('无法解码该文件');
        return;
      }
      if (!mounted) return;
      setState(() {
        _apngResult = result;
        _apngName = path.split('/').last;
        _apngPlayer?.dispose();
        _apngPlayer = ApngPlayer(result);
      });
    } catch (e) {
      _snack('打开失败: $e');
    }
  }

  // ==================== 导出目录 ====================

  Future<void> _chooseCustomDir() async {
    try {
      final name = await FileGateway.pickExportDirectory();
      if (name != null && name.isNotEmpty) {
        setState(() {
          _customDirName = name;
        });
      }
    } catch (_) {}
  }

  Future<bool> _writeFile({
    required String fileName,
    required String mime,
    required Uint8List data,
  }) async {
    if (_useCustomDir) {
      return FileGateway.writeExport(
        fileName: fileName, mime: mime, data: data,
        useCustomDir: true,
      );
    }
    return FileGateway.writeExportSmart(
      fileName: fileName, mime: mime, data: data,
    );
  }

  Future<void> _exportApng() async {
    final data = _generatedApng;
    if (data == null) {
      _snack('请先生成 APNG');
      return;
    }
    if (_useCustomDir && _customDirName == null) {
      _snack('请先选择导出目录');
      return;
    }
    setState(() => _converting = true);
    try {
      final base = _srcImages.first.sourceName;
      final name = '${base.substring(0, base.lastIndexOf('.'))}_apng.apng';
      final ok = await _writeFile(
        fileName: name,
        mime: 'image/apng',
        data: data,
      );
      if (!mounted) return;
      if (ok) _snack('APNG 已导出: $name');
    } catch (e) {
      if (mounted) _snack('导出失败: $e');
    } finally {
      // 取消保存弹窗/异常都要复位，否则按钮永远转圈
      if (mounted) setState(() => _converting = false);
    }
  }

  Future<void> _exportFrames() async {
    final result = _apngResult;
    if (result == null) {
      _snack('请先打开 APNG');
      return;
    }
    if (_useCustomDir && _customDirName == null) {
      _snack('请先选择导出目录');
      return;
    }

    if (_useCustomDir) {
      setState(() => _converting = true);
      try {
        var count = 0;
        for (var i = 0; i < result.frames.length; i++) {
          // 解码时已生成 PNG 压缩字节，直接复用，无需重复编码
          final ok = await FileGateway.writeExport(
            fileName: '${_baseName()}_frame_${i + 1}.png',
            mime: 'image/png',
            data: result.frames[i].pngBytes,
            useCustomDir: true,
          );
          if (ok) count++;
        }
        if (!mounted) return;
        _snack('已导出 $count/${result.frames.length} 帧到所选目录');
      } catch (e) {
        if (mounted) _snack('导出失败: $e');
      } finally {
        // 取消保存弹窗/异常都要复位
        if (mounted) setState(() => _converting = false);
      }
    } else {
      if (result.frames.length > 1) {
        final go = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('导出帧序列'),
            content: Text(
                '共 ${result.frames.length} 帧，将逐个弹出系统保存对话框。\n建议开启“自定义目录”开关批量导出。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('继续'),
              ),
            ],
          ),
        );
        if (go != true) return;
      }
      setState(() => _converting = true);
      try {
        var count = 0;
        for (var i = 0; i < result.frames.length; i++) {
          final ok = await _writeFile(
            fileName: '${_baseName()}_frame_${i + 1}.png',
            mime: 'image/png',
            data: result.frames[i].pngBytes,
          );
          if (ok) count++;
        }
        if (!mounted) return;
        _snack('已导出 $count/${result.frames.length} 帧');
      } catch (e) {
        if (mounted) _snack('导出失败: $e');
      } finally {
        // 取消保存弹窗/异常都要复位
        if (mounted) setState(() => _converting = false);
      }
    }
  }

  String _baseName() {
    final n = _apngName ?? 'apng';
    final dot = n.lastIndexOf('.');
    return dot > 0 ? n.substring(0, dot) : n;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('图片 <-> APNG'),
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: '图片转 APNG', icon: Icon(Icons.animation)),
            Tab(text: 'APNG 转图片', icon: Icon(Icons.photo_library)),
          ],
        ),
      ),
      body: Stack(
        children: [
          TabBarView(
            controller: _tab,
            children: [_buildImagesToApng(), _buildApngToImages()],
          ),
          if (_converting)
            Container(
              color: Colors.black.withValues(alpha: 0.35),
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  // ---------- Tab1: 图片 -> APNG ----------
  Widget _buildImagesToApng() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildCustomDirCard(),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text('选择图片生成 APNG 动画',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                    ),
                    FilledButton.icon(
                      onPressed: _pickImages,
                      icon: const Icon(Icons.add_photo_alternate, size: 18),
                      label: const Text('选择图片'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_srcImages.isEmpty)
                  Text('可多选 PNG / JPG / WebP / GIF / BMP 图片',
                      style: TextStyle(color: Theme.of(context).hintColor))
                else
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '已选 ${_srcImages.length} 张 · 点击预览 · 长按移除',
                          style:
                              TextStyle(color: Theme.of(context).hintColor),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _removeAllImages,
                        icon: const Icon(Icons.clear_all, size: 16),
                        label: const Text('全部取消'),
                      ),
                    ],
                  ),
                if (_srcImages.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  // 多行网格显示
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 110,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1,
                    ),
                    itemCount: _srcImages.length,
                    itemBuilder: (_, i) => _SelectableImageTile(
                      image: _srcImages[i],
                      index: i,
                      onTap: () => _showImagePreview(_srcImages[i]),
                      onRemove: () => _removeImageAt(i),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildFrameDelaySlider(),
                  const SizedBox(height: 8),
                  _buildLoopCountSelector(),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed:
                              _srcImages.length > 1 ? _generateApng : null,
                          icon: const Icon(Icons.auto_fix_high),
                          label: const Text('生成 APNG'),
                        ),
                      ),
                    ],
                  ),
                  if (_generatedApng != null && _previewPlayer != null) ...[
                    const SizedBox(height: 16),
                    _buildPreviewSection(),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _exportApng,
                            icon: const Icon(Icons.save_alt),
                            label: const Text('导出 APNG'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPreviewSection() {
    final p = _previewPlayer!;
    return Column(
      children: [
        Container(
          height: 220,
          width: double.infinity,
          color: Colors.black,
          child: AnimatedBuilder(
            animation: p,
            builder: (_, _) {
              final f = p.currentFrameData;
              if (f == null) return const SizedBox.shrink();
              return ApngFrameView(
                pngBytes: f.pngBytes,
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.skip_previous),
              onPressed: () => p.prevFrame(),
            ),
            IconButton(
              iconSize: 40,
              icon: Icon(
                p.playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
                color: Theme.of(context).colorScheme.primary,
              ),
              onPressed: _togglePreview,
            ),
            IconButton(
              icon: const Icon(Icons.skip_next),
              onPressed: () => p.nextFrame(),
            ),
          ],
        ),
        AnimatedBuilder(
          animation: p,
          builder: (_, _) => Text(
            '${p.currentFrame + 1} / ${p.frameCount}',
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget _buildFrameDelaySlider() {
    return Row(
      children: [
        const Text('帧延时'),
        Expanded(
          child: Slider(
            value: _frameDelay.toDouble(),
            min: 20,
            max: 1000,
            divisions: 49,
            label: '${_frameDelay}ms',
            onChanged: (v) {
              // 拖动过程只更新显示值，不重新编码
              setState(() => _frameDelay = v.round());
            },
            onChangeEnd: (v) {
              // 松手后再重新生成，避免拖动时反复触发重编码
              setState(() => _frameDelay = v.round());
              if (_srcImages.length > 1) _generateApng();
            },
          ),
        ),
        SizedBox(
          width: 60,
          child: Text('${_frameDelay}ms',
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }

  Widget _buildLoopCountSelector() {
    return Row(
      children: [
        const Text('循环次数'),
        const SizedBox(width: 12),
        ChoiceChip(
          label: const Text('无限'),
          selected: _loopCount == 0,
          onSelected: (_) => setState(() {
            _loopCount = 0;
            if (_srcImages.length > 1) _generateApng();
          }),
        ),
        const SizedBox(width: 8),
        ChoiceChip(
          label: const Text('1次'),
          selected: _loopCount == 1,
          onSelected: (_) => setState(() {
            _loopCount = 1;
            if (_srcImages.length > 1) _generateApng();
          }),
        ),
        const SizedBox(width: 8),
        ChoiceChip(
          label: const Text('3次'),
          selected: _loopCount == 3,
          onSelected: (_) => setState(() {
            _loopCount = 3;
            if (_srcImages.length > 1) _generateApng();
          }),
        ),
      ],
    );
  }

  // ---------- Tab2: APNG -> 图片 ----------
  Widget _buildApngToImages() {
    final result = _apngResult;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildCustomDirCard(),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text('从 APNG 提取各帧图片',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                    ),
                    FilledButton.icon(
                      onPressed: _pickApng,
                      icon: const Icon(Icons.file_open, size: 18),
                      label: const Text('打开 APNG'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (result == null)
                  Text('选择一个 APNG 动画，提取其中的每一帧为 PNG 图片',
                      style: TextStyle(color: Theme.of(context).hintColor))
                else ...[
                  Text(
                    '$_apngName · ${result.width}×${result.height} · ${result.frames.length} 帧',
                    style: TextStyle(color: Theme.of(context).hintColor),
                  ),
                  const SizedBox(height: 12),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                    ),
                    itemCount: result.frames.length,
                    itemBuilder: (_, i) {
                      final f = result.frames[i];
                      return Column(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: ApngFrameView(
                                pngBytes: f.pngBytes,
                              ),
                            ),
                          ),
                          Text('第${i + 1}帧',
                              style: const TextStyle(fontSize: 11)),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _exportFrames,
                          icon: const Icon(Icons.save_alt),
                          label: Text('导出 ${result.frames.length} 帧'),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ---------- 自定义目录开关（共用） ----------
  Widget _buildCustomDirCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Column(
          children: [
            SwitchListTile(
              title: const Text('自定义导出目录'),
              subtitle: Text(
                _useCustomDir
                    ? (_customDirName ?? '未选择目录，点击右侧选择')
                    : '关闭：导出时使用系统保存对话框逐个选择位置',
                style: const TextStyle(fontSize: 12),
              ),
              value: _useCustomDir,
              onChanged: (v) {
                setState(() {
                  _useCustomDir = v;
                  if (v && _customDirName == null) {
                    _chooseCustomDir();
                  }
                });
              },
            ),
            if (_useCustomDir)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _chooseCustomDir,
                  icon: const Icon(Icons.folder, size: 16),
                  label: const Text('重新选择目录'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 可选中的图片项：
///  - 单击：小预览（防止选错）
///  - 长按：带过渡动画显示移除按钮，再点移除
class _SelectableImageTile extends StatefulWidget {
  final DecodedImage image;
  final int index;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _SelectableImageTile({
    required this.image,
    required this.index,
    required this.onTap,
    required this.onRemove,
  });

  @override
  State<_SelectableImageTile> createState() => _SelectableImageTileState();
}

class _SelectableImageTileState extends State<_SelectableImageTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _removeBtnCtrl;
  late final Animation<double> _removeBtnScale;
  late final Animation<double> _removeBtnOpacity;

  late final AnimationController _removeAnimCtrl;
  late final Animation<double> _removeScale;
  late final Animation<double> _removeOpacity;

  bool _showingRemove = false;
  bool _removing = false;

  @override
  void initState() {
    super.initState();
    _removeBtnCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _removeBtnScale = CurvedAnimation(
      parent: _removeBtnCtrl,
      curve: Curves.easeOutBack,
    );
    _removeBtnOpacity =
        CurvedAnimation(parent: _removeBtnCtrl, curve: Curves.easeInOut);

    _removeAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _removeScale = Tween(begin: 1.0, end: 0.4).animate(
      CurvedAnimation(parent: _removeAnimCtrl, curve: Curves.easeIn),
    );
    _removeOpacity = Tween(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _removeAnimCtrl, curve: Curves.easeIn),
    );
  }

  @override
  void dispose() {
    _removeBtnCtrl.dispose();
    _removeAnimCtrl.dispose();
    super.dispose();
  }

  /// 长按：出现移除按钮（带弹性动画）
  void _onLongPress() {
    if (_removing) return;
    setState(() => _showingRemove = true);
    _removeBtnCtrl.forward(from: 0);
  }

  /// 隐藏移除按钮
  void _hideRemove() {
    if (!_showingRemove || _removing) return;
    _removeBtnCtrl.reverse();
    setState(() => _showingRemove = false);
  }

  /// 确认移除（带消失过渡动画）
  void _confirmRemove() {
    showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('移除图片'),
        content: Text('确定移除第 ${widget.index + 1} 张图片吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(c).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('移除'),
          ),
        ],
      ),
    ).then((ok) {
      if (ok == true && mounted) {
        setState(() => _removing = true);
        _removeAnimCtrl.forward().then((_) {
          if (mounted) widget.onRemove();
        });
      } else {
        _hideRemove();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _showingRemove ? _hideRemove : widget.onTap,
      onLongPress: _onLongPress,
      onTapCancel: _showingRemove ? _hideRemove : null,
      child: AnimatedBuilder(
        animation: _removeAnimCtrl,
        builder: (_, child) {
          return Opacity(
            opacity: _removeOpacity.value,
            child: Transform.scale(scale: _removeScale.value, child: child),
          );
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 缩略图
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(
                widget.image.thumbnailPng(),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(
                  color: Colors.grey.shade300,
                  child: const Icon(Icons.broken_image),
                ),
              ),
            ),
            // 帧序号徽标
            Positioned(
              left: 4,
              top: 4,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF4FC3F7).withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${widget.index + 1}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            // 长按后才显示的移除按钮（带过渡动画）
            if (_showingRemove)
              Positioned(
                right: 2,
                top: 2,
                child: FadeTransition(
                  opacity: _removeBtnOpacity,
                  child: ScaleTransition(
                  scale: _removeBtnScale,
                  child: GestureDetector(
                    onTap: _confirmRemove,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.65),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close,
                        size: 16,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
              ),
          ],
        ),
      ),
    );
  }
}
