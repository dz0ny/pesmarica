import 'package:flutter/material.dart';

import '../model/settings.dart';
import 'page_style.dart';

/// The bottom strip: page number, title, total. Deliberately quiet — it is
/// wayfinding for the room, not part of the content.
class ChromeBar extends StatelessWidget {
  const ChromeBar({
    super.key,
    required this.font,
    required this.palette,
    required this.number,
    required this.title,
    required this.position,
    required this.total,
  });

  final AppFont font;
  final PagePalette palette;
  final int number;
  final String title;
  final int position;
  final int total;

  @override
  Widget build(BuildContext context) {
    final size = (MediaQuery.sizeOf(context).height / 45).clamp(11.0, 34.0);
    final style = fontStyle(
      font: font,
      size: size,
      color: palette.muted,
      height: 1.0,
    );

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: MediaQuery.sizeOf(context).width * 0.055,
        vertical: size * 0.7,
      ),
      child: Row(
        children: <Widget>[
          Text(
            '$number',
            style: style.copyWith(
              color: palette.foreground,
              fontWeight: FontWeight.w700,
              fontVariations: const <FontVariation>[FontVariation('wght', 700)],
            ),
          ),
          SizedBox(width: size * 0.8),
          Expanded(
            child: Text(title, style: style, overflow: TextOverflow.ellipsis),
          ),
          SizedBox(width: size * 0.8),
          Text('$position / $total', style: style),
        ],
      ),
    );
  }
}

/// The half-typed page number, PowerPoint style.
class NumberEntryOverlay extends StatelessWidget {
  const NumberEntryOverlay({
    super.key,
    required this.digits,
    required this.font,
    required this.palette,
  });

  final String digits;
  final AppFont font;
  final PagePalette palette;

  @override
  Widget build(BuildContext context) {
    final size = (MediaQuery.sizeOf(context).height / 6).clamp(40.0, 260.0);
    return Center(
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: size * 0.45,
          vertical: size * 0.18,
        ),
        decoration: BoxDecoration(
          color: palette.background.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(size * 0.18),
          border: Border.all(color: palette.muted, width: size * 0.012),
        ),
        child: Text(
          digits,
          style: fontStyle(
            font: font,
            size: size,
            color: palette.foreground,
            weight: FontWeight.w700,
            height: 1.0,
          ),
        ),
      ),
    );
  }
}

/// Transient status line for zoom / theme / font changes.
class FlashOverlay extends StatelessWidget {
  const FlashOverlay({
    super.key,
    required this.message,
    required this.font,
    required this.palette,
  });

  final String message;
  final AppFont font;
  final PagePalette palette;

  @override
  Widget build(BuildContext context) {
    final size = (MediaQuery.sizeOf(context).height / 32).clamp(14.0, 48.0);
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.only(bottom: size * 2.4),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: size * 0.9,
            vertical: size * 0.4,
          ),
          decoration: BoxDecoration(
            color: palette.foreground.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(size * 0.5),
          ),
          child: Text(
            message,
            style: fontStyle(
              font: font,
              size: size,
              color: palette.foreground,
              height: 1.0,
            ),
          ),
        ),
      ),
    );
  }
}

/// Keyboard reference, shown on `?`. Handy when the only input device in the
/// room is a presenter remote nobody has used before.
class HelpOverlay extends StatelessWidget {
  const HelpOverlay({
    super.key,
    required this.font,
    required this.palette,
    required this.adminUrl,
  });

  final AppFont font;
  final PagePalette palette;
  final String? adminUrl;

  static const List<(String, String)> bindings = <(String, String)>[
    ('↓ → · Space · PgDn', 'Naslednja stran'),
    ('↑ ← · PgUp', 'Prejšnja stran'),
    ('0–9 nato Enter', 'Skok na stran'),
    ('Backspace', 'Zbriši zadnjo števko'),
    ('Esc', 'Prekliči vnos'),
    ('Home · End', 'Prva · zadnja stran'),
    ('+ · −', 'Povečava (shrani se v stran)'),
    ('R', 'Ponastavi povečavo'),
    ('B', 'Črno na belem / belo na črnem'),
    ('F', 'Naslednja pisava'),
    ('T', 'Pokaži/skrij naslove'),
    ('C', 'Pokaži/skrij spodnjo vrstico'),
    ('?', 'Ta pomoč'),
  ];

  @override
  Widget build(BuildContext context) {
    final size = (MediaQuery.sizeOf(context).height / 34).clamp(12.0, 40.0);
    final label = fontStyle(
      font: font,
      size: size,
      color: palette.foreground,
      weight: FontWeight.w600,
      height: 1.6,
    );
    final desc = fontStyle(
      font: font,
      size: size,
      color: palette.muted,
      height: 1.6,
    );

    return Center(
      child: Container(
        padding: EdgeInsets.all(size * 1.4),
        decoration: BoxDecoration(
          color: palette.background.withValues(alpha: 0.96),
          border: Border.all(color: palette.muted, width: 1),
          borderRadius: BorderRadius.circular(size * 0.4),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Tipke', style: label.copyWith(fontSize: size * 1.3)),
            SizedBox(height: size * 0.6),
            Table(
              columnWidths: const <int, TableColumnWidth>{
                0: IntrinsicColumnWidth(),
                1: IntrinsicColumnWidth(),
              },
              children: <TableRow>[
                for (final (keys, what) in bindings)
                  TableRow(
                    children: <Widget>[
                      Padding(
                        padding: EdgeInsets.only(right: size * 1.2),
                        child: Text(keys, style: label),
                      ),
                      Text(what, style: desc),
                    ],
                  ),
              ],
            ),
            if (adminUrl != null) ...<Widget>[
              SizedBox(height: size * 0.8),
              Text('Urejanje: $adminUrl', style: desc),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shown when the content folder has no pages yet.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.font,
    required this.palette,
    required this.contentRoot,
    required this.adminUrl,
  });

  final AppFont font;
  final PagePalette palette;
  final String contentRoot;
  final String? adminUrl;

  @override
  Widget build(BuildContext context) {
    final size = (MediaQuery.sizeOf(context).height / 26).clamp(14.0, 56.0);
    return Center(
      child: Padding(
        padding: EdgeInsets.all(size),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'Pesmarica je prazna',
              style: fontStyle(
                font: font,
                size: size,
                color: palette.foreground,
                weight: FontWeight.w700,
              ),
            ),
            SizedBox(height: size * 0.5),
            Text(
              'Dodaj datoteke 001-pesem.md v\n$contentRoot',
              textAlign: TextAlign.center,
              style: fontStyle(
                font: font,
                size: size * 0.55,
                color: palette.muted,
              ),
            ),
            if (adminUrl != null) ...<Widget>[
              SizedBox(height: size * 0.4),
              Text(
                adminUrl!,
                style: fontStyle(
                  font: font,
                  size: size * 0.55,
                  color: palette.muted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
