import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'convert_page.dart';
import 'platform_file_gateway.dart';
import 'viewer_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ApngViewerApp());
}

class ApngViewerApp extends StatefulWidget {
  const ApngViewerApp({super.key});

  @override
  State<ApngViewerApp> createState() => _ApngViewerAppState();
}

class _ApngViewerAppState extends State<ApngViewerApp> {
  ThemeMode _themeMode = ThemeMode.system;
  static const _themeKey = 'theme_mode';

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_themeKey);
      if (!mounted) return;
      setState(() {
        _themeMode = switch (stored) {
          'dark' => ThemeMode.dark,
          'light' => ThemeMode.light,
          _ => ThemeMode.system,
        };
      });
    } catch (_) {}
  }

  Future<void> _setThemeMode(ThemeMode mode) async {
    setState(() => _themeMode = mode);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_themeKey, mode.name);
    } catch (_) {}
  }

  ThemeData _buildTheme(Brightness brightness) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF4FC3F7),
        brightness: brightness,
      ),
      scaffoldBackgroundColor: brightness == Brightness.light
          ? const Color(0xFFF5F7FA)
          : const Color(0xFF121212),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'APNG 阅览器',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      themeMode: _themeMode,
      home: HomePage(
        themeMode: _themeMode,
        onThemeModeChanged: _setThemeMode,
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  const HomePage({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final List<Map<String, String>> _recentFiles = [];
  final bool _loading = false;
  MethodChannel? _intentChannel;

  static const _prefsKey = 'recent_apng_files';

  Future<void> _showSaveModeSheet(BuildContext context) async {
    final current = await FileGateway.loadSaveMode();
    if (!mounted) return;
    final mode = await showModalBottomSheet<SaveMode>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              leading: Icon(Icons.save_alt),
              title: Text('保存方式'),
              subtitle: Text('选择后点击保存不再弹位置选择'),
            ),
            RadioListTile<SaveMode>(
              value: SaveMode.dialog,
              groupValue: current,
              title: const Text('系统对话框（默认）'),
              onChanged: (v) => Navigator.pop(c, v),
            ),
            RadioListTile<SaveMode>(
              value: SaveMode.folder,
              groupValue: current,
              title: const Text('默认文件夹 APNG_Exporter'),
              subtitle: Text(Platform.isAndroid
                  ? '相册 → Pictures/APNG_Exporter'
                  : '「文件」App → 我的 iPad 可见'),
              onChanged: (v) => Navigator.pop(c, v),
            ),
            RadioListTile<SaveMode>(
              value: SaveMode.album,
              groupValue: current,
              title: const Text('保存到相册'),
              onChanged: (v) => Navigator.pop(c, v),
            ),
          ],
        ),
      ),
    );
    if (mode == null || !mounted) return;
    setState(() {});
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('save_mode', mode.name);
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _intentChannel =
        const MethodChannel('com.apngviewer.apng_viewer/intent');
    _loadPrefs();
    _checkIntent();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkIntent();
    }
  }

  /// 检查外部通过文件管理器打开 APNG（Android intent / iOS Filza "Open in"）
  Future<void> _checkIntent() async {
    try {
      final path = await _intentChannel!.invokeMethod<String>('getPendingFile');
      if (path != null && path.isNotEmpty && File(path).existsSync()) {
        _openFile(path);
      }
    } catch (e) {
      // ignore
    }
  }

  /// 将文件加入最近浏览记录（去重置顶，最多保留 20 条）
  Future<void> _addRecent(String path) async {
    final name = path.split('/').last;
    _recentFiles.removeWhere((f) => f['path'] == path);
    _recentFiles.insert(0, {'path': path, 'name': name});
    if (_recentFiles.length > 20) {
      _recentFiles.removeRange(20, _recentFiles.length);
    }
    if (mounted) setState(() {});
    await _savePrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final recent = prefs.getStringList(_prefsKey) ?? [];
    if (!mounted) return;
    setState(() {
      _recentFiles.clear();
      for (final line in recent) {
        final parts = line.split('|');
        if (parts.length == 2) {
          _recentFiles.add({'path': parts[0], 'name': parts[1]});
        }
      }
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final lines =
        _recentFiles.map((f) => '${f['path']}|${f['name']}').toList();
    await prefs.setStringList(_prefsKey, lines);
  }

  Future<void> _pickAndOpen() async {
    try {
      final path = await FileGateway.pickApngFile();
      if (path != null && path.isNotEmpty && File(path).existsSync()) {
        _openFile(path);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法打开文件选择器: $e')),
      );
    }
  }

  /// 从「文件」App 选择原始 .apng/.png 文件打开
  /// （iOS 相册会转码 APNG 丢动画，走文件选择器才能保真）
  Future<void> _pickAndOpenFiles() async {
    try {
      final path = await FileGateway.pickApngFileFromFiles();
      if (path != null && path.isNotEmpty && File(path).existsSync()) {
        _openFile(path);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法打开文件选择器: $e')),
      );
    }
  }

  Future<void> _openFile(String path) async {
    // 直接跳转查看器，由 ViewerPage 后台 isolate 解码（避免主线程卡顿/闪退）
    final fileName = path.split('/').last;
    await _addRecent(path); // 记录最近浏览（去重置顶）
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ViewerPage(path: path, fileName: fileName),
      ),
    );
  }

  /// 清空最近浏览记录，并同时清除 Android 端复制产生的缓存图片
  /// （只清本应用缓存目录，绝不影响源文件）
  void _clearRecent() {
    setState(() => _recentFiles.clear());
    _savePrefs();
    FileGateway.clearPendingCache();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = widget.themeMode == ThemeMode.dark ||
        (widget.themeMode == ThemeMode.system &&
            MediaQuery.platformBrightnessOf(context) == Brightness.dark);

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.animation, color: Color(0xFF4FC3F7)),
            SizedBox(width: 10),
            Text('APNG 阅览器',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.save_outlined),
            tooltip: '保存方式',
            onPressed: () => _showSaveModeSheet(context),
          ),
          IconButton(
            icon: Icon(isDark ? Icons.light_mode : Icons.dark_mode),
            tooltip: isDark ? '切换到浅色模式' : '切换到深色模式',
            onPressed: () {
              widget.onThemeModeChanged(
                isDark ? ThemeMode.light : ThemeMode.dark,
              );
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              _buildHeroCard(theme),
              if (_recentFiles.isNotEmpty) _buildRecentHeader(),
              Expanded(
                child: _recentFiles.isEmpty
                    ? _buildEmptyState(theme)
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        itemCount: _recentFiles.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final f = _recentFiles[index];
                          return _buildRecentTile(f, index);
                        },
                      ),
              ),
            ],
          ),
          if (_loading)
            Container(
              color: Colors.black.withValues(alpha: 0.3),
              child: const Center(
                child: CircularProgressIndicator(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHeroCard(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF4FC3F7), Color(0xFF29B6F6)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF29B6F6).withValues(alpha: 0.35),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'APNG 动画图片阅览器',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '支持 APNG 动画逐帧播放、预览大图缩放、图片与 APNG 互转',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.9)),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: _HomeActionButton(
                  icon: Icons.photo_library,
                  label: '阅览图片',
                  onTap: _pickAndOpen,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _HomeActionButton(
                  icon: Icons.folder_open,
                  label: '文件打开',
                  onTap: _pickAndOpenFiles,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _HomeActionButton(
                  icon: Icons.swap_horiz,
                  label: '图片互转',
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const ConvertPage()),
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRecentHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      child: Row(
        children: [
          const Expanded(
            child: Text('最近浏览',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          TextButton.icon(
            onPressed: _clearRecent,
            icon: const Icon(Icons.delete_sweep, size: 18),
            label: const Text('清空'),
          ),
        ],
      ),
    );
  }

  Widget _buildRecentTile(Map<String, String> f, int index) {
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.withValues(alpha: 0.15)),
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: const Color(0xFF4FC3F7).withValues(alpha: 0.15),
          child: const Icon(Icons.image, color: Color(0xFF0288D1)),
        ),
        title: Text(
          f['name'] ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          f['path'] ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          final path = f['path'];
          if (path != null && File(path).existsSync()) {
            _openFile(path);
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('文件已不存在')),
            );
          }
        },
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.image_search,
              size: 96, color: theme.colorScheme.primary.withValues(alpha: 0.4)),
          const SizedBox(height: 16),
          const Text('还没有浏览记录'),
          const SizedBox(height: 8),
          Text(
            '点击上方按钮选择 APNG 图片开始浏览',
            style: TextStyle(color: theme.hintColor),
          ),
        ],
      ),
    );
  }
}

/// 主页三按钮：纯白底 + 无状态层黑边（自绘，不用 FilledButton，
/// 彻底绕开 iOS 上 Material 状态覆盖层的黑底问题）
class _HomeActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _HomeActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 24, color: const Color(0xFF0288D1)),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF0288D1)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
