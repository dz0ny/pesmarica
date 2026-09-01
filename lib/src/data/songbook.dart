import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';

import '../model/settings.dart';
import '../model/song_page.dart';
import '../web/credentials.dart';

/// The on-disk songbook: a directory of numbered markdown files plus a
/// `settings.json`. Everything the app persists lives here, so the whole
/// installation is one folder you can rsync, back up, or put in git.
class Songbook extends ChangeNotifier {
  Songbook(this.root);

  final Directory root;

  List<SongPage> _pages = <SongPage>[];
  Settings _settings = const Settings();
  String? _error;

  List<SongPage> get pages => List<SongPage>.unmodifiable(_pages);
  Settings get settings => _settings;

  /// Last load/save failure, surfaced on screen instead of a blank display.
  String? get error => _error;

  File get settingsFile => File(p.join(root.path, 'settings.json'));
  Directory get mediaDir => Directory(p.join(root.path, 'images'));

  StreamSubscription<WatchEvent>? _watch;
  Timer? _reloadDebounce;
  final Map<String, DateTime> _selfWrites = <String, DateTime>{};
  final Map<String, Timer> _pendingScaleWrites = <String, Timer>{};

  Future<void> start() async {
    await root.create(recursive: true);
    await mediaDir.create(recursive: true);
    await reload();

    // Picking up edits from the web UI, an SSH session or a synced folder is
    // the same code path, so watch the directory rather than special-casing.
    _watch = DirectoryWatcher(root.path).events.listen(
      _onFileEvent,
      onError: (Object e) => debugPrint('pesmarica: watcher failed: $e'),
    );
  }

