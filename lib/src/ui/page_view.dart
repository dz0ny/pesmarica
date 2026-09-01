import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:path/path.dart' as p;

import '../model/settings.dart';
import '../model/song_page.dart';
import 'auto_fit.dart';
import 'page_style.dart';

/// Renders one markdown page, auto-fitted to the screen.
class SongPageView extends StatelessWidget {
  const SongPageView({
    super.key,
    required this.page,
    required this.font,
    required this.palette,
    required this.scale,
    required this.contentRoot,
    required this.showTitle,
  });

  final SongPage page;
  final AppFont font;
  final PagePalette palette;

  /// Page magnification times the global multiplier.
  final double scale;

  /// Directory relative image paths are resolved against.
  final String contentRoot;

  /// Whether the page title is drawn above the body. Only has an effect when
  /// the title lives in the front matter — a title that is already a heading
  /// in the body is part of the content and stays there either way.
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Type size is derived from the panel, not from a fixed pixel value,
        // so the same songbook looks right on a 1080p TV and a 4K panel.
        final base = (constraints.maxHeight / 15).clamp(14.0, 260.0) * scale;
        final pad = constraints.maxWidth * 0.055;

        return Padding(
          padding: EdgeInsets.symmetric(horizontal: pad, vertical: pad * 0.4),
          child: AutoFit(
            baseSize: base,
            signature:
                '${page.path}|${page.body.hashCode}|${font.id}|$scale|$showTitle',
            builder: (context, size) => _body(size),
          ),
        );
      },
    );
  }

  /// The title as a leading heading in the body, if there is one there.
  static final RegExp _leadingHeading = RegExp(r'^\s*(#{1,6})\s+(.*\S)[ \t]*\r?\n?');

  /// A title can live in the front matter or as the first heading of the body.
  /// [showTitle] has to mean the same thing in both cases, so hiding it drops
  /// that leading heading, and showing it draws the front matter title as one
  /// when the body has no heading of its own.
  ({bool drawTitle, String body}) get _titleAndBody {
    final match = _leadingHeading.firstMatch(page.body);
    final headingIsTitle = match != null && match.group(2)!.trim() == page.title;

    if (!showTitle) {
      return (
        drawTitle: false,
        body: headingIsTitle ? page.body.substring(match.end) : page.body,
      );
    }
    return (
      drawTitle: page.declaredTitle != null && !headingIsTitle,
      body: page.body,
    );
  }

  Widget _body(double size) {
    final (:drawTitle, body: bodySource) = _titleAndBody;
    final markdown = MarkdownBody(
      data: bodySource,
      selectable: false,
      fitContent: false,
      // A songbook is written in lines and has to read as lines: without this,
      // markdown collapses a stanza into one wrapped paragraph.
      softLineBreak: true,
      styleSheet: markdownStyles(font: font, palette: palette, base: size),
      imageBuilder: (uri, title, alt) => _image(uri, alt),
    );

    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: page.align == PageAlign.center
                ? MainAxisAlignment.center
                : MainAxisAlignment.start,
            children: <Widget>[
              if (drawTitle) ...<Widget>[
                Text(
                  page.title,
                  style: fontStyle(
                    font: font,
                    size: size * 1.6,
                    color: palette.foreground,
                    weight: FontWeight.w700,
                    height: 1.15,
                  ),
                ),
                SizedBox(height: size * 0.55),
              ],
              markdown,
            ],
          ),
        ),
      ],
    );
  }

  Widget _image(Uri uri, String? alt) {
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      return Image.network(uri.toString(), fit: BoxFit.contain);
    }
    final path = uri.hasScheme && uri.scheme == 'file'
        ? uri.toFilePath()
        : p.isAbsolute(uri.path)
        ? uri.path
        : p.join(contentRoot, Uri.decodeComponent(uri.path));

    final file = File(path);
    if (!file.existsSync()) {
      return _missing(alt ?? p.basename(path));
    }
    return Image.file(file, fit: BoxFit.contain);
  }

  Widget _missing(String label) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(
      '[$label]',
      style: TextStyle(color: palette.muted, fontFamily: font.family),
    ),
  );
}
