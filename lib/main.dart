import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';

void main() => runApp(const PhotosApp());

class PhotosApp extends StatelessWidget {
  const PhotosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Photos',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xff0a84ff),
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xff0a84ff),
        brightness: Brightness.dark,
      ),
      home: const PhotosHomePage(),
    );
  }
}

enum LibrarySection { library, timeline, albums, favorites }

class PhotoAsset {
  const PhotoAsset({
    required this.path,
    required this.name,
    required this.modifiedAt,
    required this.sizeBytes,
    required this.extension,
    this.width,
    this.height,
    this.favorite = false,
  });

  final String path;
  final String name;
  final DateTime modifiedAt;
  final int sizeBytes;
  final String extension;
  final int? width;
  final int? height;
  final bool favorite;

  String get dayKey {
    final d = modifiedAt;
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  String get albumKey {
    final parent = File(path).parent.path;
    return parent.split(Platform.pathSeparator).last;
  }

  PhotoAsset copyWith({bool? favorite}) {
    return PhotoAsset(
      path: path,
      name: name,
      modifiedAt: modifiedAt,
      sizeBytes: sizeBytes,
      extension: extension,
      width: width,
      height: height,
      favorite: favorite ?? this.favorite,
    );
  }

  factory PhotoAsset.fromJson(Map<String, dynamic> json) {
    final path = json['path'] as String;
    return PhotoAsset(
      path: path,
      name: json['name'] as String? ?? File(path).uri.pathSegments.last,
      modifiedAt:
          DateTime.fromMillisecondsSinceEpoch(json['modified_ms'] as int? ?? 0),
      sizeBytes: json['size_bytes'] as int? ?? 0,
      extension: json['extension'] as String? ?? '',
      width: json['width'] as int?,
      height: json['height'] as int?,
    );
  }
}

typedef _ScanNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _ScanDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

class RustPhotoCore {
  RustPhotoCore._(this._lib)
      : _scan = _lib.lookupFunction<_ScanNative, _ScanDart>('scan_photos_json'),
        _free = _lib.lookupFunction<_FreeNative, _FreeDart>('free_rust_string');

  final DynamicLibrary _lib;
  final _ScanDart _scan;
  final _FreeDart _free;

  static RustPhotoCore? tryLoad() {
    final names = <String>[
      if (Platform.isWindows) 'photos_core.dll',
      if (Platform.isMacOS) 'libphotos_core.dylib',
      if (Platform.isLinux) 'libphotos_core.so',
    ];
    for (final name in names) {
      try {
        return RustPhotoCore._(DynamicLibrary.open(name));
      } catch (_) {}
    }
    return null;
  }

  Future<List<PhotoAsset>> scan(String root) async {
    final input = root.toNativeUtf8();
    Pointer<Utf8> output = nullptr;
    try {
      output = _scan(input);
      if (output == nullptr) return const [];
      final data = jsonDecode(output.toDartString()) as List<dynamic>;
      return data
          .cast<Map<String, dynamic>>()
          .map(PhotoAsset.fromJson)
          .toList(growable: false);
    } finally {
      calloc.free(input);
      if (output != nullptr) _free(output);
    }
  }
}

class PhotoRepository {
  PhotoRepository() : _core = RustPhotoCore.tryLoad();

  final RustPhotoCore? _core;
  bool get usingRust => _core != null;

  Future<List<PhotoAsset>> scan(String root) async {
    final core = _core;
    if (core != null) return core.scan(root);
    return _scanWithDart(root);
  }

  Future<List<PhotoAsset>> _scanWithDart(String root) async {
    final dir = Directory(root);
    if (!await dir.exists()) return const [];
    const allowed = {
      'jpg',
      'jpeg',
      'png',
      'gif',
      'webp',
      'bmp',
      'heic',
      'heif'
    };
    final result = <PhotoAsset>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
      if (!allowed.contains(ext)) continue;
      try {
        final stat = await entity.stat();
        result.add(PhotoAsset(
          path: entity.path,
          name: name,
          modifiedAt: stat.modified,
          sizeBytes: stat.size,
          extension: ext,
        ));
      } catch (_) {}
    }
    result.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return result;
  }
}

class PhotosHomePage extends StatefulWidget {
  const PhotosHomePage({super.key});

  @override
  State<PhotosHomePage> createState() => _PhotosHomePageState();
}

class _PhotosHomePageState extends State<PhotosHomePage> {
  final _repo = PhotoRepository();
  final _folderController = TextEditingController(text: _defaultPicturesPath());
  final _searchController = TextEditingController();

