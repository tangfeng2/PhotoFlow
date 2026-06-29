import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    this.albumName,
    this.favorite = false,
  });

  final String path;
  final String name;
  final DateTime modifiedAt;
  final int sizeBytes;
  final String extension;
  final int? width;
  final int? height;
  final String? albumName;
  final bool favorite;

  String get dayKey {
    final d = modifiedAt;
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  String get albumKey {
    final album = albumName?.trim();
    if (album != null && album.isNotEmpty) return album;
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
      albumName: albumName,
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
      albumName: json['album'] as String?,
    );
  }
}

class AndroidPhotoBridge {
  AndroidPhotoBridge._();

  static const _channel = MethodChannel('photos_app/android_photos');

  static Future<List<PhotoAsset>> scanPhotos() async {
    final data = await _channel.invokeListMethod<Map<dynamic, dynamic>>(
      'scanPhotos',
    );
    return (data ?? const <Map<dynamic, dynamic>>[])
        .map((item) => PhotoAsset.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  static Future<Uint8List> readImageBytes(String uri) async {
    final bytes = await _channel.invokeMethod<Uint8List>(
      'readImageBytes',
      {'uri': uri},
    );
    if (bytes == null) {
      throw StateError('Android returned no image bytes.');
    }
    return bytes;
  }

  static Future<Uint8List> readThumbnailBytes(String uri, int size) async {
    final bytes = await _channel.invokeMethod<Uint8List>(
      'readThumbnailBytes',
      {'uri': uri, 'size': size},
    );
    if (bytes == null) {
      throw StateError('Android returned no thumbnail bytes.');
    }
    return bytes;
  }

  static Future<String> getThumbnailPath(String uri, int size) async {
    final path = await _channel.invokeMethod<String>(
      'getThumbnailPath',
      {'uri': uri, 'size': size},
    );
    if (path == null || path.isEmpty) {
      throw StateError('Android returned no thumbnail path.');
    }
    return path;
  }
}

class AndroidImageCache {
  AndroidImageCache._();

  static const _maxThumbnails = 400;
  static const _maxFullImages = 4;
  static const _maxThumbnailLoads = 6;
  static int _activeThumbnailLoads = 0;
  static final _thumbnailWaiters = <Completer<void>>[];
  static final _thumbnails = <String, Future<String>>{};
  static final _fullImages = <String, Future<Uint8List>>{};

  static Future<String> thumbnailPath(String uri, {int size = 224}) {
    final key = '$size|$uri';
    final cached = _thumbnails.remove(key);
    if (cached != null) {
      _thumbnails[key] = cached;
      return cached;
    }
    final future = _queuedThumbnailPath(uri, size);
    _thumbnails[key] = future;
    _evictOldest(_thumbnails, _maxThumbnails);
    return future;
  }

  static Future<Uint8List> fullImage(String uri) {
    final cached = _fullImages.remove(uri);
    if (cached != null) {
      _fullImages[uri] = cached;
      return cached;
    }
    final future = AndroidPhotoBridge.readImageBytes(uri);
    _fullImages[uri] = future;
    _evictOldest(_fullImages, _maxFullImages);
    return future;
  }

  static Future<String> _queuedThumbnailPath(String uri, int size) async {
    await _acquireThumbnailSlot();
    try {
      return await AndroidPhotoBridge.getThumbnailPath(uri, size);
    } finally {
      _releaseThumbnailSlot();
    }
  }

  static Future<void> _acquireThumbnailSlot() async {
    if (_activeThumbnailLoads < _maxThumbnailLoads) {
      _activeThumbnailLoads++;
      return;
    }
    final waiter = Completer<void>();
    _thumbnailWaiters.add(waiter);
    await waiter.future;
    _activeThumbnailLoads++;
  }

  static void _releaseThumbnailSlot() {
    _activeThumbnailLoads = math.max(0, _activeThumbnailLoads - 1);
    if (_thumbnailWaiters.isNotEmpty) {
      _thumbnailWaiters.removeAt(0).complete();
    }
  }

  static void prefetchThumbnails(Iterable<PhotoAsset> photos) {
    if (!Platform.isAndroid) return;
    for (final photo in photos) {
      if (photo.path.startsWith('content://')) {
        thumbnailPath(photo.path);
      }
    }
  }

  static void _evictOldest<T>(Map<String, Future<T>> cache, int maxItems) {
    while (cache.length > maxItems) {
      cache.remove(cache.keys.first);
    }
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

  // Kept to pin the dynamic library for the lifetime of the lookup functions.
  // ignore: unused_field
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
    if (Platform.isAndroid) {
      return AndroidPhotoBridge.scanPhotos();
    }
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
      AndroidImageCache.prefetchThumbnails(photos.take(96));
    } catch (error) {
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<PhotoAsset> get _visiblePhotos {
    Iterable<PhotoAsset> items = _photos;
    if (_section == LibrarySection.favorites) {
      items = items.where((p) => p.favorite);
    }
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
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _EmptyState(title: 'Scan failed', subtitle: _error!);
    }
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
              // Chip(
              //   avatar: Icon(usingRust ? Icons.memory : Icons.code, size: 18),
              //   label: Text(usingRust ? 'Rust core' : 'Dart fallback'),
              // ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: Platform.isAndroid
                    ? InputDecorator(
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.photo_library_outlined),
                          border: OutlineInputBorder(),
                          labelText: 'Source',
                          isDense: true,
                        ),
                        child: Text(
                          folderController.text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      )
                    : TextField(
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
                label: Text(Platform.isAndroid ? 'Load' : 'Scan'),
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
    return _ZoomablePhotoMap(
      photos: photos,
      selected: selected,
      onSelect: onSelect,
      onOpen: onOpen,
    );
  }
}

class _ZoomablePhotoMap extends StatefulWidget {
  const _ZoomablePhotoMap({
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
  State<_ZoomablePhotoMap> createState() => _ZoomablePhotoMapState();
}

class _ZoomablePhotoMapState extends State<_ZoomablePhotoMap> {
  static const _minTile = 10.0;
  static const _maxTile = 420.0;
  static const _initialTile = 96.0;

  Offset _offset = const Offset(20, 20);
  double _tile = _initialTile;
  late Offset _startOffset;
  late double _startTile;
  late Offset _startFocal;

  @override
  void didUpdateWidget(covariant _ZoomablePhotoMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photos.length != widget.photos.length) {
      _offset = const Offset(20, 20);
      _tile = _initialTile;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final columns =
            _columnsFor(widget.photos.length, size.aspectRatio, _tile);
        final visible = _visibleIndexes(
          count: widget.photos.length,
          columns: columns,
          viewport: size,
          offset: _offset,
          tile: _tile,
        );

        return Listener(
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) {
              final factor = event.scrollDelta.dy > 0 ? 0.88 : 1.14;
              _zoomAt(event.localPosition, factor, size);
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTapDown: (details) {
              final index = _indexAt(details.localPosition, columns);
              if (index != null) {
                widget.onOpen(widget.photos[index]);
              }
            },
            onTapUp: (details) {
              final index = _indexAt(details.localPosition, columns);
              if (index != null) {
                widget.onSelect(widget.photos[index]);
              }
            },
            onScaleStart: (details) {
              _startOffset = _offset;
              _startTile = _tile;
              _startFocal = details.localFocalPoint;
            },
            onScaleUpdate: (details) {
              final nextTile =
                  (_startTile * details.scale).clamp(_minTile, _maxTile);
              final worldAtStart = (_startFocal - _startOffset) / _startTile;
              final nextOffset = details.localFocalPoint -
                  worldAtStart * nextTile +
                  details.localFocalPoint -
                  _startFocal;
              final nextColumns =
                  _columnsFor(widget.photos.length, size.aspectRatio, nextTile);
              final nextRows = (widget.photos.length / nextColumns).ceil();
              setState(() {
                _tile = nextTile;
                _offset = _clampOffset(nextOffset, size,
                    Size(nextColumns * nextTile, nextRows * nextTile));
              });
            },
            child: ClipRect(
              child: Stack(
                children: [
                  for (final index in visible)
                    _MapTile(
                      key: ValueKey(widget.photos[index].path),
                      photo: widget.photos[index],
                      selected:
                          widget.selected?.path == widget.photos[index].path,
                      rect: _rectFor(index, columns),
                      tile: _tile,
                      offset: _offset,
                    ),
                  Positioned(
                    left: 12,
                    bottom: 12,
                    child: _ZoomHud(
                      photos: widget.photos.length,
                      visible: visible.length,
                      tile: _tile,
                      onReset: () => setState(() {
                        _tile = _initialTile;
                        _offset = const Offset(20, 20);
                      }),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _zoomAt(Offset focal, double factor, Size viewport) {
    final nextTile = (_tile * factor).clamp(_minTile, _maxTile);
    final world = (focal - _offset) / _tile;
    final nextColumns =
        _columnsFor(widget.photos.length, viewport.aspectRatio, nextTile);
    final nextRows = (widget.photos.length / nextColumns).ceil();
    final nextContent = Size(nextColumns * nextTile, nextRows * nextTile);
    setState(() {
      _tile = nextTile;
      _offset = _clampOffset(focal - world * nextTile, viewport, nextContent);
    });
  }

  int? _indexAt(Offset localPosition, int columns) {
    final world = localPosition - _offset;
    if (world.dx < 0 || world.dy < 0) return null;
    final column = world.dx ~/ _tile;
    final row = world.dy ~/ _tile;
    if (column < 0 || column >= columns || row < 0) return null;
    final index = row * columns + column;
    if (index < 0 || index >= widget.photos.length) return null;
    return index;
  }

  Rect _rectFor(int index, int columns) {
    final column = index % columns;
    final row = index ~/ columns;
    return Rect.fromLTWH(column * _tile, row * _tile, _tile, _tile);
  }

  List<int> _visibleIndexes({
    required int count,
    required int columns,
    required Size viewport,
    required Offset offset,
    required double tile,
  }) {
    final startColumn = math.max(0, ((-offset.dx) / tile).floor() - 2);
    final endColumn =
        math.min(columns - 1, ((viewport.width - offset.dx) / tile).ceil() + 2);
    final startRow = math.max(0, ((-offset.dy) / tile).floor() - 2);
    final endRow = math.min((count / columns).ceil() - 1,
        ((viewport.height - offset.dy) / tile).ceil() + 2);
    final indexes = <int>[];
    for (var row = startRow; row <= endRow; row++) {
      for (var column = startColumn; column <= endColumn; column++) {
        final index = row * columns + column;
        if (index >= 0 && index < count) indexes.add(index);
      }
    }
    return indexes;
  }

  int _columnsFor(int count, double aspectRatio, double tile) {
    if (count <= 0) return 1;
    final base = math.sqrt(count * math.max(0.65, aspectRatio));
    final startColumns = math.max(1, base.ceil());
    final zoomProgress =
        ((tile - _initialTile) / (_maxTile - _initialTile)).clamp(0.0, 1.0);
    final maxZoomColumns = aspectRatio < 1 ? 1 : count;
    if (zoomProgress >= 0.98) return maxZoomColumns;
    final stripProgress = math.pow(zoomProgress, 4).toDouble();
    final columns = startColumns +
        ((maxZoomColumns - startColumns) * stripProgress).round();
    return columns.clamp(1, count);
  }

  Offset _clampOffset(Offset offset, Size viewport, Size content) {
    final minX = math.min(20.0, viewport.width - content.width - 20);
    final minY = math.min(20.0, viewport.height - content.height - 20);
    final maxX = 20.0;
    final maxY = 20.0;
    return Offset(offset.dx.clamp(minX, maxX), offset.dy.clamp(minY, maxY));
  }
}

class _MapTile extends StatelessWidget {
  const _MapTile({
    super.key,
    required this.photo,
    required this.selected,
    required this.rect,
    required this.tile,
    required this.offset,
  });

  final PhotoAsset photo;
  final bool selected;
  final Rect rect;
  final double tile;
  final Offset offset;

  @override
  Widget build(BuildContext context) {
    final gap = tile < 28 ? 0.0 : 1.0;
    final showChrome = tile >= 72;
    return Positioned(
      left: offset.dx + rect.left + gap,
      top: offset.dy + rect.top + gap,
      width: math.max(1, rect.width - gap * 2),
      height: math.max(1, rect.height - gap * 2),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(tile < 40 ? 0 : 8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _GpuFriendlyImage(
              path: photo.path,
              thumbnailSize: tile < 44 ? 96 : (tile < 96 ? 160 : 224),
            ),
            if (selected && tile >= 42)
              ColoredBox(color: Colors.white.withValues(alpha: 0.12)),
            if (showChrome)
              Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _TileLabel(photo: photo)),
            if (selected && tile >= 64)
              const Positioned(
                left: 6,
                top: 6,
                child: Icon(Icons.check_circle, color: Colors.white, size: 20),
              ),
            if (photo.favorite && tile >= 42)
              const Positioned(
                right: 5,
                top: 5,
                child: Icon(Icons.favorite, color: Colors.white, size: 18),
              ),
          ],
        ),
      ),
    );
  }
}

class _ViewerMiniTimeline extends StatefulWidget {
  const _ViewerMiniTimeline({
    required this.photos,
    required this.activeIndex,
    required this.onSelectIndex,
  });

  final List<PhotoAsset> photos;
  final int activeIndex;
  final ValueChanged<int> onSelectIndex;

  @override
  State<_ViewerMiniTimeline> createState() => _ViewerMiniTimelineState();
}

class _ViewerMiniTimelineState extends State<_ViewerMiniTimeline> {
  static const _itemExtent = 50.0;
  static const _sideBlurWidth = 48.0;

  final _controller = ScrollController();
  double _viewportWidth = 0;
  bool _programmaticScroll = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _centerOn(widget.activeIndex, animated: false);
    });
  }

  @override
  void didUpdateWidget(covariant _ViewerMiniTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeIndex != widget.activeIndex ||
        oldWidget.photos.length != widget.photos.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _centerOn(widget.activeIndex);
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewportWidth = constraints.maxWidth;
        return Padding(
          padding: EdgeInsets.fromLTRB(14, 0, 14, 10 + bottomInset),
          child: SizedBox(
            height: 64,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.32),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.13),
                        ),
                      ),
                    ),
                  ),
                  NotificationListener<ScrollEndNotification>(
                    onNotification: (_) {
                      if (!_programmaticScroll) _openCenteredPhoto();
                      return false;
                    },
                    child: ListView.builder(
                      controller: _controller,
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      padding: EdgeInsets.symmetric(
                        horizontal: math.max(
                          0,
                          (constraints.maxWidth - _itemExtent) / 2,
                        ),
                        vertical: 9,
                      ),
                      itemExtent: _itemExtent,
                      itemCount: widget.photos.length,
                      itemBuilder: (context, index) {
                        final photo = widget.photos[index];
                        final active = index == widget.activeIndex;
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => widget.onSelectIndex(index),
                          child: Center(
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              curve: Curves.easeOut,
                              width: active ? 44 : 36,
                              height: active ? 44 : 36,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: active
                                      ? Colors.white
                                      : Colors.white.withValues(alpha: 0.18),
                                  width: active ? 2 : 1,
                                ),
                                boxShadow: active
                                    ? [
                                        BoxShadow(
                                          color: Colors.black
                                              .withValues(alpha: 0.34),
                                          blurRadius: 12,
                                        ),
                                      ]
                                    : null,
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    _GpuFriendlyImage(path: photo.path),
                                    if (!active)
                                      ColoredBox(
                                        color:
                                            Colors.black.withValues(alpha: 0.2),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: _sideBlurWidth,
                    child: _TimelineEdgeBlur(alignment: Alignment.centerLeft),
                  ),
                  const Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    width: _sideBlurWidth,
                    child: _TimelineEdgeBlur(alignment: Alignment.centerRight),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _centerOn(int index, {bool animated = true}) {
    if (!_controller.hasClients || _viewportWidth <= 0) return;
    final maxScroll = _controller.position.maxScrollExtent;
    final target =
        (index * _itemExtent).clamp(0.0, math.max(0.0, maxScroll)).toDouble();

    if (!animated) {
      _controller.jumpTo(target);
      return;
    }

    _programmaticScroll = true;
    _controller
        .animateTo(
          target,
          duration: const Duration(milliseconds: 210),
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() => _programmaticScroll = false);
  }

  void _openCenteredPhoto() {
    if (!_controller.hasClients || widget.photos.isEmpty) return;
    final rawIndex = (_controller.offset / _itemExtent).round();
    final index = rawIndex.clamp(0, widget.photos.length - 1);
    widget.onSelectIndex(index);
    _centerOn(index);
  }
}

class _TimelineEdgeBlur extends StatelessWidget {
  const _TimelineEdgeBlur({required this.alignment});

  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final isLeft = alignment == Alignment.centerLeft;
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: isLeft ? Alignment.centerLeft : Alignment.centerRight,
              end: isLeft ? Alignment.centerRight : Alignment.centerLeft,
              colors: [
                Colors.black.withValues(alpha: 0.5),
                Colors.black.withValues(alpha: 0),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ZoomHud extends StatelessWidget {
  const _ZoomHud({
    required this.photos,
    required this.visible,
    required this.tile,
    required this.onReset,
  });

  final int photos;
  final int visible;
  final double tile;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
                '$photos photos • $visible rendered • ${tile.toStringAsFixed(0)}px'),
            const SizedBox(width: 8),
            TextButton(onPressed: onReset, child: const Text('Reset')),
          ],
        ),
      ),
    );
  }
}

// ignore: unused_element
class _MapBackgroundPainter extends CustomPainter {
  // ignore: unused_element
  const _MapBackgroundPainter({
    required this.offset,
    required this.tile,
    required this.columns,
    required this.rows,
    required this.color,
  });

