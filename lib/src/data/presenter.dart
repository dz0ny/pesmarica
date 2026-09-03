import 'dart:async';

import 'package:flutter/foundation.dart';

import '../model/settings.dart';
import '../model/song_page.dart';
import 'songbook.dart';

/// Drives what is on screen right now: which page, what the operator has
/// half-typed on the keypad, and whether the help card is up.
class Presenter extends ChangeNotifier {
  Presenter(this.songbook) {
    songbook.addListener(_onSongbookChanged);
  }

  final Songbook songbook;

  int _index = 0;
  String _numberBuffer = '';
  Timer? _numberTimeout;
  bool _helpVisible = false;
  double _liveScale = 1.0;
  String? _flash;
  Timer? _flashTimer;

  /// How long a half-typed page number stays on screen before it is discarded.
  static const Duration numberEntryTimeout = Duration(seconds: 3);

  int get index => _index;
  bool get helpVisible => _helpVisible;

  /// The transient multiplier the remote has dialled in, 1.0 when untouched.
  double get liveScale => _liveScale;

  /// Digits typed so far, empty when no jump is in progress.
  String get numberBuffer => _numberBuffer;

  /// Short-lived status text ("Povečava 130 %"), null when nothing to show.
  String? get flash => _flash;

  List<SongPage> get pages => songbook.pages;
  Settings get settings => songbook.settings;

  SongPage? get current =>
      _index >= 0 && _index < pages.length ? pages[_index] : null;

  /// Page magnification times the global multiplier times whatever the remote
  /// has nudged it to for as long as this page is up.
  double get effectiveScale =>
      (current?.scale ?? 1.0) * settings.baseScale * _liveScale;

  void _onSongbookChanged() {
    // Keep showing the same page number across reloads where we can; the file
    // list may have shifted underneath us while the operator was not looking.
    final wanted = _lastNumber;
    if (wanted != null) {
      final found = songbook.indexNearNumber(wanted);
      if (found >= 0) _index = found;
    }
    _index = pages.isEmpty ? 0 : _index.clamp(0, pages.length - 1);
    notifyListeners();
  }

  int? _lastNumber;

  /// Showing a page writes nothing. The display used to stamp a view counter
  /// and a timestamp into the front matter after a dwell, which meant a service
  /// wrote to the card every few minutes to record something nobody read.
  void _settle(int index) {
    if (pages.isEmpty) return;
    final was = current?.path;
    _index = index.clamp(0, pages.length - 1);
    _lastNumber = pages[_index].number;
    // The live zoom belongs to the page that is up, not to the screen: the
    // next song was written by somebody else and fits differently.
    if (pages[_index].path != was) _liveScale = 1.0;
    notifyListeners();
  }

  void next() => _settle(_index + 1);

  void previous() => _settle(_index - 1);

  void first() => _settle(0);

  void last() => _settle(pages.length - 1);

  /// Jumps to a page by its printed number, as the web remote does.
  bool goToNumber(int number) {
    final index = songbook.indexOfNumber(number);
    if (index < 0) {
      showFlash('Ni strani $number');
      return false;
    }
    _settle(index);
    return true;
  }

  // --- Keypad -------------------------------------------------------------

  void typeDigit(String digit) {
    if (_numberBuffer.length >= 5) return;
    _numberBuffer += digit;
    _restartNumberTimeout();
    notifyListeners();
  }

  void backspace() {
    if (_numberBuffer.isEmpty) return;
    _numberBuffer = _numberBuffer.substring(0, _numberBuffer.length - 1);
    if (_numberBuffer.isEmpty) {
      _numberTimeout?.cancel();
    } else {
      _restartNumberTimeout();
    }
    notifyListeners();
  }

  void cancelNumberEntry() {
    if (_numberBuffer.isEmpty) return;
    _numberBuffer = '';
    _numberTimeout?.cancel();
    notifyListeners();
  }

