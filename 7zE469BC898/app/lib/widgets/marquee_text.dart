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

  late final AnimationController _controller = AnimationController(vsync: this);
  double _overflow = 0;
  bool _running = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _sync(double overflow, bool run) {
    if (!mounted) return;
    if (!run) {
      if (_running) {
        _controller
          ..stop()
          ..value = 0;
        _running = false;
      }
      return;
    }
    if (_running && (overflow - _overflow).abs() < 1) return;
    _overflow = overflow;
    final scroll = overflow / _pxPerSecond;
    _controller.duration =
        Duration(milliseconds: ((scroll + 2 * _pauseSeconds) * 1000).round());
    _controller.repeat();
    _running = true;
  }

  /// Положение (0..overflow) в момент анимации [t]: пауза, прокрутка, пауза, возврат в начало.
  double _offset(double t) {
    final total = _controller.duration!.inMilliseconds / 1000.0;
    final scroll = _overflow / _pxPerSecond;
    final sec = t * total;
    if (sec < _pauseSeconds) return 0;
    if (sec > _pauseSeconds + scroll) return _overflow;
    return _overflow * ((sec - _pauseSeconds) / scroll);
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
      return ClipRect(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) => Transform.translate(
            offset: Offset(-(_running ? _offset(_controller.value) : 0), 0),
            child: child,
          ),
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            minWidth: 0,
            maxWidth: double.infinity,
            child: Text(widget.text, style: style, maxLines: 1, softWrap: false),
          ),
        ),
      );
    });
  }
}
