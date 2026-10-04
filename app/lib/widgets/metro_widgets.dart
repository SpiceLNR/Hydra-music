import 'package:flutter/material.dart';
import '../theme.dart';

/// Плоская плитка-кнопка в стиле Metro.
class MetroTile extends StatelessWidget {
  const MetroTile({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.color = Metro.green,
    this.subtitle,
  });

  final String label;
  final String? subtitle;
  final IconData icon;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(icon, size: 40, color: Colors.white),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white)),
                  if (subtitle != null)
                    Text(subtitle!,
                        style: const TextStyle(fontSize: 13, color: Colors.white70)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Диалог подтверждения (удаление, перемещение). Возвращает true, если пользователь согласился.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Да',
  bool danger = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w300, fontSize: 24)),
      content: Text(message),
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
        ElevatedButton(
          style: danger ? ElevatedButton.styleFrom(backgroundColor: Metro.danger) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Крупный заголовок раздела.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Text(text.toLowerCase(), style: Theme.of(context).textTheme.headlineLarge),
      );
}

/// Обложка трека; для видеоконтейнеров показываем киноплёнку.
class Cover extends StatelessWidget {
  const Cover({super.key, required this.isVideo, this.size = 56});
  final bool isVideo;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        color: Metro.greenDark,
        child: Icon(isVideo ? Icons.movie_outlined : Icons.music_note,
            color: Colors.white, size: size * 0.55),
      );
}
