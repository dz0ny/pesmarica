import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'src/data/boot_config.dart';
import 'src/data/presenter.dart';
import 'src/data/songbook.dart';
import 'src/ui/presenter_screen.dart';
import 'src/web/admin_server.dart';

/// Where the songbook lives.
///
/// One environment variable, one fallback: the signage host sets
/// `PESMARICA_CONTENT` in its unit file, and a developer just gets the
/// `content/` folder next to the project.
Directory resolveContentRoot() {
  const compiled = String.fromEnvironment('PESMARICA_CONTENT');
  final configured = compiled.isNotEmpty
      ? compiled
      : Platform.environment['PESMARICA_CONTENT'];
  final path = (configured == null || configured.trim().isEmpty)
      ? p.join(Directory.current.path, 'content')
      : configured.trim();
  return Directory(p.normalize(p.absolute(path)));
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await enterKioskMode();

  final songbook = Songbook(resolveContentRoot());
  await songbook.start();

  // A rotation on the boot partition is what the launcher started flutter-pi
  // with, so it is the truth about which way up the screen is. Take it over the
  // one in settings.json, or the web interface would offer to "change" a
  // rotation the box is not using. Only when they disagree: a boot that agrees
  // writes nothing.
  final boot = BootConfig.fromEnvironment();
  final rotation = boot.readRotation();
  if (rotation != null && rotation != songbook.settings.rotation) {
    await songbook.saveSettings(songbook.settings.copyWith(rotation: rotation));
  }

  final presenter = Presenter(songbook);
  final admin = AdminServer(songbook, presenter, boot: boot);
  await admin.start();

  runApp(PesmaricaApp(presenter: presenter, admin: admin));
}

class PesmaricaApp extends StatefulWidget {
  const PesmaricaApp({super.key, required this.presenter, required this.admin});

  final Presenter presenter;
  final AdminServer admin;

  @override
  State<PesmaricaApp> createState() => _PesmaricaAppState();
}

class _PesmaricaAppState extends State<PesmaricaApp> {
  String? _adminUrl;

  @override
  void initState() {
    super.initState();
    // Resolving the LAN address hits the network stack, so do it after the
    // first frame rather than holding up the display.
    widget.admin.lanUrl().then((url) {
      if (mounted) setState(() => _adminUrl = url);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pesmarica',
      debugShowCheckedModeBanner: false,
      // The screen has no chrome of its own; all colours come from the page
      // palette so that the two polarities stay exactly two colours.
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: MouseRegion(
        cursor: SystemMouseCursors.none,
        child: PresenterScreen(
          presenter: widget.presenter,
          adminUrl: _adminUrl,
        ),
      ),
    );
  }
}
