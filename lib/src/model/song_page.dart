import 'package:path/path.dart' as p;

import '../data/front_matter.dart';

/// How a page positions its content in the available space.
enum PageAlign { start, center }

/// One markdown document = one page of the songbook.
class SongPage {
  SongPage({
    required this.number,
    required this.path,
    required this.declaredTitle,
    required this.title,
    required this.body,
    required this.scale,
    required this.align,
    required this.showTitle,
    required this.lastShown,
    required this.views,
    required this.extra,
  });

  /// The number the audience sees and the operator types on the keypad.
  final int number;

  /// Absolute path of the backing `.md` file.
  final String path;

  /// `title:` as written in the front matter, or null if the file has none.
  /// Kept separate from [title] so that rewriting a page does not silently
  /// promote a body heading into the header.
  final String? declaredTitle;

  /// Display title: front matter, else the first heading, else the file slug.
  final String title;

  /// Markdown source with the front matter stripped off.
  final String body;

  /// Per-page magnification, persisted back into the front matter.
  final double scale;

  final PageAlign align;

  /// Whether the title is shown on screen for this page. `null` means "follow
  /// the songbook default" — a page only pins it when it needs to differ, so
  /// flipping the global switch still moves every ordinary page.
  final bool? showTitle;

  /// When this page was last put on screen. Written back to the front matter
  /// so usage survives restarts and shows up in the web list ("nazadnje").
  final DateTime? lastShown;

  /// How many times the page has been shown, ever.
  final int views;

  /// Front matter keys Pesmarica does not interpret, preserved on rewrite.
  final Map<String, Object?> extra;

  static const double minScale = 0.4;
  static const double maxScale = 4.0;

  String get fileName => p.basename(path);

  /// Numbers come from the file name prefix (`012-nekaj.md` -> 12) so that the
  /// operator's keypad and the file system agree without a separate index.
  static int? numberFromFileName(String fileName) {
    final match = RegExp(
      r'^(\d+)',
    ).firstMatch(p.basenameWithoutExtension(fileName));
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  static SongPage parse(String path, String source, {required int number}) {
    final matter = FrontMatter.parse(source);
    final extra = Map<String, Object?>.from(matter.values)
      ..remove('title')
      ..remove('scale')
      ..remove('align')
      ..remove('showTitle')
      ..remove('lastShown')
      ..remove('views');

    final declared = matter.values['title']?.toString().trim();

    return SongPage(
      number: number,
      path: path,
      declaredTitle: (declared == null || declared.isEmpty) ? null : declared,
      title: declared != null && declared.isNotEmpty
          ? declared
          : _derivedTitle(matter.body, path),
      body: matter.body,
      scale: _scale(matter.values['scale']),
      align: '${matter.values['align']}' == 'center'
          ? PageAlign.center
          : PageAlign.start,
      showTitle: _bool(matter.values['showTitle']),
      lastShown: _dateTime(matter.values['lastShown']),
      views: _int(matter.values['views']),
      extra: extra,
    );
  }

  static String _derivedTitle(String body, String path) {
    for (final line in body.split('\n')) {
      final heading = RegExp(r'^#{1,6}\s+(.*\S)').firstMatch(line.trim());
      if (heading != null) return heading.group(1)!;
    }
    final slug = p
        .basenameWithoutExtension(path)
        .replaceFirst(RegExp(r'^\d+[-_ ]*'), '');
    return slug.isEmpty
        ? p.basenameWithoutExtension(path)
        : slug.replaceAll('-', ' ');
  }

  static double _scale(Object? raw) {
    final value = raw is num ? raw.toDouble() : double.tryParse('${raw ?? ''}');
    return clampScale(value ?? 1.0);
  }

  static bool? _bool(Object? raw) {
    if (raw is bool) return raw;
    switch ('${raw ?? ''}'.trim().toLowerCase()) {
      case 'true' || 'yes' || 'da' || '1':
        return true;
      case 'false' || 'no' || 'ne' || '0':
        return false;
      default:
        return null;
    }
  }

  static DateTime? _dateTime(Object? raw) {
    if (raw is DateTime) return raw;
    if (raw == null) return null;
    return DateTime.tryParse('$raw');
  }

  static int _int(Object? raw) =>
      raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}') ?? 0;

  static double clampScale(double value) =>
      value.isFinite ? value.clamp(minScale, maxScale) : 1.0;

  /// Rebuilds the file contents, keeping unknown front matter keys intact.
  String toSource({
    double? scale,
    PageAlign? align,
    String? body,
    DateTime? lastShown,
    int? views,
  }) {
    final effectiveScale = clampScale(scale ?? this.scale);
    final effectiveAlign = align ?? this.align;
    final effectiveViews = views ?? this.views;
    final values = <String, Object?>{
      'title': declaredTitle,
      ...extra,
      // Trailing digits make the file churn on every keypress; keep it short.
      'scale': effectiveScale == 1.0
          ? null
          : double.parse(effectiveScale.toStringAsFixed(2)),
      'align': effectiveAlign == PageAlign.center ? 'center' : null,
      'showTitle': showTitle,
      'lastShown': (lastShown ?? this.lastShown)?.toUtc().toIso8601String(),
      'views': effectiveViews == 0 ? null : effectiveViews,
    };
    return FrontMatter.compose(values, body ?? this.body);
  }

  SongPage copyWith({
    double? scale,
    PageAlign? align,
    DateTime? lastShown,
    int? views,
  }) => SongPage(
    number: number,
    path: path,
    declaredTitle: declaredTitle,
    title: title,
    body: body,
    scale: scale == null ? this.scale : clampScale(scale),
    align: align ?? this.align,
    showTitle: showTitle,
    lastShown: lastShown ?? this.lastShown,
    views: views ?? this.views,
    extra: extra,
  );
}
