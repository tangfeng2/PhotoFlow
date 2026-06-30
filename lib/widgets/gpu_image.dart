import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/photo_service.dart';

class GpuFriendlyImage extends StatelessWidget {
  const GpuFriendlyImage({
    super.key,
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
                  errorBuilder: (_, __, ___) => const ImageErrorBox(),
                );
              }
              if (snapshot.hasError) return const ImageErrorBox();
              return const ImagePlaceholder();
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
            if (snapshot.hasError) return const ImageErrorBox();
            return const ImagePlaceholder(showSpinner: true);
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
          return const ImagePlaceholder(showSpinner: true);
        },
        errorBuilder: (_, __, ___) => const ImageErrorBox(),
      ),
    );
  }
}

class ImagePlaceholder extends StatelessWidget {
  const ImagePlaceholder({super.key, this.showSpinner = false});

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

class ImageErrorBox extends StatelessWidget {
  const ImageErrorBox({super.key});

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xff3a3a3c),
      child: Icon(Icons.broken_image_outlined, color: Colors.white54),
    );
  }
}
