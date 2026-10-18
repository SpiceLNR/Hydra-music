import 'package:flutter/material.dart';

/// Одна строка текста фиксированной высоты. Если [active] и текст не помещается,
/// он плавно едет справа налево как бегущая строка, иначе обрезается многоточием.
class MarqueeText extends StatefulWidget {
  const MarqueeText(this.text, {super.key, this.style, this.active = false});

  final String text;
  final TextStyle? style;
  final bool active;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText> with SingleTickerProviderStateMixin {
  static const double _pxPerSecond = 40;
  static const double _pauseSeconds = 1.2;

  final ScrollController _scroll = ScrollController();
  late final AnimationController _controller = AnimationController(vsync: this)
    ..addListener(_tick);
  double _overflow = 0;
  bool _running = false;

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Положение прокрутки: пауза, движение, пауза, возврат в начало.
  void _tick() {
    if (!_scroll.hasClients || _overflow <= 0 || _controller.duration == null) return;
    final total = _controller.duration!.inMilliseconds / 1000.0;
    final scroll = _overflow / _pxPerSecond;
    final sec = _controller.value * total;
    double offset;
    if (sec < _pauseSeconds) {
      offset = 0;
    } else if (sec > _pauseSeconds + scroll) {
      offset = _overflow;
    } else {
      offset = _overflow * ((sec - _pauseSeconds) / scroll);
    }
    final max = _scroll.position.maxScrollExtent;
    _scroll.jumpTo(offset.clamp(0.0, max));
  }

  void _sync(double overflow, bool run) {
    if (!mounted) return;
    if (!run) {
      if (_running) {
        _controller.stop();
        _controller.value = 0;
        _running = false;
      }
      return;
    }
    if (_running && (overflow - _overflow).abs() < 1) return;
    _overflow = overflow;
    final scroll = overflow / _pxPerSecond;
    _controller.duration = Duration(milliseconds: ((scroll + 2 * _pauseSeconds) * 1000).round());
    _controller.repeat();
    _running = true;
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style ?? DefaultTextStyle.of(context).style;
    return LayoutBuilder(builder: (context, constraints) {
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: style),
        maxLines: 1,
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final overflow = painter.width - constraints.maxWidth;
      final run = widget.active && overflow > 1;
      WidgetsBinding.instance.addPostFrameCallback((_) => _sync(overflow, run));
      if (!run) {
        return Text(widget.text, style: style, maxLines: 1, overflow: TextOverflow.ellipsis);
      }
      // горизонтальная прокрутка без жестов: она сама даёт тексту нужную ширину и
      // не требует ограниченной высоты (внутри ListTile высота не ограничена)
      return ClipRect(
        child: SingleChildScrollView(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          child: Text(widget.text, style: style, maxLines: 1, softWrap: false),
        ),
      );
    });
  }
}
