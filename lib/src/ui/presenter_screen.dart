import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/presenter.dart';
import '../input/key_bindings.dart';
import 'overlays.dart';
import 'page_style.dart';
import 'page_view.dart';

/// The full-screen display. One page at a time, no scroll bars, no cursor.
class PresenterScreen extends StatefulWidget {
  const PresenterScreen({
    super.key,
    required this.presenter,
    required this.adminUrl,
  });

  final Presenter presenter;

  /// Shown in the help card and the empty state, null when the web interface
  /// is disabled.
  final String? adminUrl;

  @override
  State<PresenterScreen> createState() => _PresenterScreenState();
}

class _PresenterScreenState extends State<PresenterScreen> {
  final FocusNode _focus = FocusNode(debugLabel: 'pesmarica');
  late final KeyBindings _keys = KeyBindings(widget.presenter);

  @override
  void initState() {
    super.initState();
    widget.presenter.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    widget.presenter.removeListener(_onChanged);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final presenter = widget.presenter;
    final settings = presenter.settings;
    final palette = PagePalette.of(settings.theme);
    final font = settings.font;
    final page = presenter.current;
    // A page opts in or out on its own; otherwise the songbook default wins.
    final showTitle = page?.showTitle ?? settings.showTitle;

    // Nothing here is a Scaffold, and text outside a Material inherits the
    // framework's error style: a yellow double underline under every line.
    // A transparent Material draws nothing and supplies a plain default.
    return Material(
      type: MaterialType.transparency,
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: (_, event) => _keys.handle(event),
        child: GestureDetector(
          // Touch panels and USB "air mouse" remotes are common on signage
          // hardware; a tap on the right half advances, like the arrow keys.
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            final width = MediaQuery.sizeOf(context).width;
            details.globalPosition.dx > width / 2
                ? presenter.next()
                : presenter.previous();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            color: palette.background,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                if (page == null)
                  EmptyState(
                    font: font,
                    palette: palette,
                    contentRoot: presenter.songbook.root.path,
                    adminUrl: widget.adminUrl,
                  )
                else
                  Column(
                    children: <Widget>[
                      Expanded(
                        child: SongPageView(
                          key: ValueKey<String>(page.path),
                          page: page,
                          font: font,
                          palette: palette,
                          scale: presenter.effectiveScale,
                          contentRoot: presenter.songbook.root.path,
                          showTitle: showTitle,
                        ),
                      ),
                      if (settings.showChrome)
                        ChromeBar(
                          font: font,
                          palette: palette,
                          number: page.number,
                          title: showTitle ? page.title : '',
                          position: presenter.index + 1,
                          total: presenter.pages.length,
                        ),
                    ],
                  ),
                if (presenter.numberBuffer.isNotEmpty)
                  NumberEntryOverlay(
                    digits: presenter.numberBuffer,
                    font: font,
                    palette: palette,
                  ),
                if (presenter.flash != null)
                  FlashOverlay(
                    message: presenter.flash!,
                    font: font,
                    palette: palette,
                  ),
                if (presenter.helpVisible)
                  HelpOverlay(
                    font: font,
                    palette: palette,
                    adminUrl: widget.adminUrl,
                  ),
                if (presenter.songbook.error != null)
                  _ErrorBanner(
                    message: presenter.songbook.error!,
                    palette: palette,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.palette});

  final String message;
  final PagePalette palette;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: Container(
      width: double.infinity,
      color: const Color(0xFF8B1E1E),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        message,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontSize: 16),
      ),
    ),
  );
}

/// Hides the mouse pointer and any system chrome on the signage host.
Future<void> enterKioskMode() async {
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
}
