import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

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

  final presenter = Presenter(songbook);
  final admin = AdminServer(songbook, presenter);
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
