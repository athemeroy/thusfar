import 'package:flutter/material.dart';

/// Secondary reader guidance is available on tap, including on touch devices.
class InfoButton extends StatelessWidget {
  const InfoButton({super.key, required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: '了解$title',
    icon: const Icon(Icons.info_outline, size: 20),
    onPressed: () => showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(message)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    ),
  );
}
