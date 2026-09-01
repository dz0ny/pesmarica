import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../model/settings.dart';

/// The two-colour palette the whole app is drawn with. Signage lives or dies
/// on contrast, so there are exactly two colours plus one muted tone.
class PagePalette {
  const PagePalette({
    required this.background,
    required this.foreground,
    required this.muted,
  });

  final Color background;
  final Color foreground;
  final Color muted;

  static const PagePalette light = PagePalette(
    background: Color(0xFFFFFFFF),
    foreground: Color(0xFF0B0B0B),
    muted: Color(0xFF767676),
  );

  static const PagePalette dark = PagePalette(
    background: Color(0xFF000000),
    foreground: Color(0xFFF4F4F4),
    muted: Color(0xFF8C8C8C),
  );

  static PagePalette of(PageTheme theme) =>
      theme == PageTheme.light ? light : dark;
}

/// Bundled families are variable fonts, so weight has to be set through
/// [FontVariation] as well as [FontWeight] — the latter alone only picks a
/// named instance, which a single-file variable font does not have.
TextStyle fontStyle({
  required AppFont font,
  required double size,
  required Color color,
  FontWeight weight = FontWeight.w400,
  FontStyle style = FontStyle.normal,
  double height = 1.35,
}) => TextStyle(
  fontFamily: font.family,
  fontSize: size,
  color: color,
  fontWeight: weight,
  fontStyle: style,
  height: height,
  fontVariations: <FontVariation>[FontVariation('wght', weight.value.toDouble())],
  // Lyrics are read at a distance; a touch of extra tracking helps.
  letterSpacing: size * 0.002,
);

/// Markdown styling scaled off a single base size, so magnification moves
/// headings, body text and spacing together.
MarkdownStyleSheet markdownStyles({
  required AppFont font,
  required PagePalette palette,
  required double base,
}) {
  TextStyle t(
    double factor, {
    FontWeight weight = FontWeight.w400,
    Color? color,
    FontStyle style = FontStyle.normal,
    double height = 1.35,
  }) => fontStyle(
    font: font,
    size: base * factor,
    color: color ?? palette.foreground,
    weight: weight,
    style: style,
    height: height,
  );

  final gap = base * 0.55;

  return MarkdownStyleSheet(
    p: t(1.0),
    h1: t(1.6, weight: FontWeight.w700, height: 1.15),
    h2: t(1.3, weight: FontWeight.w600, height: 1.2),
    h3: t(1.15, weight: FontWeight.w600, height: 1.25),
    h4: t(1.05, weight: FontWeight.w600),
    h5: t(1.0, weight: FontWeight.w600),
    h6: t(0.95, weight: FontWeight.w600, color: palette.muted),
    em: t(1.0, style: FontStyle.italic),
    strong: t(1.0, weight: FontWeight.w700),
    blockquote: t(1.0, style: FontStyle.italic, color: palette.muted),
    listBullet: t(1.0),
    code: TextStyle(
      fontFamily: 'monospace',
      fontSize: base * 0.9,
      color: palette.foreground,
    ),
    a: t(1.0, color: palette.muted),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(
        top: BorderSide(width: base * 0.03, color: palette.muted),
      ),
    ),
    blockquoteDecoration: BoxDecoration(
      border: Border(
        left: BorderSide(width: base * 0.09, color: palette.muted),
      ),
    ),
    blockquotePadding: EdgeInsets.only(left: base * 0.6),
    pPadding: EdgeInsets.only(bottom: gap),
    h1Padding: EdgeInsets.only(bottom: gap * 0.6),
    h2Padding: EdgeInsets.only(top: gap * 0.6, bottom: gap * 0.4),
    h3Padding: EdgeInsets.only(top: gap * 0.5, bottom: gap * 0.3),
    listIndent: base * 1.2,
    blockSpacing: gap,
    textAlign: WrapAlignment.start,
    h1Align: WrapAlignment.start,
  );
}