  /// Commits the typed digits. Returns false when nothing was pending, so the
  /// caller can treat Enter as "next page" instead.
  bool commitNumberEntry() {
    if (_numberBuffer.isEmpty) return false;
    final number = int.tryParse(_numberBuffer);
    _numberBuffer = '';
    _numberTimeout?.cancel();
    if (number != null) goToNumber(number);
    notifyListeners();
    return true;
  }

  void _restartNumberTimeout() {
    _numberTimeout?.cancel();
    // PowerPoint waits for Enter forever; on a wall display a forgotten "12"
    // sitting in the corner looks broken, so time it out instead.
    _numberTimeout = Timer(numberEntryTimeout, () {
      if (_numberBuffer.isEmpty) return;
      _numberBuffer = '';
      notifyListeners();
    });
  }

  // --- Presentation -------------------------------------------------------

  static const double scaleStep = 0.1;

  void zoom(int steps) {
    final page = current;
    if (page == null) return;
    final target = SongPage.clampScale(page.scale + scaleStep * steps);
    songbook.setScale(page, target);
    showFlash('Povečava ${(target * 100).round()} %');
  }

  /// Magnifies what is on screen right now and writes nothing.
  ///
  /// This is the remote's zoom, and the remote is open to everyone in the
  /// hall. It may not touch the card for two reasons that happen to agree: an
  /// unlocked call must not be able to rewrite the songbook, and the display
  /// path never writes at all -- the box runs off an SD card in a room that
  /// browns out every winter. The persistent per-page zoom is a different
  /// thing, lives in the front matter, and is set by a human at /manage.
  void nudgeZoom(int steps) {
    if (current == null) return;
    // Keep the factor on the step grid: a hundred taps of + and - should end
    // up back at exactly 1.0, not at something that only looks like it.
    final stepped = ((_liveScale + scaleStep * steps) * 100).roundToDouble() / 100;
    final target = SongPage.clampScale(stepped);
    if (target == _liveScale) return;
    _liveScale = target;
    showFlash('Povečava ${(effectiveScale * 100).round()} %');
  }

  /// Drops the transient zoom, leaving the page's own magnification alone.
  void clearLiveZoom() {
    if (_liveScale == 1.0) return;
    _liveScale = 1.0;
    showFlash('Povečava ${(effectiveScale * 100).round()} %');
  }

  void resetZoom() {
    final page = current;
    if (page == null) return;
    _liveScale = 1.0;
    if (page.scale != 1.0) songbook.setScale(page, 1.0);
    showFlash('Povečava ${(settings.baseScale * 100).round()} %');
  }

  Future<void> toggleTheme() async {
    final next = settings.theme.flipped;
    await songbook.saveSettings(settings.copyWith(theme: next));
    showFlash(next == PageTheme.dark ? 'Belo na črnem' : 'Črno na belem');
  }

  Future<void> cycleFont({int step = 1}) async {
    final fonts = AppFont.all;
    final at = fonts.indexWhere((f) => f.id == settings.fontId);
    final next = fonts[(at + step) % fonts.length];
    await songbook.saveSettings(settings.copyWith(fontId: next.id));
    showFlash(next.label);
  }

  /// Flips the songbook-wide title default. Pages that pin `showTitle:` in
  /// their own front matter keep their own answer.
  Future<void> toggleTitle() async {
    final next = !settings.showTitle;
    await songbook.saveSettings(settings.copyWith(showTitle: next));
    showFlash(next ? 'Naslovi vklopljeni' : 'Naslovi izklopljeni');
  }

  Future<void> toggleChrome() async {
    await songbook.saveSettings(
      settings.copyWith(showChrome: !settings.showChrome),
    );
  }

  void toggleHelp() {
    _helpVisible = !_helpVisible;
    notifyListeners();
  }

  void showFlash(String message) {
    _flash = message;
    notifyListeners();
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 1600), () {
      _flash = null;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    songbook.removeListener(_onSongbookChanged);
    _numberTimeout?.cancel();
    _flashTimer?.cancel();
    super.dispose();
  }
}
