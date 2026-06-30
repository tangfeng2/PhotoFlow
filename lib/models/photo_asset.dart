import 'dart:io';

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
