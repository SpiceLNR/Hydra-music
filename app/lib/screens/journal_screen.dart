import 'package:flutter/material.dart';

import '../net_service.dart';
import '../theme.dart';

/// Журнал сети: когда и что происходило при сопряжении и синхронизации.
class JournalScreen extends StatelessWidget {
  const JournalScreen({super.key});

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _line(String raw) {
    final tab = raw.indexOf('\t');
    final ms = tab > 0 ? int.tryParse(raw.substring(0, tab)) : null;
    if (ms == null) {
      return raw;
    }
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final stamp =
        '${_two(t.day)}.${_two(t.month)} ${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
    return '$stamp  ${raw.substring(tab + 1)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('журнал')),
      body: ListenableBuilder(
        listenable: hydraNet,
        builder: (context, _) {
          final lines = hydraNet.log.reversed.map(_line).toList();
          if (lines.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Журнал пока пуст.'),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              SelectableText(
                lines.join('\n\n'),
                style: const TextStyle(fontSize: 13, color: Metro.textDim),
              ),
            ],
          );
        },
      ),
    );
  }
}
