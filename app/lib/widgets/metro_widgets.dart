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

/// Переключатель в стиле Metro: прямоугольная рамка и прямоугольный ползунок.
/// «Выкл» - рамка и ползунок слева; «Вкл» - зелёная заливка, ползунок справа.
class MetroToggle extends StatelessWidget {
  const MetroToggle({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 52,
          height: 24,
          decoration: BoxDecoration(
            color: value ? Metro.green : Colors.transparent,
            border: Border.all(color: value ? Metro.green : Colors.white70, width: 2),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 150),
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(width: 14, margin: const EdgeInsets.all(2), color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// Строка настроек: название слева, «Вкл/Выкл» и переключатель справа.
class MetroSwitchRow extends StatelessWidget {
  const MetroSwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            Expanded(child: Text(title, style: const TextStyle(fontSize: 18))),
            Text(value ? 'Вкл' : 'Выкл',
                style: const TextStyle(fontSize: 16, color: Metro.textDim)),
            const SizedBox(width: 12),
            MetroToggle(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}

/// Полоса позиции: тонкая линия и прямоугольный ползунок, без скруглений.
/// Нажатие в любом месте перематывает, ползунок можно тянуть.
class MetroSlider extends StatelessWidget {
  const MetroSlider({
    super.key,
    required this.value,
    required this.max,
    required this.onChanged,
    this.onChangeEnd,
    this.color = Metro.green,
  });

  final double value;
  final double max;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final frac = max <= 0 ? 0.0 : (value / max).clamp(0.0, 1.0).toDouble();
        final thumbLeft = (w * frac - 5).clamp(0.0, w > 10 ? w - 10 : 0.0).toDouble();

        double toValue(double dx) {
          final f = (dx / (w <= 0 ? 1 : w)).clamp(0.0, 1.0).toDouble();
          return f * max;
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            final v = toValue(d.localPosition.dx);
            onChanged(v);
            onChangeEnd?.call(v);
          },
          onHorizontalDragUpdate: (d) => onChanged(toValue(d.localPosition.dx)),
          onHorizontalDragEnd: (_) => onChangeEnd?.call(value),
          child: SizedBox(
            height: 40,
            width: double.infinity,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(height: 4, color: Colors.white24),
                Container(width: w * frac, height: 4, color: color),
                Positioned(
                  left: thumbLeft,
                  child: Container(width: 10, height: 24, color: Colors.white),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Индикатор ожидания в стиле Metro: пять квадратиков «пролетают» слева направо.
class MetroProgress extends StatefulWidget {
  const MetroProgress({super.key});

  @override
  State<MetroProgress> createState() => _MetroProgressState();
}

class _MetroProgressState extends State<MetroProgress> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  double _x(double w, int i) {
    var t = _c.value - i * 0.05;
    if (t < 0) t += 1;
    return -6 + (w + 6) * Curves.easeInOut.transform(t);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 6,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          return AnimatedBuilder(
            animation: _c,
            builder: (context, _) => Stack(
              children: [
                for (var i = 0; i < 5; i++)
                  Positioned(
                    left: _x(w, i),
                    top: 1,
                    child: const SizedBox(
                      width: 4,
                      height: 4,
                      child: ColoredBox(color: Metro.green),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Компактная кнопка «значок и подпись» для нижней панели действий. Без скруглений.
/// Помещайте в [Expanded]: подпись сама уменьшается, если не помещается.
class MetroAction extends StatelessWidget {
  const MetroAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.filled = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  /// Зелёная заливка для главного действия.
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Material(
        color: filled ? Metro.green : Metro.surface,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            height: 56,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 22, color: Colors.white),
                  const SizedBox(height: 2),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(label, style: const TextStyle(fontSize: 12, color: Colors.white)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
