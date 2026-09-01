import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Shrinks its child until it fits the available height.
///
/// Markdown reflows as the font size changes, so the fitting font size cannot
/// be computed in one step — this converges over a couple of frames and keeps
/// the child hidden until it has settled, which is invisible in practice
/// because it only re-runs when the page, the zoom or the window changes.
class AutoFit extends StatefulWidget {
  const AutoFit({
    super.key,
    required this.baseSize,
    required this.builder,
    this.minSize = 8,
    this.signature,
  });

  /// Font size to start from: the size the page gets when it already fits.
  final double baseSize;

  /// Never shrink below this, scroll instead.
  final double minSize;

  final Widget Function(BuildContext context, double fontSize) builder;

  /// Changing this restarts the fit — pass whatever identifies the content.
  final Object? signature;

  @override
  State<AutoFit> createState() => _AutoFitState();
}

class _AutoFitState extends State<AutoFit> {
  final GlobalKey _contentKey = GlobalKey();
  late double _size = widget.baseSize;
  bool _settled = false;
  double _viewport = 0;
  int _passes = 0;

  static const int _maxPasses = 8;

  @override
  void didUpdateWidget(AutoFit old) {
    super.didUpdateWidget(old);
    if (old.signature != widget.signature || old.baseSize != widget.baseSize) {
      _restart();
    }
  }

  void _restart() {
    _size = widget.baseSize;
    _settled = false;
    _passes = 0;
  }

  void _measure() {
    final box = _contentKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || _viewport <= 0) return;

    final height = box.size.height;
    final overflow = height - _viewport;

    if (overflow > 0.5 && _size > widget.minSize && _passes < _maxPasses) {
      // Undershoot slightly: reflow after a shrink usually frees a little more
      // height than the linear estimate, and overshooting looks worse than one
      // extra pass.
      final next = (_size * (_viewport / height) * 0.985).clamp(
        widget.minSize,
        widget.baseSize,
      );
      if ((next - _size).abs() > 0.2) {
        setState(() {
          _size = next;
          _passes++;
        });
        return;
      }
    }
    if (!_settled) setState(() => _settled = true);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (_viewport != constraints.maxHeight) {
          _viewport = constraints.maxHeight;
          _restart();
        }
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (mounted) _measure();
        });

        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.topCenter,
            minHeight: 0,
            maxHeight: double.infinity,
            child: AnimatedOpacity(
              opacity: _settled ? 1 : 0,
              duration: const Duration(milliseconds: 120),
              child: KeyedSubtree(
                key: _contentKey,
                child: widget.builder(context, _size),
              ),
            ),
          ),
        );
      },
    );
  }
}
