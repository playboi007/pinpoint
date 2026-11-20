// Plain Dart with `dart:io`: no `dart:ui` and no `package:flutter`, so
// `dart run pinpoint:bridge` can run it. Never exported from pinpoint.dart.

import 'dart:io';

import 'bridge_protocol.dart';

/// The bin for deleted notes: `<dir>/tmp/<id>__<stamp>/`.
///
/// A note the user deletes is moved here, with every file it owns, and not
/// destroyed. [flush] empties what is [tmpKeep] old. To undo a delete by
/// hand, move the files from `tmp/<entry>/` back into `open/`, `drafts/` or
/// `resolved/`.
class TmpBin {
  TmpBin(this.root);

  /// The notes folder, `.pinpoint/`.
  final Directory root;

  /// The folder name inside [root].
  static const String folderName = 'tmp';

  Directory get dir => Directory('${root.path}/$folderName');

  /// The stamp of [time] in an entry name: UTC, `yyyyMMddTHHmmssZ`.
  static String stamp(DateTime time) {
    final t = time.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}'
        'T${two(t.hour)}${two(t.minute)}${two(t.second)}Z';
  }

  static final RegExp _stampPattern = RegExp(
    r'__((\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z)(?:_\d+)?$',
  );

  /// The time in the name of an entry, or null when the name has none.
  static DateTime? stampOf(String name) {
    final m = _stampPattern.firstMatch(name);
    if (m == null) return null;
    final n = [for (var i = 2; i <= 7; i++) int.parse(m[i]!)];
    final time = DateTime.utc(n[0], n[1], n[2], n[3], n[4], n[5]);
    // DateTime.utc wraps a month 13 and the like: refuse those names.
    return stamp(time) == m[1] ? time : null;
  }

  /// A new, empty entry folder for note [id] at [now]. A second delete of
  /// the same id in the same second gets a `_2`, `_3`... suffix.
  Future<Directory> newEntry(String id, DateTime now) async {
    final base = '${id}__${stamp(now)}';
    var entry = Directory('${dir.path}/$base');
    for (var n = 2; entry.existsSync(); n++) {
      entry = Directory('${dir.path}/${base}_$n');
    }
    await entry.create(recursive: true);
    return entry;
  }

  /// Moves [from] into [to] (a folder), keeping the name. Renames; copies
  /// and deletes only when the rename fails.
  static Future<void> moveInto(FileSystemEntity from, Directory to) async {
    final name = from.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    final target = '${to.path}/$name';
    try {
      await from.rename(target);
    } on FileSystemException {
      if (from is Directory) {
        await _copyDir(from, Directory(target));
        await from.delete(recursive: true);
      } else if (from is File) {
        await from.copy(target);
        await from.delete();
      }
    }
  }

  static Future<void> _copyDir(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final entry in from.list()) {
      final name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (entry is Directory) {
        await _copyDir(entry, Directory('${to.path}/$name'));
      } else if (entry is File) {
        await entry.copy('${to.path}/$name');
      }
    }
  }

  /// Removes every entry whose stamp is at least [keep] before [now]; an
  /// entry with no readable stamp counts by its modification time. Does
  /// nothing when the folder is empty or missing. Returns how many it
  /// removed.
  Future<int> flush({DateTime? now, Duration keep = tmpKeep}) async {
    if (!dir.existsSync()) return 0;
    final cutoff = (now ?? DateTime.now()).subtract(keep);
    var removed = 0;
    try {
      await for (final entry in dir.list()) {
        final name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
        final at = stampOf(name) ?? (await entry.stat()).modified;
        if (at.isAfter(cutoff)) continue;
        try {
          await entry.delete(recursive: true);
          removed++;
        } on FileSystemException {
          // Gone already, or locked: the next flush tries again.
        }
      }
    } on FileSystemException {
      // The folder went away while it was read.
    }
    return removed;
  }
}
