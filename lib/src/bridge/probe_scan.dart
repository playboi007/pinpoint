// Plain Dart: the bridge's `list_probes`.

import 'dart:io';

import '../model/annotation.dart' show clipText;

/// One `PinPoint.probe(` line left in the project.
class ProbeLine {
  const ProbeLine(this.file, this.line, this.text);

  /// Relative to the project root, with `/`.
  final String file;

  /// 1-based.
  final int line;

  /// The line, trimmed and cut to 160 characters.
  final String text;

  @override
  String toString() => '$file:$line  $text';
}

/// The text that marks a probe line.
const String probeCall = 'PinPoint.probe(';

/// Every line under `<project>/lib` that calls `PinPoint.probe(`, in file
/// order, at most [max]. A plain text search: a probe in a comment counts
/// too, so nothing is missed.
Future<List<ProbeLine>> findProbes(Directory project, {int max = 200}) async {
  final lib = Directory('${project.path}/lib');
  if (!lib.existsSync()) return const <ProbeLine>[];
  final files = [
    await for (final entity in lib.list(recursive: true))
      if (entity is File && entity.path.endsWith('.dart')) entity,
  ]..sort((a, b) => a.path.compareTo(b.path));
  final found = <ProbeLine>[];
  final prefix = project.absolute.path.length + 1;
  for (final file in files) {
    final List<String> lines;
    try {
      lines = await file.readAsLines();
    } on FileSystemException {
      continue;
    }
    for (final (i, line) in lines.indexed) {
      if (!line.contains(probeCall)) continue;
      found.add(
        ProbeLine(
          file.absolute.path.substring(prefix).replaceAll(r'\', '/'),
          i + 1,
          clipText(line.trim(), 160),
        ),
      );
      if (found.length >= max) return found;
    }
  }
  return found;
}
