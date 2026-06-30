import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/photo_asset.dart';
import '../services/photo_service.dart';
import '../widgets/gpu_image.dart';
import '../widgets/photo_viewer.dart';

enum LibrarySection { library, timeline, albums, favorites }

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
  final Set<String> _selectedPaths = {};
  bool _loading = false;
  String? _error;
  String _query = '';

  bool get _selectionMode => _selectedPaths.isNotEmpty;

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
        _selected = null;
        _selectedPaths.clear();
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
      if (_selected != null && _selectedPaths.contains(photo.path)) {
        _selectedPaths
          ..remove(photo.path)
          ..add(_selected!.path);
      }
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
        if (_selectedPaths.remove(photo.path)) _selectedPaths.add(renamed.path);
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
        _selectedPaths.remove(photo.path);
        _selected = _resolveSelectedFallback();
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
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      child: Actions(
        actions: {
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              if (_selectionMode) {
                _clearSelection();
                return null;
              }
              return null;
            },
          ),
        },
        child: PopScope(
          canPop: !_selectionMode,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && _selectionMode) _clearSelection();
          },
          child: Scaffold(
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
                    selectionMode: _selectionMode,
                    selectionCount: _selectedPaths.length,
                    onClearSelection: _clearSelection,
                    onSelectAll: _selectAll,
                    onDeleteSelected: _deleteSelected,
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
                  selectedCount: _selectedPaths.length,
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
          ),
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
    final selectionMode = _selectionMode;
    if (_section == LibrarySection.timeline) {
      return _TimelineView(
        photos: photos,
        selected: _selected,
        selectedPaths: _selectedPaths,
        selectionMode: selectionMode,
        onSelect: _toggleSelection,
        onOpen: _openViewer,
      );
    }
    if (_section == LibrarySection.albums) {
      return _AlbumsView(
        albums: _albumMap(photos),
        selected: _selected,
        selectedPaths: _selectedPaths,
        selectionMode: selectionMode,
        onSelect: _toggleSelection,
        onOpen: _openViewer,
      );
    }
    return _LibraryGrid(
        photos: photos,
        selected: _selected,
        selectedPaths: _selectedPaths,
        selectionMode: selectionMode,
        onSelect: _toggleSelection,
        onOpen: _openViewer);
  }

  void _toggleSelection(PhotoAsset photo) {
    setState(() {
      if (_selectedPaths.contains(photo.path)) {
        _selectedPaths.remove(photo.path);
        _selected = _selected?.path == photo.path ? _resolveSelectedFallback() : _selected;
      } else {
        _selectedPaths.add(photo.path);
        _selected = photo;
      }
    });
  }

  void _selectAll() {
    setState(() {
      _selectedPaths.addAll(_visiblePhotos.map((p) => p.path));
      _selected = _visiblePhotos.isNotEmpty ? _visiblePhotos.first : null;
    });
  }

  Future<void> _deleteSelected() async {
    final count = _selectedPaths.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete $count photo${count == 1 ? '' : 's'}?'),
        content: Text(_selectedPaths.take(3).join('\n')),
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
    if (confirmed != true) return;

    final paths = _selectedPaths.toList();
    for (final path in paths) {
      final photo = _photos.where((p) => p.path == path).firstOrNull;
      if (photo == null) continue;
      try {
        await PhotoActions.delete(photo);
      } catch (_) {}
    }
    setState(() {
      _photos = [
        for (final item in _photos)
          if (!_selectedPaths.contains(item.path)) item
      ];
      _selectedPaths.clear();
      _selected = null;
    });
    _showSnack('Deleted $count photo${count == 1 ? '' : 's'}');
  }

  void _clearSelection() {
    setState(() {
      _selectedPaths.clear();
      _selected = null;
    });
  }

  PhotoAsset? _resolveSelectedFallback() {
    for (final photo in _photos) {
      if (_selectedPaths.contains(photo.path)) return photo;
    }
    return null;
  }

  Future<void> _openViewer(PhotoAsset photo) async {
    _clearSelection();
    await Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => PhotoViewer(
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
    this.selectionMode = false,
    this.selectionCount = 0,
    this.onClearSelection,
    this.onSelectAll,
    this.onDeleteSelected,
  });

  final TextEditingController folderController;
  final TextEditingController searchController;
  final bool usingRust;
  final VoidCallback onScan;
  final ValueChanged<String> onSearch;
  final bool selectionMode;
  final int selectionCount;
  final VoidCallback? onClearSelection;
  final VoidCallback? onSelectAll;
  final VoidCallback? onDeleteSelected;

  @override
  Widget build(BuildContext context) {
    if (selectionMode) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Row(
          children: [
            Text('$selectionCount selected',
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w700)),
            const Spacer(),
            TextButton.icon(
              onPressed: onSelectAll,
              icon: const Icon(Icons.select_all, size: 18),
              label: const Text('All'),
            ),
            const SizedBox(width: 4),
            TextButton.icon(
              onPressed: selectionCount == 0 ? null : onDeleteSelected,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Delete'),
            ),
            const SizedBox(width: 4),
            TextButton.icon(
              onPressed: onClearSelection,
              icon: const Icon(Icons.close, size: 18),
              label: const Text('Cancel'),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Column(
        children: [
          Row(
            children: [
              const Text('Photos',
                  style: TextStyle(fontSize: 34, fontWeight: FontWeight.w800)),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (MediaQuery.sizeOf(context).width >= 600) ...[
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
              ],
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
    required this.selectedPaths,
    required this.selectionMode,
    required this.onSelect,
    required this.onOpen,
  });

  final List<PhotoAsset> photos;
  final PhotoAsset? selected;
  final Set<String> selectedPaths;
  final bool selectionMode;
  final ValueChanged<PhotoAsset> onSelect;
  final ValueChanged<PhotoAsset> onOpen;

  @override
  Widget build(BuildContext context) {
    return _ZoomablePhotoMap(
      photos: photos,
      selected: selected,
      selectedPaths: selectedPaths,
      selectionMode: selectionMode,
      onSelect: onSelect,
      onOpen: onOpen,
    );
  }
}

class _ZoomablePhotoMap extends StatefulWidget {
  const _ZoomablePhotoMap({
    required this.photos,
    required this.selected,
    required this.selectedPaths,
    required this.selectionMode,
    required this.onSelect,
    required this.onOpen,
  });

  final List<PhotoAsset> photos;
  final PhotoAsset? selected;
  final Set<String> selectedPaths;
  final bool selectionMode;
  final ValueChanged<PhotoAsset> onSelect;
  final ValueChanged<PhotoAsset> onOpen;

  @override
  State<_ZoomablePhotoMap> createState() => _ZoomablePhotoMapState();
}

class _ZoomablePhotoMapState extends State<_ZoomablePhotoMap> {
  static const _minTile = 8.0;
  static const _maxTile = 420.0;

  // ponytail: static cache persists zoom/pan across tab switches
  static Offset _savedOffset = Offset.zero;
  static double _savedTile = 0;
  static int _savedCount = 0;
  static Size _savedViewport = Size.zero;

  Offset _offset = _savedOffset;
  double _tile = _savedTile;
  late Offset _startOffset;
  late double _startTile;
  late Offset _startFocal;
  int _lastPhotoCount = _savedCount;
  Size _lastViewport = _savedViewport;

  @override
  void didUpdateWidget(covariant _ZoomablePhotoMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photos.length != widget.photos.length) {
      _tile = 0;
      _offset = Offset.zero;
    }
  }

  @override
  void dispose() {
    _savedOffset = _offset;
    _savedTile = _tile;
    _savedCount = widget.photos.length;
    _savedViewport = _lastViewport;
    super.dispose();
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
            onTapUp: (details) {
              final index = _indexAt(details.localPosition, columns);
              if (index != null) {
                final photo = widget.photos[index];
                if (widget.selectionMode) {
                  widget.onSelect(photo);
                } else {
                  widget.onOpen(photo);
                }
              }
            },
            onLongPressStart: (details) {
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
                          widget.selectedPaths.contains(widget.photos[index].path),
                      rect: _rectFor(index, columns),
                      tile: _tile,
                      offset: _offset,
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
            GpuFriendlyImage(
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

class _TimelineView extends StatelessWidget {
  const _TimelineView({
    required this.photos,
    required this.selected,
    required this.selectedPaths,
    required this.selectionMode,
    required this.onSelect,
    required this.onOpen,
  });

  final List<PhotoAsset> photos;
  final PhotoAsset? selected;
  final Set<String> selectedPaths;
  final bool selectionMode;
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
                  selected: selectedPaths.contains(photo.path),
                  compact: true,
                  onTap: () {
                    if (selectionMode) {
                      onSelect(photo);
                    } else {
                      onOpen(photo);
                    }
                  },
                  onLongPress: () => onSelect(photo),
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
  const _AlbumsView({
    required this.albums,
    required this.selected,
    required this.selectedPaths,
    required this.selectionMode,
    required this.onSelect,
    required this.onOpen,
  });

  final Map<String, List<PhotoAsset>> albums;
  final PhotoAsset? selected;
  final Set<String> selectedPaths;
  final bool selectionMode;
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
                          selected: selectedPaths.contains(photo.path),
                          onTap: () {
                            if (selectionMode) {
                              onSelect(photo);
                            } else {
                              onOpen(photo);
                            }
                          },
                          onLongPress: () => onSelect(photo),
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
    required this.onLongPress,
    this.compact = false,
  });

  final PhotoAsset photo;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
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
                    child: GpuFriendlyImage(path: photo.path)),
                if (selected)
                  ColoredBox(
                      color: Colors.black.withValues(alpha: 0.25)),
                if (!compact)
                  Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _TileLabel(photo: photo)),
                if (selected)
                  const Positioned(
                    left: 6,
                    top: 6,
                    child: Icon(Icons.check_circle,
                        color: Colors.white, size: 22),
                  ),
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
    required this.selectedCount,
    required this.onFavorite,
    required this.onCopy,
    required this.onShare,
    required this.onRename,
    required this.onDelete,
  });

  final PhotoAsset? photo;
  final int selectedCount;
  final VoidCallback? onFavorite;
  final VoidCallback? onCopy;
  final VoidCallback? onShare;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    if (selectedCount > 1) {
      return DecoratedBox(
        decoration: BoxDecoration(
            border: Border(
                left: BorderSide(color: Theme.of(context).dividerColor))),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.checklist, size: 48,
                  color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 12),
              Text('$selectedCount photos selected',
                  style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
        ),
      );
    }
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
                    child: GpuFriendlyImage(path: p.path),
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

String _defaultPicturesPath() {
  if (Platform.isAndroid) return 'Device photos';
  final home = Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      '.';
  final pictures = Directory('$home${Platform.pathSeparator}Pictures');
  return pictures.existsSync() ? pictures.path : home;
}
