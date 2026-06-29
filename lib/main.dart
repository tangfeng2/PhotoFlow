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

  PhotoAsset renamed({required String path, required String name}) {
    final ext =
        name.contains('.') ? name.split('.').last.toLowerCase() : extension;
    return PhotoAsset(
      path: path,
      name: name,
      modifiedAt: modifiedAt,
      sizeBytes: sizeBytes,
      extension: ext,
      width: width,
      height: height,
      albumName: albumName,
      favorite: favorite,
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

class PhotoActions {
  PhotoActions._();

  static Future<void> copyReference(PhotoAsset photo) async {
    if (Platform.isAndroid && photo.path.startsWith('content://')) {
      await AndroidPhotoBridge._channel.invokeMethod<void>(
        'copyPhoto',
        {'uri': photo.path, 'name': photo.name},
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: photo.path));
  }

  static Future<void> share(PhotoAsset photo) async {
    if (Platform.isAndroid && photo.path.startsWith('content://')) {
      await AndroidPhotoBridge._channel.invokeMethod<void>(
        'sharePhoto',
        {'uri': photo.path, 'name': photo.name},
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: photo.path));
  }

  static Future<PhotoAsset> rename(PhotoAsset photo, String newName) async {
    final cleanName = newName.trim();
    if (cleanName.isEmpty || cleanName == photo.name) return photo;

    if (Platform.isAndroid && photo.path.startsWith('content://')) {
      final data =
          await AndroidPhotoBridge._channel.invokeMapMethod<String, dynamic>(
        'renamePhoto',
        {'uri': photo.path, 'name': cleanName},
      );
      return photo.renamed(
        path: data?['path'] as String? ?? photo.path,
        name: data?['name'] as String? ?? cleanName,
      );
    }

    final file = File(photo.path);
    final renamed =
        File('${file.parent.path}${Platform.pathSeparator}$cleanName');
    await file.rename(renamed.path);
    return photo.renamed(path: renamed.path, name: cleanName);
  }

  static Future<void> delete(PhotoAsset photo) async {
    if (Platform.isAndroid && photo.path.startsWith('content://')) {
      await AndroidPhotoBridge._channel.invokeMethod<void>(
        'deletePhoto',
        {'uri': photo.path},
      );
      return;
    }
    await File(photo.path).delete();
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

  Future<void> _copyPhoto(PhotoAsset photo) async {
    await PhotoActions.copyReference(photo);
    _showSnack('Copied reference');
  }

  Future<void> _sharePhoto(PhotoAsset photo) async {
    try {
      await PhotoActions.share(photo);
    } catch (error) {
      _showSnack('Share failed: $error');
    }
  }

  Future<PhotoAsset?> _renamePhoto(PhotoAsset photo) async {
    final controller = TextEditingController(text: photo.name);
    final nextName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename photo'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'File name'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (nextName == null || nextName.trim().isEmpty) return null;

    try {
      final renamed = await PhotoActions.rename(photo, nextName);
      setState(() {
        _photos = [
          for (final item in _photos)
            if (item.path == photo.path) renamed else item,
        ];
        if (_selected?.path == photo.path) _selected = renamed;
      });
      _showSnack('Renamed');
      return renamed;
    } catch (error) {
      _showSnack('Rename failed: $error');
      return null;
    }
  }

  Future<bool> _deletePhoto(PhotoAsset photo) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete photo?'),
        content: Text(photo.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;

    try {
      await PhotoActions.delete(photo);
      setState(() {
        _photos = [
          for (final item in _photos)
            if (item.path != photo.path) item
        ];
        _selected = _photos.firstOrNull;
      });
      _showSnack('Deleted');
      return true;
    } catch (error) {
      _showSnack('Delete failed: $error');
      return false;
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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
                width: 218,
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
                  onCopy:
                      _selected == null ? null : () => _copyPhoto(_selected!),
                  onShare:
                      _selected == null ? null : () => _sharePhoto(_selected!),
                  onRename:
                      _selected == null ? null : () => _renamePhoto(_selected!),
                  onDelete:
                      _selected == null ? null : () => _deletePhoto(_selected!),
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
        onCopy: _copyPhoto,
        onShare: _sharePhoto,
        onRename: _renamePhoto,
        onDelete: _deletePhoto,
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
    final labelStyle = Theme.of(context).textTheme.labelMedium?.copyWith(
          fontSize: 12,
          height: 1,
          fontWeight: FontWeight.w600,
        );
    return DefaultTextStyle.merge(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: labelStyle,
      child: NavigationRail(
        extended: true,
        minExtendedWidth: 218,
        minWidth: 72,
        groupAlignment: -0.9,
        selectedIndex: section.index,
        onDestinationSelected: (index) =>
            onChanged(LibrarySection.values[index]),
        destinations: [
          NavigationRailDestination(
            icon: const Icon(Icons.photo_library_outlined, size: 21),
            selectedIcon: const Icon(Icons.photo_library, size: 21),
            label: _RailLabel(text: 'Library', count: total),
          ),
          const NavigationRailDestination(
            icon: Icon(Icons.calendar_month_outlined, size: 21),
            selectedIcon: Icon(Icons.calendar_month, size: 21),
            label: _RailLabel(text: 'Timeline'),
          ),
          NavigationRailDestination(
            icon: const Icon(Icons.photo_album_outlined, size: 21),
            selectedIcon: const Icon(Icons.photo_album, size: 21),
            label: _RailLabel(text: 'Albums', count: albums),
          ),
          NavigationRailDestination(
            icon: const Icon(Icons.favorite_border, size: 21),
            selectedIcon: const Icon(Icons.favorite, size: 21),
            label: _RailLabel(text: 'Favorites', count: favorites),
          ),
        ],
      ),
    );
  }
}

class _RailLabel extends StatelessWidget {
  const _RailLabel({required this.text, this.count});

  final String text;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final count = this.count;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (count != null) ...[
          const SizedBox(width: 6),
          Text(
            _compactCount(count),
            maxLines: 1,
            style: TextStyle(color: Theme.of(context).hintColor, fontSize: 11),
          ),
        ],
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
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
      child: Theme(
        data: Theme.of(context).copyWith(
          textTheme: Theme.of(context).textTheme.copyWith(
                labelLarge: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontSize: 11,
                      height: 1,
                    ),
              ),
        ),
        child: SegmentedButton<LibrarySection>(
          style: const ButtonStyle(
            visualDensity: VisualDensity(horizontal: -3, vertical: -3),
            padding: WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 7, vertical: 6),
            ),
          ),
          segments: const [
            ButtonSegment(value: LibrarySection.library, label: Text('Lib')),
            ButtonSegment(value: LibrarySection.timeline, label: Text('Days')),
            ButtonSegment(value: LibrarySection.albums, label: Text('Albums')),
            ButtonSegment(value: LibrarySection.favorites, label: Text('Favs')),
          ],
          selected: {section},
          onSelectionChanged: (value) => onChanged(value.first),
        ),
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
  static const _minTile = 8.0;
  static const _maxTile = 420.0;

  Offset _offset = Offset.zero;
  double _tile = 0;
  late Offset _startOffset;
  late double _startTile;
  late Offset _startFocal;
  int _lastPhotoCount = 0;
  Size _lastViewport = Size.zero;

  @override
  void didUpdateWidget(covariant _ZoomablePhotoMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photos.length != widget.photos.length) {
      _tile = 0;
      _offset = Offset.zero;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        _ensureViewportLayout(size);
        if (_tile <= 0 || !_tile.isFinite || widget.photos.isEmpty) {
          return const SizedBox.expand();
        }
        final columns = _columnsFor(widget.photos.length, size, _tile);
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
              if (_startTile <= 0 || !_startTile.isFinite) return;
              final nextTile = _clampTile(_startTile * details.scale, size);
              final worldAtStart = (_startFocal - _startOffset) / _startTile;
              final nextOffset = details.localFocalPoint -
                  worldAtStart * nextTile +
                  details.localFocalPoint -
                  _startFocal;
              final nextColumns =
                  _columnsFor(widget.photos.length, size, nextTile);
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
                        _tile = _fitTileFor(widget.photos.length, size);
                        final resetColumns =
                            _columnsFor(widget.photos.length, size, _tile);
                        final resetRows =
                            (widget.photos.length / resetColumns).ceil();
                        _offset = _fitOffset(
                          size,
                          Size(resetColumns * _tile, resetRows * _tile),
                        );
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
    if (_tile <= 0 || !_tile.isFinite) return;
    final nextTile = _clampTile(_tile * factor, viewport);
    final world = (focal - _offset) / _tile;
    final nextColumns = _columnsFor(widget.photos.length, viewport, nextTile);
    final nextRows = (widget.photos.length / nextColumns).ceil();
    final nextContent = Size(nextColumns * nextTile, nextRows * nextTile);
    setState(() {
      _tile = nextTile;
      _offset = _clampOffset(focal - world * nextTile, viewport, nextContent);
    });
  }

  int? _indexAt(Offset localPosition, int columns) {
    if (_tile <= 0 || !_tile.isFinite) return null;
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
    if (count <= 0 || columns <= 0 || tile <= 0 || !tile.isFinite) {
      return const [];
    }
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

  void _ensureViewportLayout(Size viewport) {
    if (widget.photos.isEmpty || viewport.width <= 0 || viewport.height <= 0) {
      return;
    }
    final viewportChanged = _lastViewport != viewport;
    final countChanged = _lastPhotoCount != widget.photos.length;
    if (_tile <= 0 || viewportChanged || countChanged) {
      final previousTile = _tile;
      _tile = previousTile <= 0
          ? _fitTileFor(widget.photos.length, viewport)
          : _clampTile(previousTile, viewport);
      final columns = _columnsFor(widget.photos.length, viewport, _tile);
      final rows = (widget.photos.length / columns).ceil();
      _offset = _clampOffset(
        countChanged
            ? _fitOffset(viewport, Size(columns * _tile, rows * _tile))
            : _offset,
        viewport,
        Size(columns * _tile, rows * _tile),
      );
      _lastViewport = viewport;
      _lastPhotoCount = widget.photos.length;
    }
  }

  int _columnsFor(int count, Size viewport, double tile) {
    if (count <= 0) return 1;
    if (tile <= 0 || !tile.isFinite) return 1;
    final usableWidth = math.max(1.0, viewport.width);
    return (usableWidth / tile).floor().clamp(1, count);
  }

  double _fitTileFor(int count, Size viewport) {
    if (count <= 0 || viewport.width <= 0 || viewport.height <= 0) {
      return 96;
    }
    var bestTile = _minTile;
    for (var columns = 1; columns <= count; columns++) {
      final rows = (count / columns).ceil();
      final tile = math.min(viewport.width / columns, viewport.height / rows);
      if (tile > bestTile) bestTile = tile;
    }
    return bestTile.clamp(_minTile, math.min(_maxTile, viewport.width));
  }

  double _clampTile(double tile, Size viewport) {
    final minTile = _fitTileFor(widget.photos.length, viewport);
    final maxTile = math.min(_maxTile, math.max(_minTile, viewport.width));
    return tile.clamp(minTile, maxTile).toDouble();
  }

  Offset _fitOffset(Size viewport, Size content) {
    return Offset(
      math.max(0, (viewport.width - content.width) / 2),
      math.max(0, (viewport.height - content.height) / 2),
    );
  }

  Offset _clampOffset(Offset offset, Size viewport, Size content) {
    final dx = content.width <= viewport.width
        ? (viewport.width - content.width) / 2
        : offset.dx.clamp(viewport.width - content.width, 0.0).toDouble();
    final dy = content.height <= viewport.height
        ? (viewport.height - content.height) / 2
        : offset.dy.clamp(viewport.height - content.height, 0.0).toDouble();
    return Offset(dx, dy);
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
  const _Inspector({
    required this.photo,
    required this.onFavorite,
    required this.onCopy,
    required this.onShare,
    required this.onRename,
    required this.onDelete,
  });

  final PhotoAsset? photo;
  final VoidCallback? onFavorite;
  final VoidCallback? onCopy;
  final VoidCallback? onShare;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;

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
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: onCopy,
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('Copy'),
                    ),
                    OutlinedButton.icon(
                      onPressed: onShare,
                      icon: const Icon(Icons.ios_share, size: 18),
                      label: const Text('Share'),
                    ),
                    OutlinedButton.icon(
                      onPressed: onRename,
                      icon: const Icon(
                        Icons.drive_file_rename_outline,
                        size: 18,
                      ),
                      label: const Text('Rename'),
                    ),
                    FilledButton.icon(
                      onPressed: onDelete,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Delete'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SelectableText(p.path,
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
    );
  }
}

class _PhotoViewer extends StatefulWidget {
  const _PhotoViewer({
    required this.photos,
    required this.initial,
    required this.onFavorite,
    required this.onCopy,
    required this.onShare,
    required this.onRename,
    required this.onDelete,
  });

  final List<PhotoAsset> photos;
  final PhotoAsset initial;
  final ValueChanged<PhotoAsset> onFavorite;
  final ValueChanged<PhotoAsset> onCopy;
  final ValueChanged<PhotoAsset> onShare;
  final Future<PhotoAsset?> Function(PhotoAsset) onRename;
  final Future<bool> Function(PhotoAsset) onDelete;

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  late final PageController _controller;
  late List<PhotoAsset> _photos = List.of(widget.photos);
  late int _index =
      math.max(0, _photos.indexWhere((p) => p.path == widget.initial.path));

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
    final photo = _photos[_index];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(photo.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Copy',
            onPressed: () => widget.onCopy(photo),
            icon: const Icon(Icons.copy),
          ),
          IconButton(
            tooltip: 'Share',
            onPressed: () => widget.onShare(photo),
            icon: const Icon(Icons.ios_share),
          ),
          IconButton(
            tooltip: 'Rename',
            onPressed: () async {
              final renamed = await widget.onRename(photo);
              if (renamed == null || !mounted) return;
              setState(() {
                _photos = [
                  for (final item in _photos)
                    if (item.path == photo.path) renamed else item,
                ];
              });
            },
            icon: const Icon(Icons.drive_file_rename_outline),
          ),
          IconButton(
            onPressed: () => widget.onFavorite(photo),
            icon: Icon(photo.favorite ? Icons.favorite : Icons.favorite_border),
          ),
          IconButton(
            tooltip: 'Delete',
            onPressed: () async {
              final navigator = Navigator.of(context);
              final deleted = await widget.onDelete(photo);
              if (deleted && mounted) navigator.pop();
            },
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: PageView.builder(
              controller: _controller,
              itemCount: _photos.length,
              onPageChanged: (index) => setState(() => _index = index),
              itemBuilder: (_, index) {
                final item = _photos[index];
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
          if (_photos.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _ViewerMiniTimeline(
                photos: _photos,
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

String _compactCount(int count) {
  if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)}M';
  if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}K';
  return '$count';
}
