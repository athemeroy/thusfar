import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A local book illustration, enlarged without changing the reading position.
Future<void> openReaderImage(
  BuildContext context,
  ImageProvider image, {
  String? label,
}) => showDialog<void>(
  context: context,
  useSafeArea: false,
  builder: (_) => ReaderImageViewer(image: image, label: label),
);

class ReaderImageViewer extends StatefulWidget {
  const ReaderImageViewer({super.key, required this.image, this.label});
  final ImageProvider image;
  final String? label;

  @override
  State<ReaderImageViewer> createState() => _ReaderImageViewerState();
}

class _ReaderImageViewerState extends State<ReaderImageViewer> {
  final TransformationController _transform = TransformationController();

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog.fullscreen(
    backgroundColor: const Color(0xff151515),
    child: CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.pop(context),
      },
      child: Focus(
        autofocus: true,
        child: SafeArea(
          child: Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      widget.label ?? '书中插图',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  IconButton(
                    tooltip: '还原图片大小',
                    color: Colors.white,
                    onPressed: () => _transform.value = Matrix4.identity(),
                    icon: const Icon(Icons.zoom_out_map),
                  ),
                  IconButton(
                    key: const ValueKey<String>('reader-image-close'),
                    tooltip: '关闭图片',
                    color: Colors.white,
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Expanded(
                child: InteractiveViewer(
                  key: const ValueKey<String>('reader-image-zoom'),
                  transformationController: _transform,
                  minScale: 1,
                  maxScale: 8,
                  child: Center(
                    child: Image(
                      image: widget.image,
                      fit: BoxFit.contain,
                      semanticLabel: widget.label,
                      errorBuilder: (_, _, _) => const Text(
                        '图片无法加载',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  '双指缩放 · 拖动查看',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