  final Offset offset;
  final double tile;
  final int columns;
  final int rows;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (tile < 24) return;
    final paint = Paint()
      ..color = color.withValues(alpha: 0.45)
      ..strokeWidth = 0.6;
    final width = columns * tile;
    final height = rows * tile;
    for (var x = offset.dx; x <= offset.dx + width; x += tile) {
      if (x >= 0 && x <= size.width) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      }
    }
    for (var y = offset.dy; y <= offset.dy + height; y += tile) {
      if (y >= 0 && y <= size.height) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MapBackgroundPainter oldDelegate) {
    return oldDelegate.offset != offset ||
        oldDelegate.tile != tile ||
        oldDelegate.columns != columns ||
        oldDelegate.rows != rows ||
        oldDelegate.color != color;
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
                color: Colors.black.withValues(alpha: selected ? 0.22 : 0.10),
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
  const _GpuFriendlyImage({
    required this.path,
    this.fit = BoxFit.cover,
    this.thumbnailSize = 224,
  });

  final String path;
  final BoxFit fit;
  final int thumbnailSize;

  @override
  Widget build(BuildContext context) {
    if (Platform.isAndroid && path.startsWith('content://')) {
      if (fit != BoxFit.contain) {
        return RepaintBoundary(
          child: FutureBuilder<String>(
            future: AndroidImageCache.thumbnailPath(path, size: thumbnailSize),
            builder: (context, snapshot) {
              if (snapshot.hasData) {
                return Image.file(
                  File(snapshot.data!),
                  fit: fit,
                  filterQuality: FilterQuality.low,
                  cacheWidth: thumbnailSize,
                  errorBuilder: (_, __, ___) => const _ImageErrorBox(),
                );
              }
              if (snapshot.hasError) return const _ImageErrorBox();
              return const _ImagePlaceholder();
            },
          ),
        );
      }
      return RepaintBoundary(
        child: FutureBuilder<Uint8List>(
          future: AndroidImageCache.fullImage(path),
          builder: (context, snapshot) {
            if (snapshot.hasData) {
              return Image.memory(
                snapshot.data!,
                fit: fit,
                filterQuality: FilterQuality.medium,
              );
            }
            if (snapshot.hasError) return const _ImageErrorBox();
            return const _ImagePlaceholder(showSpinner: true);
          },
        ),
      );
    }
    return RepaintBoundary(
      child: Image.file(
        File(path),
        fit: fit,
        filterQuality: FilterQuality.medium,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded || frame != null) return child;
          return const _ImagePlaceholder(showSpinner: true);
        },
        errorBuilder: (_, __, ___) => const _ImageErrorBox(),
      ),
    );
  }
}