  LibrarySection _section = LibrarySection.library;
  List<PhotoAsset> _photos = [];
  PhotoAsset? _selected;
  bool _loading = false;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    _folderController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final photos = await _repo.scan(_folderController.text.trim());
      setState(() {
        _photos = photos;
        _selected = photos.firstOrNull;
      });
    } catch (error) {
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<PhotoAsset> get _visiblePhotos {
    Iterable<PhotoAsset> items = _photos;
    if (_section == LibrarySection.favorites)
      items = items.where((p) => p.favorite);
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      items = items.where((p) =>
          p.name.toLowerCase().contains(q) ||
          p.albumKey.toLowerCase().contains(q) ||
          p.extension.toLowerCase().contains(q));
    }
    return items.toList(growable: false);
  }

  void _toggleFavorite(PhotoAsset photo) {
    setState(() {
      _photos = [
        for (final item in _photos)
          if (item.path == photo.path)
            item.copyWith(favorite: !item.favorite)
          else
            item,
      ];
      _selected = _photos.where((p) => p.path == photo.path).firstOrNull;
    });
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 980;
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            if (wide)
              SizedBox(
                width: 250,
                child: _Sidebar(
                  section: _section,
                  total: _photos.length,
                  albums: _albumMap(_photos).length,
                  favorites: _photos.where((p) => p.favorite).length,
                  onChanged: (value) => setState(() => _section = value),
                ),
              ),
            Expanded(
              child: Column(
                children: [
                  _TopBar(
                    folderController: _folderController,
                    searchController: _searchController,
                    usingRust: _repo.usingRust,
                    onScan: _scan,
                    onSearch: (value) => setState(() => _query = value),
                  ),
                  if (!wide)
                    _CompactTabs(
                      section: _section,
                      onChanged: (value) => setState(() => _section = value),
                    ),
                  Expanded(child: _content()),
                ],
              ),
            ),
            if (wide)
              SizedBox(
                width: 360,
                child: _Inspector(
                  photo: _selected,
                  onFavorite: _selected == null
                      ? null
                      : () => _toggleFavorite(_selected!),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _content() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null)
      return _EmptyState(title: 'Scan failed', subtitle: _error!);
    if (_photos.isEmpty) {
      return const _EmptyState(
        title: 'No photos found',
        subtitle: 'Enter a folder path, then press Scan.',
      );
    }
    final photos = _visiblePhotos;
    if (_section == LibrarySection.timeline) {
      return _TimelineView(
          photos: photos, onSelect: _select, onOpen: _openViewer);
    }
    if (_section == LibrarySection.albums) {
      return _AlbumsView(
          albums: _albumMap(photos), onSelect: _select, onOpen: _openViewer);
    }
    return _LibraryGrid(
        photos: photos,
        selected: _selected,
        onSelect: _select,
        onOpen: _openViewer);
  }

  void _select(PhotoAsset photo) => setState(() => _selected = photo);

  Future<void> _openViewer(PhotoAsset photo) async {
    _select(photo);
    await Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _PhotoViewer(
        photos: _visiblePhotos,
        initial: photo,
        onFavorite: _toggleFavorite,
      ),
    ));
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.folderController,
    required this.searchController,
    required this.usingRust,
    required this.onScan,
    required this.onSearch,
  });

  final TextEditingController folderController;
  final TextEditingController searchController;
  final bool usingRust;
  final VoidCallback onScan;
  final ValueChanged<String> onSearch;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Column(
        children: [
          Row(
            children: [
              const Text('Photos',
                  style: TextStyle(fontSize: 34, fontWeight: FontWeight.w800)),
              const Spacer(),
              Chip(
                avatar: Icon(usingRust ? Icons.memory : Icons.code, size: 18),
                label: Text(usingRust ? 'Rust core' : 'Dart fallback'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextField(
                  controller: folderController,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.folder_outlined),
                    border: OutlineInputBorder(),
                    labelText: 'Photo folder',
                    isDense: true,
                  ),
                  onSubmitted: (_) => onScan(),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: searchController,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                    labelText: 'Search',
                    isDense: true,
                  ),
                  onChanged: onSearch,
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: onScan,
                icon: const Icon(Icons.sync),
                label: const Text('Scan'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.section,
    required this.total,
    required this.albums,
    required this.favorites,
    required this.onChanged,
  });

  final LibrarySection section;
  final int total;
  final int albums;
  final int favorites;
  final ValueChanged<LibrarySection> onChanged;

  @override
  Widget build(BuildContext context) {
    return NavigationRail(
      extended: true,
      selectedIndex: section.index,
      onDestinationSelected: (index) => onChanged(LibrarySection.values[index]),
      destinations: [
        NavigationRailDestination(
          icon: const Icon(Icons.photo_library_outlined),
          selectedIcon: const Icon(Icons.photo_library),
          label: Text('Library  $total'),
        ),
        const NavigationRailDestination(
          icon: Icon(Icons.calendar_month_outlined),
          selectedIcon: Icon(Icons.calendar_month),
          label: Text('Timeline'),
        ),
        NavigationRailDestination(
          icon: const Icon(Icons.photo_album_outlined),
          selectedIcon: const Icon(Icons.photo_album),
          label: Text('Albums  $albums'),
        ),
        NavigationRailDestination(
          icon: const Icon(Icons.favorite_border),
          selectedIcon: const Icon(Icons.favorite),
          label: Text('Favorites  $favorites'),
        ),
      ],
    );
  }
}

class _CompactTabs extends StatelessWidget {
  const _CompactTabs({required this.section, required this.onChanged});

  final LibrarySection section;
  final ValueChanged<LibrarySection> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: SegmentedButton<LibrarySection>(
        segments: const [
          ButtonSegment(value: LibrarySection.library, label: Text('Library')),
          ButtonSegment(value: LibrarySection.timeline, label: Text('Days')),
          ButtonSegment(value: LibrarySection.albums, label: Text('Albums')),
          ButtonSegment(value: LibrarySection.favorites, label: Text('Favs')),
        ],
        selected: {section},
        onSelectionChanged: (value) => onChanged(value.first),
      ),
    );
  }
}

