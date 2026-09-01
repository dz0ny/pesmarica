import 'package:yaml/yaml.dart';

/// A markdown document split into its YAML front matter and its body.
///
/// Pesmarica keeps per-page presentation state (magnification, alignment) in
/// the front matter so that a page is entirely self describing: copy the `.md`
/// file to another screen and it looks the same.
class FrontMatter {
  FrontMatter(this.values, this.body);

  final Map<String, Object?> values;
  final String body;

  static final RegExp _fence = RegExp(r'^---[ \t]*\r?\n');

  static FrontMatter parse(String source) {
    final text = source.replaceAll('\r\n', '\n');
    if (!_fence.hasMatch(text)) return FrontMatter(<String, Object?>{}, text);

    final end = text.indexOf(RegExp(r'\n---[ \t]*(\n|$)'), 3);
    if (end < 0) return FrontMatter(<String, Object?>{}, text);

    final yamlText = text.substring(text.indexOf('\n') + 1, end + 1);
    final rest = text.substring(text.indexOf('\n', end + 1) + 1);

    Map<String, Object?> values;
    try {
      final doc = loadYaml(yamlText);
      values = doc is YamlMap
          ? doc.map((k, v) => MapEntry(k.toString(), _plain(v)))
          : <String, Object?>{};
    } on YamlException {
      // A malformed header should never take the whole screen down; treat the
      // document as if it had no front matter at all.
      values = <String, Object?>{};
    }
    return FrontMatter(values, rest);
  }

  static Object? _plain(Object? node) {
    if (node is YamlMap) {
      return node.map((k, v) => MapEntry(k.toString(), _plain(v)));
    }
    if (node is YamlList) return node.map(_plain).toList();
    return node;
  }

  /// Re-assembles the document. Keys with a `null` value are dropped, so
  /// removing a setting is the same as setting it to `null`.
  static String compose(Map<String, Object?> values, String body) {
    final kept = Map<String, Object?>.fromEntries(
      values.entries.where((e) => e.value != null),
    );
    if (kept.isEmpty) return body;

    final buffer = StringBuffer('---\n');
    for (final entry in kept.entries) {
      buffer.writeln('${entry.key}: ${_scalar(entry.value!)}');
    }
    buffer.write('---\n');
    if (!body.startsWith('\n')) buffer.write('\n');
    buffer.write(body);
    return buffer.toString();
  }

  static String _scalar(Object value) {
    if (value is num || value is bool) return '$value';
    final text = '$value';
    final needsQuotes =
        text.isEmpty ||
        RegExp(r'''^[\s>|&*!%@`'"\[{#-]''').hasMatch(text) ||
        text.contains(': ') ||
        text.trimRight() != text;
    return needsQuotes ? '"${text.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"' : text;
  }
}
