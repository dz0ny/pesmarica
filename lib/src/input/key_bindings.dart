import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../data/presenter.dart';

/// Translates raw key events into presenter actions.
///
/// Deliberately layout-tolerant: page numbers and +/- are matched on the
/// produced character rather than the physical key, so a Slovenian keyboard,
/// a numeric keypad and a cheap presenter remote all behave the same.
class KeyBindings {
  const KeyBindings(this.presenter);

  final Presenter presenter;

  KeyEventResult handle(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    final char = event.character;

    // --- Number entry ---
    if (char != null && char.length == 1 && _isDigit(char)) {
      presenter.typeDigit(char);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.select) {
      if (!presenter.commitNumberEntry()) presenter.next();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.backspace) {
      if (presenter.numberBuffer.isEmpty) {
        presenter.previous();
      } else {
        presenter.backspace();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape) {
      if (presenter.helpVisible) {
        presenter.toggleHelp();
      } else {
        presenter.cancelNumberEntry();
      }
      return KeyEventResult.handled;
    }

    // --- Navigation ---
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaTrackNext) {
      presenter.next();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      presenter.previous();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.home) {
      presenter.first();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      presenter.last();
      return KeyEventResult.handled;
    }

    // --- Magnification ---
    if (char == '+' || key == LogicalKeyboardKey.numpadAdd) {
      presenter.zoom(1);
      return KeyEventResult.handled;
    }
    if (char == '-' ||
        char == '−' ||
        key == LogicalKeyboardKey.numpadSubtract) {
      presenter.zoom(-1);
      return KeyEventResult.handled;
    }

    // --- Presentation toggles ---
    switch (char?.toLowerCase()) {
      case 'r':
        presenter.resetZoom();
        return KeyEventResult.handled;
      case 'b':
        presenter.toggleTheme();
        return KeyEventResult.handled;
      case 'f':
        presenter.cycleFont();
        return KeyEventResult.handled;
      case 't':
        presenter.toggleTitle();
        return KeyEventResult.handled;
      case 'c':
        presenter.toggleChrome();
        return KeyEventResult.handled;
      case '?':
      case 'h':
        presenter.toggleHelp();
        return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.f1) {
      presenter.toggleHelp();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  static bool _isDigit(String c) {
    final code = c.codeUnitAt(0);
    return code >= 0x30 && code <= 0x39;
  }
}