class _LibraryGrid extends StatelessWidget {
  const _LibraryGrid({
    required this.photos,
    required this.selected,
    required this.onSelect,
    required this.onOpen,
  });

  final List<PhotoAsset> photos;
  final PhotoAsset? selected;
  final ValueChanged<PhotoAsset> onSelect;
  final ValueChanged<PhotoAsset> onOpen;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: _tileSize(MediaQuery.sizeOf(context).width),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
      ),
      itemCount: photos.length,
      itemBuilder: (context, index) {
        final photo = photos[index];
        return _PhotoTile(
          photo: photo,
          selected: selected?.path == photo.path,
          onTap: () => onSelect(photo),
          onDoubleTap: () => onOpen(photo),
        );
      },
    );
  }
}

class _TimelineView extends StatelessWidget {
  const _TimelineView(
      {required this.photos, required this.onSelect, required this.onOpen});

  final List<PhotoAsset> photos;
  final ValueChanged<PhotoAsset> onSelect;
  final ValueChanged<PhotoAsset> onOpen;

  @override
  Widget build(BuildContext context) {
    final grouped = _groupBy(photos, (PhotoAsset p) => p.dayKey);
    return CustomScrollView(
      slivers: [
        for (final entry in grouped.entries) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 22, 18, 8),
              child: Text(entry.key,
                  style: Theme.of(context).textTheme.titleLarge),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 150,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: entry.value.length,
              itemBuilder: (_, index) {
                final photo = entry.value[index];
                return _PhotoTile(
                  photo: photo,
                  selected: false,
                  compact: true,
                  onTap: () => onSelect(photo),
                  onDoubleTap: () => onOpen(photo),
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}

class _AlbumsView extends StatelessWidget {
  const _AlbumsView(
      {required this.albums, required this.onSelect, required this.onOpen});

  final Map<String, List<PhotoAsset>> albums;
  final ValueChanged<PhotoAsset> onSelect;
  final ValueChanged<PhotoAsset> onOpen;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final entry in albums.entries)
          Card(
            clipBehavior: Clip.antiAlias,
            child: ExpansionTile(
              initiallyExpanded: albums.length <= 2,
              title: Text(entry.key,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('${entry.value.length} photos'),
              children: [
                SizedBox(
                  height: 220,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(12),
                    scrollDirection: Axis.horizontal,
                    itemCount: entry.value.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (_, index) {
                      final photo = entry.value[index];
                      return SizedBox(
                        width: 180,
                        child: _PhotoTile(
                          photo: photo,
                          selected: false,
                          onTap: () => onSelect(photo),
                          onDoubleTap: () => onOpen(photo),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({
    required this.photo,
    required this.selected,
    required this.onTap,
    required this.onDoubleTap,
    this.compact = false,
  });

  final PhotoAsset photo;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      child: AnimatedScale(
        duration: const Duration(milliseconds: 160),
        scale: selected ? 0.97 : 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
              width: 3,
            ),
            boxShadow: [
              BoxShadow(
                blurRadius: selected ? 20 : 8,
                color: Colors.black.withOpacity(selected ? 0.22 : 0.10),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(15),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Hero(
                    tag: photo.path,
                    child: _GpuFriendlyImage(path: photo.path)),
                if (!compact)
                  Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _TileLabel(photo: photo)),
                if (photo.favorite)
                  const Positioned(
                      top: 8,
                      right: 8,
                      child: Icon(Icons.favorite, color: Colors.white)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GpuFriendlyImage extends StatelessWidget {
  const _GpuFriendlyImage({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Image.file(
        File(path),
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded || frame != null) return child;
          return const ColoredBox(
            color: Color(0xffd1d1d6),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        },
        errorBuilder: (_, __, ___) => const ColoredBox(
          color: Color(0xff3a3a3c),
          child: Icon(Icons.broken_image_outlined, color: Colors.white54),
        ),
      ),
    );
  }
}

class _TileLabel extends StatelessWidget {
  const _TileLabel({required this.photo});

  final PhotoAsset photo;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black.withOpacity(0.72)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 28, 10, 9),
        child: Text(
          photo.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style:
              const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _Inspector extends StatelessWidget {
  const _Inspector({required this.photo, required this.onFavorite});

  final PhotoAsset? photo;
  final VoidCallback? onFavorite;

  @override
  Widget build(BuildContext context) {
    final p = photo;
    return DecoratedBox(
      decoration: BoxDecoration(
          border:
              Border(left: BorderSide(color: Theme.of(context).dividerColor))),
      child: p == null
          ? const _EmptyState(
              title: 'Select a photo', subtitle: 'Metadata will appear here.')
          : ListView(
              padding: const EdgeInsets.all(18),
              children: [
                AspectRatio(
                  aspectRatio: 1,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: _GpuFriendlyImage(path: p.path),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        p.name,
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                    IconButton.filledTonal(
                      onPressed: onFavorite,
                      icon: Icon(
                          p.favorite ? Icons.favorite : Icons.favorite_border),
                    ),
                  ],
                ),
                _MetaRow(label: 'Album', value: p.albumKey),
                _MetaRow(label: 'Date', value: _formatDate(p.modifiedAt)),
                _MetaRow(label: 'Type', value: p.extension.toUpperCase()),
                _MetaRow(label: 'Size', value: _formatBytes(p.sizeBytes)),
                if (p.width != null && p.height != null)
                  _MetaRow(
                      label: 'Resolution', value: '${p.width} × ${p.height}'),
                const SizedBox(height: 12),
                SelectableText(p.path,
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
    );
  }
}

class _PhotoViewer extends StatefulWidget {
  const _PhotoViewer(
      {required this.photos, required this.initial, required this.onFavorite});

  final List<PhotoAsset> photos;
  final PhotoAsset initial;
  final ValueChanged<PhotoAsset> onFavorite;

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  late final PageController _controller;
  late int _index = math.max(
      0, widget.photos.indexWhere((p) => p.path == widget.initial.path));

  @override
  void initState() {
    super.initState();
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.photos[_index];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(photo.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            onPressed: () => widget.onFavorite(photo),
            icon: Icon(photo.favorite ? Icons.favorite : Icons.favorite_border),
          ),
        ],
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.photos.length,
        onPageChanged: (index) => setState(() => _index = index),
        itemBuilder: (_, index) {
          final item = widget.photos[index];
          return InteractiveViewer(
            minScale: 0.8,
            maxScale: 5,
            child: Center(
              child: Hero(
                tag: item.path,
                child: Image.file(File(item.path), fit: BoxFit.contain),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
              width: 92,
              child: Text(label,
                  style: TextStyle(color: Theme.of(context).hintColor))),
          Expanded(child: Text(value, textAlign: TextAlign.right)),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.photo_library_outlined, size: 64),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(subtitle, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

Map<String, List<PhotoAsset>> _albumMap(List<PhotoAsset> photos) =>
    _groupBy(photos, (p) => p.albumKey);

Map<K, List<T>> _groupBy<T, K>(Iterable<T> items, K Function(T) keyOf) {
  final map = <K, List<T>>{};
  for (final item in items) {
    map.putIfAbsent(keyOf(item), () => []).add(item);
  }
  return map;
}

double _tileSize(double width) {
  if (width > 1600) return 190;
  if (width > 1100) return 170;
  if (width > 700) return 150;
  return 120;
}

String _defaultPicturesPath() {
  final home = Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      '.';
  final pictures = Directory('$home${Platform.pathSeparator}Pictures');
  return pictures.existsSync() ? pictures.path : home;
}

String _formatDate(DateTime d) {
  return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

String _formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  return '${size.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}