class _ImagePlaceholder extends StatelessWidget {
  const _ImagePlaceholder({this.showSpinner = false});

  final bool showSpinner;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xff2c2c2e),
      child: showSpinner
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : null,
    );
  }
}

class _ImageErrorBox extends StatelessWidget {
  const _ImageErrorBox();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xff3a3a3c),
      child: Icon(Icons.broken_image_outlined, color: Colors.white54),
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
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.72)],
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
      body: Stack(
        children: [
          Positioned.fill(
            child: PageView.builder(
              controller: _controller,
              itemCount: widget.photos.length,
              onPageChanged: (index) => setState(() => _index = index),
              itemBuilder: (_, index) {
                final item = widget.photos[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 86),
                  child: InteractiveViewer(
                    minScale: 0.8,
                    maxScale: 5,
                    child: Center(
                      child: Hero(
                        tag: item.path,
                        child: _GpuFriendlyImage(
                          path: item.path,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (widget.photos.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _ViewerMiniTimeline(
                photos: widget.photos,
                activeIndex: _index,
                onSelectIndex: _openAt,
              ),
            ),
        ],
      ),
    );
  }

  void _openAt(int index) {
    if (index == _index) return;
    setState(() => _index = index);
    _controller.animateToPage(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
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

String _defaultPicturesPath() {
  if (Platform.isAndroid) return 'Device photos';
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
