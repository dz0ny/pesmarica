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
    required this.slideshow,
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

  /// How long each image stays up on a page that is nothing but images, or
  /// null when the page does not cycle. Only ever set from `slideshow:`.
  final Duration? slideshow;

  /// Front matter keys Pesmarica does not interpret, preserved on rewrite.
  final Map<String, Object?> extra;

  static const double minScale = 0.4;
  static const double maxScale = 4.0;

  static const Duration defaultSlideshow = Duration(seconds: 5);
  static const int minSlideshowSeconds = 1;
  static const int maxSlideshowSeconds = 120;

  /// One image on a line of its own, which is the only shape an image page is
  /// written in: markdown that puts an image inside a paragraph is prose.
  static final RegExp _imageLine = RegExp(
    r'^!\[[^\]]*\]\(\s*<?([^)>]+?)>?(?:\s+"[^"]*")?\s*\)$',
  );

  /// The images of a page whose body holds nothing else, in the order they are
  /// written; empty for every other page. A page that mixes an image into its
  /// text is prose with a picture in it and keeps the ordinary layout.
  late final List<String> images = _parseImages(body);

  bool get isImagePage => images.isNotEmpty;

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
      ..remove('slideshow')
      // Not fields any more, and not preserved either: pages written by an
      // older Pesmarica carry a view counter and a timestamp that nothing reads.
      // Dropping them here means they disappear the next time a human edits the
      // page, which costs no write of its own.
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
      slideshow: _slideshow(matter.values['slideshow']),
      extra: extra,
    );
  }

  static List<String> _parseImages(String body) {
    final images = <String>[];
    for (final line in body.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final match = _imageLine.firstMatch(trimmed);
      if (match == null) return const <String>[];
      images.add(match.group(1)!.trim());
    }
    return images;
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

  /// `slideshow: 5` is five seconds; a bare `true` takes the default. Anything
  /// else -- absent, false, nonsense -- means the page does not cycle.
  static Duration? _slideshow(Object? raw) {
    if (raw is bool) return raw ? defaultSlideshow : null;
    final text = '${raw ?? ''}'.trim();
    if (text.isEmpty) return null;
    final seconds = num.tryParse(text);
    if (seconds != null) {
      if (!seconds.isFinite || seconds <= 0) return null;
      return Duration(
        seconds: seconds
            .round()
            .clamp(minSlideshowSeconds, maxSlideshowSeconds),
      );
    }
    return _bool(raw) == true ? defaultSlideshow : null;
  }

  static double clampScale(double value) =>
      value.isFinite ? value.clamp(minScale, maxScale) : 1.0;

  /// Rebuilds the file contents, keeping unknown front matter keys intact.
  String toSource({
    double? scale,
    PageAlign? align,
    String? body,
  }) {
    final effectiveScale = clampScale(scale ?? this.scale);
    final effectiveAlign = align ?? this.align;
    final values = <String, Object?>{
      'title': declaredTitle,
      ...extra,
      // Trailing digits make the file churn on every keypress; keep it short.
      'scale': effectiveScale == 1.0
          ? null
          : double.parse(effectiveScale.toStringAsFixed(2)),
      'align': effectiveAlign == PageAlign.center ? 'center' : null,
      'showTitle': showTitle,
      'slideshow': slideshow?.inSeconds,
    };
    return FrontMatter.compose(values, body ?? this.body);
  }

  /// [clearTitle] and [clearShowTitle] are how a caller says "back to the
  /// default" rather than "leave it alone": both fields mean something when
  /// they are null -- the title falls back to the body heading, and showTitle
  /// falls back to the songbook-wide switch -- so null cannot also mean
  /// "unchanged". Same shape as `Settings.copyWith(clearPassword:)`.
  SongPage copyWith({
    String? declaredTitle,
    double? scale,
    PageAlign? align,
    bool? showTitle,
    Duration? slideshow,
    String? body,
    bool clearTitle = false,
    bool clearShowTitle = false,
    bool clearSlideshow = false,
  }) {
    final nextTitle = clearTitle ? null : (declaredTitle ?? this.declaredTitle);
    final nextBody = body ?? this.body;
    return SongPage(
      number: number,
      path: path,
      declaredTitle: nextTitle,
      title: nextTitle ?? _derivedTitle(nextBody, path),
      body: nextBody,
      scale: scale == null ? this.scale : clampScale(scale),
      align: align ?? this.align,
      showTitle: clearShowTitle ? null : (showTitle ?? this.showTitle),
      slideshow: clearSlideshow ? null : (slideshow ?? this.slideshow),
      extra: extra,
    );
  }
}
