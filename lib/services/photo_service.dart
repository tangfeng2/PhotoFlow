import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import '../models/photo_asset.dart';

class AndroidPhotoBridge {
  AndroidPhotoBridge._();

  static const _channel = MethodChannel('photo_flow/android_photos');

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
      'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif'
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
