import 'dart:convert';

/// Contrast polarity. Signage screens are usually one or the other for the
/// whole room, so this is a global setting rather than a per-page one.
enum PageTheme {
  /// Black text on white — daylight, projector, printed-page feel.
  light,

  /// White text on black — dark rooms, OLED panels, less glare.
  dark;

  PageTheme get flipped => this == light ? dark : light;
}

/// The bundled families, all of which cover č/š/ž/ć/đ.
class AppFont {
  const AppFont(this.id, this.label, this.family);

  final String id;
  final String label;
  final String family;

  static const List<AppFont> all = <AppFont>[
    AppFont('inter', 'Inter', 'Inter'),
    AppFont('noto-sans', 'Noto Sans', 'Noto Sans'),
    AppFont('noto-serif', 'Noto Serif', 'Noto Serif'),
    AppFont('atkinson', 'Atkinson Hyperlegible', 'Atkinson Hyperlegible'),
  ];

  static AppFont byId(String? id) =>
      all.firstWhere((f) => f.id == id, orElse: () => all.first);
}

class Settings {
  const Settings({
    this.theme = PageTheme.dark,
    this.fontId = 'inter',
    this.baseScale = 1.0,
    this.showChrome = true,
    this.showTitle = true,
    this.rotation = 0,
    this.httpPort = 80,
    this.httpEnabled = true,
    this.autoUpdate = false,
    this.password,
    this.passwordHash,
    this.passwordSalt,
  });

  /// Global polarity.
  final PageTheme theme;

  /// Id of the bundled font family, see [AppFont].
  final String fontId;

  /// Global magnification applied on top of each page's own scale.
  final double baseScale;

  /// Whether to draw the page number / title strip along the bottom.
  final bool showChrome;

  /// Songbook-wide default for showing page titles. A page can override it
  /// with `showTitle:` in its own front matter.
  final bool showTitle;

  /// How far the picture is turned on the panel, clockwise, in degrees. Only
  /// 0/90/180/270 are meaningful. The display cannot apply this itself: it is
  /// passed to flutter-pi at startup, so the appliance restarts the app when it
  /// changes. On a desktop run it does nothing.
  final int rotation;

  final int httpPort;
  final bool httpEnabled;

  /// Whether the box may fetch a newer release and stage it in the slot it is
  /// not running from. Off until somebody turns it on: the download is half a
  /// gigabyte over whatever connection the box was given, and a hall's guest
  /// wifi is not the place to spend that unasked. Nothing is ever installed by
  /// it either way -- that is a button, pressed by whoever can see the screen.
  ///
  /// The app only stores this. `pesmarica-update-check` on the box reads the
  /// same file, the same way the launcher reads `rotation`.
  final bool autoUpdate;

  /// A password typed straight into `settings.json` by a human. It is hashed
  /// and cleared on the next load, so plaintext never lingers in the file.
  final String? password;

  /// Salted hash of the password. Null means the web interface is open.
  final String? passwordHash;
  final String? passwordSalt;

  /// Whether the web interface asks for a password at all.
  bool get isProtected => passwordHash != null && passwordSalt != null;

  AppFont get font => AppFont.byId(fontId);

  Settings copyWith({
    PageTheme? theme,
    String? fontId,
    double? baseScale,
    bool? showChrome,
    bool? showTitle,
    int? rotation,
    int? httpPort,
    bool? httpEnabled,
    bool? autoUpdate,
    String? password,
    String? passwordHash,
    String? passwordSalt,
    bool clearPassword = false,
  }) => Settings(
    theme: theme ?? this.theme,
    fontId: fontId ?? this.fontId,
    baseScale: baseScale ?? this.baseScale,
    showChrome: showChrome ?? this.showChrome,
    showTitle: showTitle ?? this.showTitle,
    rotation: rotation ?? this.rotation,
    httpPort: httpPort ?? this.httpPort,
    httpEnabled: httpEnabled ?? this.httpEnabled,
    autoUpdate: autoUpdate ?? this.autoUpdate,
    password: clearPassword ? null : (password ?? this.password),
    passwordHash: clearPassword ? null : (passwordHash ?? this.passwordHash),
    passwordSalt: clearPassword ? null : (passwordSalt ?? this.passwordSalt),
  );

  /// The same settings with the plaintext password dropped.
  Settings withoutPlaintextPassword() => Settings(
    theme: theme,
    fontId: fontId,
    baseScale: baseScale,
    showChrome: showChrome,
    showTitle: showTitle,
    rotation: rotation,
    httpPort: httpPort,
    httpEnabled: httpEnabled,
    autoUpdate: autoUpdate,
    passwordHash: passwordHash,
    passwordSalt: passwordSalt,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'theme': theme.name,
    'font': fontId,
    'baseScale': baseScale,
    'showChrome': showChrome,
    'showTitle': showTitle,
    'rotation': rotation,
    'httpPort': httpPort,
    'httpEnabled': httpEnabled,
    'autoUpdate': autoUpdate,
    // `password` is intentionally never written back — see [password].
    if (passwordHash != null) 'passwordHash': passwordHash,
    if (passwordSalt != null) 'passwordSalt': passwordSalt,
  };

  static Settings fromJson(Map<String, Object?> json) => Settings(
    theme: json['theme'] == 'light' ? PageTheme.light : PageTheme.dark,
    fontId: AppFont.byId(json['font'] as String?).id,
    baseScale: _double(json['baseScale'], 1.0).clamp(0.4, 4.0),
    showChrome: json['showChrome'] as bool? ?? true,
    showTitle: json['showTitle'] as bool? ?? true,
    rotation: _rotation(json['rotation']),
    httpPort: _int(json['httpPort'], 80),
    httpEnabled: json['httpEnabled'] as bool? ?? true,
    autoUpdate: json['autoUpdate'] as bool? ?? false,
    password: _text(json['password']),
    passwordHash: _text(json['passwordHash']),
    passwordSalt: _text(json['passwordSalt']),
  );

  /// Anything that is not a right angle would leave the picture off the panel,
  /// so an unusable value falls back to no rotation at all.
  static int _rotation(Object? value) {
    final degrees = _int(value, 0);
    return const <int>[0, 90, 180, 270].contains(degrees) ? degrees : 0;
  }

  static String? _text(Object? value) {
    final text = value is String ? value.trim() : null;
    return (text == null || text.isEmpty) ? null : text;
  }

  static Settings decode(String source) {
    final decoded = jsonDecode(source);
    return decoded is Map<String, Object?>
        ? fromJson(decoded)
        : const Settings();
  }

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  static double _double(Object? v, double fallback) =>
      v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? fallback;

  static int _int(Object? v, int fallback) =>
      v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? fallback;
}
