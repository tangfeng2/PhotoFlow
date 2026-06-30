import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../models/photo_asset.dart';
import 'gpu_image.dart';

class PhotoViewer extends StatefulWidget {
  const PhotoViewer({
    super.key,
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
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> {
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
                        child: GpuFriendlyImage(
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
              child: ViewerMiniTimeline(
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

class ViewerMiniTimeline extends StatefulWidget {
  const ViewerMiniTimeline({
    super.key,
    required this.photos,
    required this.activeIndex,
    required this.onSelectIndex,
  });

  final List<PhotoAsset> photos;
  final int activeIndex;
  final ValueChanged<int> onSelectIndex;

  @override
  State<ViewerMiniTimeline> createState() => _ViewerMiniTimelineState();
}

class _ViewerMiniTimelineState extends State<ViewerMiniTimeline> {
  static const _itemExtent = 50.0;
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
  void didUpdateWidget(covariant ViewerMiniTimeline oldWidget) {
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
                                    GpuFriendlyImage(path: photo.path),
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


