import 'dart:io';

import 'package:flutter/material.dart';

import '../library_controller.dart';
import '../widgets/metro_widgets.dart';

/// Обложка трека из тегов файла; без обложки - значок ноты (или киноплёнки для видео).
/// Обновляется, когда обложка заменена.
class CoverImage extends StatefulWidget {
  const CoverImage({super.key, required this.trackId, required this.size, this.isVideo = false});

  final String? trackId;
  final double size;
  final bool isVideo;

  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  String? _path;

  @override
  void initState() {
    super.initState();
    hydraLibrary.addListener(_load);
    _load();
  }

  @override
  void didUpdateWidget(covariant CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trackId != widget.trackId) _load();
  }

  @override
  void dispose() {
    hydraLibrary.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final id = widget.trackId;
    final path = id == null ? null : await hydraLibrary.coverPath(id);
    if (!mounted || id != widget.trackId) return;
    if (path != _path) setState(() => _path = path);
  }

  @override
  Widget build(BuildContext context) {
    final path = _path;
    if (widget.trackId != null && path != null) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: Image.file(File(path), fit: BoxFit.cover, gaplessPlayback: true),
      );
    }
    return Cover(isVideo: widget.isVideo, size: widget.size);
  }
}