  void _onFileEvent(WatchEvent event) {
    final path = p.normalize(event.path);
    final recent = _selfWrites[path];
    if (recent != null && DateTime.now().difference(recent).inMilliseconds < 2000) {
      return; // Our own write echoing back.
    }
    if (path.endsWith('.tmp')) return;
    if (!path.endsWith('.md') && p.basename(path) != 'settings.json') return;

    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 250), reload);
  }

  Future<void> reload() async {
    try {
      _settings = await _adoptPassword(await _readSettings());
      _pages = await _readPages();
      _error = null;
    } on Object catch (e) {
      _error = '$e';
    }
    notifyListeners();
  }

  Future<Settings> _readSettings() async {
    if (!settingsFile.existsSync()) {
      await settingsFile.writeAsString(const Settings().encode());
      return const Settings();
    }
    try {
      return Settings.decode(await settingsFile.readAsString());
    } on Object catch (e) {
      debugPrint('pesmarica: settings.json unreadable ($e), using defaults');
      return const Settings();
    }
  }

  /// Turns a `password:` somebody typed into `settings.json` into a salted
  /// hash and rewrites the file without it. Leaving the plaintext sitting in a
  /// world-readable file on the Pi would be careless, and nothing needs it
  /// after this point.
  Future<Settings> _adoptPassword(Settings settings) async {
    final plaintext = settings.password;
    if (plaintext == null) return settings;

    final credentials = Credentials.forPassword(
      plaintext,
      salt: settings.passwordSalt,
    );
    final hashed = settings
        .copyWith(
          passwordHash: credentials.hash,
          passwordSalt: credentials.salt,
        )
        .withoutPlaintextPassword();
    await _write(settingsFile, hashed.encode());
    return hashed;
  }

  Future<List<SongPage>> _readPages() async {
    final files =
        root
            .listSync()
            .whereType<File>()
            .where((f) => p.extension(f.path).toLowerCase() == '.md')
            .where((f) => !p.basename(f.path).startsWith('.'))
            .toList()
          ..sort((a, b) => _compareFiles(a.path, b.path));

    final result = <SongPage>[];
    var fallback = 0;
    for (final file in files) {
      final explicit = SongPage.numberFromFileName(p.basename(file.path));
      // Files without a numeric prefix still get a slot, numbered after the
      // highest number seen so far, so a stray note never hides a page.
      final number = explicit ?? (++fallback);
      if (explicit != null && explicit > fallback) fallback = explicit;
      try {
        result.add(
          SongPage.parse(
            p.normalize(file.path),
            await file.readAsString(),
            number: number,
          ),
        );
      } on Object catch (e) {
        debugPrint('pesmarica: skipping ${file.path}: $e');
      }
    }
    return result;
  }

  static int _compareFiles(String a, String b) {
    final na = SongPage.numberFromFileName(p.basename(a));
    final nb = SongPage.numberFromFileName(p.basename(b));
    if (na != null && nb != null && na != nb) return na.compareTo(nb);
    if (na != null && nb == null) return -1;
    if (na == null && nb != null) return 1;
    return p.basename(a).toLowerCase().compareTo(p.basename(b).toLowerCase());
  }

  int indexOfNumber(int number) => _pages.indexWhere((p) => p.number == number);

  /// The page at [number], or the closest one at or above it, or null.
  int indexNearNumber(int number) {
    final exact = indexOfNumber(number);
    if (exact >= 0) return exact;
    final after = _pages.indexWhere((p) => p.number >= number);
    return after >= 0 ? after : (_pages.isEmpty ? -1 : _pages.length - 1);
  }

  // --- Writes -------------------------------------------------------------

  /// Writes through a temporary file and renames it into place.
  ///
  /// A signage box gets its power cut, and `writeAsString` truncates before it
  /// writes: losing the mains halfway through would otherwise leave an empty
  /// page or an empty settings.json behind. Rename is atomic on the same
  /// filesystem, so a reader sees either the old file or the new one.
  Future<void> _write(File file, String contents) async {
    final target = p.normalize(file.path);
    _selfWrites[target] = DateTime.now();

    final temp = File('$target.tmp');
    _selfWrites[p.normalize(temp.path)] = DateTime.now();
    await temp.writeAsString(contents, flush: true);
    await temp.rename(target);
    _selfWrites[target] = DateTime.now();
  }

  /// Applies a magnification change immediately in memory and flushes it to
  /// the markdown file once the operator stops pressing +/-.
  void setScale(SongPage page, double scale) {
    final updated = page.copyWith(scale: SongPage.clampScale(scale));
    final index = _pages.indexWhere((p) => p.path == page.path);
    if (index < 0) return;
    _pages = List<SongPage>.of(_pages)..[index] = updated;
    notifyListeners();

    _pendingScaleWrites[page.path]?.cancel();
    _pendingScaleWrites[page.path] = Timer(
      const Duration(milliseconds: 700),
      () async {
        _pendingScaleWrites.remove(page.path);
        try {
          await _write(File(updated.path), updated.toSource());
        } on Object catch (e) {
          debugPrint('pesmarica: could not persist scale: $e');
        }
      },
    );
  }

  /// Records that a page was actually put in front of an audience. Called
  /// once the page has been on screen long enough to count as "shown", so
  /// scrubbing past twenty pages does not rewrite twenty files.
  Future<void> markShown(SongPage page) async {
    final index = _pages.indexWhere((p) => p.path == page.path);
    if (index < 0) return;
    final current = _pages[index];
    final stamped = current.copyWith(
      lastShown: DateTime.now(),
      views: current.views + 1,
    );
    _pages = List<SongPage>.of(_pages)..[index] = stamped;
    try {
      await _write(File(stamped.path), stamped.toSource());
    } on Object catch (e) {
      debugPrint('pesmarica: could not record usage: $e');
    }
  }

  Future<void> saveSettings(Settings settings) async {
    _settings = settings;
    notifyListeners();
    await _write(settingsFile, settings.encode());
  }

  /// Replaces the raw source of a page (used by the web editor).
  Future<void> writeSource(int number, String source) async {
    final index = indexOfNumber(number);
    if (index < 0) throw ArgumentError('No page number $number');
    await _write(File(_pages[index].path), source);
    await reload();
  }

  /// Creates `NNN-slug.md`. Returns the page number that was used.
  Future<int> createPage({int? number, String? title, String? source}) async {
    final assigned = number ?? _nextFreeNumber();
    if (indexOfNumber(assigned) >= 0) {
      throw ArgumentError('Page $assigned already exists');
    }
    final slug = _slug(title ?? 'nova-stran');
    final file = File(
      p.join(root.path, '${assigned.toString().padLeft(3, '0')}-$slug.md'),
    );
    await _write(file, source ?? '# ${title ?? 'Nova stran'}\n\n');
    await reload();
    return assigned;
  }

  /// Takes a dropped `.md` file into the songbook.
  ///
  /// The number in the file name wins when it is free; otherwise the page is
  /// filed after the last one rather than refused, because someone dropping a
  /// folder of songs should not have to resolve collisions one by one.
  Future<int> importMarkdown(String fileName, String source) async {
    final wanted = SongPage.numberFromFileName(fileName);
    final free = wanted != null && indexOfNumber(wanted) < 0
        ? wanted
        : _nextFreeNumber();
    final slug = _slug(
      p.basenameWithoutExtension(fileName).replaceFirst(RegExp(r'^\d+[-_ ]*'), ''),
    );
    final file = File(
      p.join(root.path, '${free.toString().padLeft(3, '0')}-$slug.md'),
    );
    await _write(file, source);
    await reload();
    return free;
  }

  int _nextFreeNumber() =>
      _pages.isEmpty ? 1 : _pages.map((p) => p.number).reduce(math.max) + 1;

  Future<void> deletePage(int number) async {
    final index = indexOfNumber(number);
    if (index < 0) return;
    final file = File(_pages[index].path);
    _selfWrites[p.normalize(file.path)] = DateTime.now();
    if (file.existsSync()) await file.delete();
    await reload();
  }

  Future<File> saveImage(String fileName, List<int> bytes) async {
    await mediaDir.create(recursive: true);
    final safe = _slug(p.basenameWithoutExtension(fileName));
    final file = File(
      p.join(mediaDir.path, '$safe${p.extension(fileName).toLowerCase()}'),
    );
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  static String _slug(String input) {
    const from = 'čćšžđČĆŠŽĐáàäéèëíîóöúüý';
    const to = 'ccszdccszdaaaeeeiioouuy';
    final buffer = StringBuffer();
    for (final rune in input.trim().toLowerCase().runes) {
      final ch = String.fromCharCode(rune);
      final mapped = from.indexOf(ch);
      buffer.write(mapped >= 0 ? to[mapped] : ch);
    }
    final slug = buffer
        .toString()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'stran' : slug;
  }

  @override
  void dispose() {
    _watch?.cancel();
    _reloadDebounce?.cancel();
    for (final timer in _pendingScaleWrites.values) {
      timer.cancel();
    }
    super.dispose();
  }
}
