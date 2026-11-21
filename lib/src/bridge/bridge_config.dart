// Plain Dart with `dart:io`: `<dir>/config.json`, the bridge's live status.

import 'dart:convert';
import 'dart:io';

import '../model/annotation.dart' show annotationSchema;
import 'bridge_protocol.dart';
import 'package_version.dart';

/// The status file in the notes folder.
const String bridgeConfigFileName = 'config.json';

/// The status of a bridge that listens on [port] for the project in [root].
Map<String, Object?> runningStatus({
  required int port,
  required String root,
  required DateTime now,
}) => {
  'name': 'pinpoint',
  'status': 'running',
  'version': pinpointVersion,
  'noteSchema': annotationSchema,
  'port': port,
  'root': root,
  'pid': pid,
  'startedAt': now.toUtc().toIso8601String(),
  'endpoints': {
    'mcp': 'http://127.0.0.1:$port$mcpPath',
    'health': 'http://127.0.0.1:$port$healthPath',
  },
};

/// Writes [status] to `<folder>/config.json` through a temporary file, so a
/// reader never sees half of it. Returns false when it cannot write.
Future<bool> writeBridgeStatus(
  Directory folder,
  Map<String, Object?> status,
) async {
  try {
    final temp = File('${folder.path}/.$bridgeConfigFileName.tmp');
    await temp.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(status)}\n',
    );
    await temp.rename('${folder.path}/$bridgeConfigFileName');
    return true;
  } on FileSystemException {
    return false;
  }
}

/// Rewrites `<folder>/config.json` as stopped, unless a bridge that started
/// later in this folder has replaced the file of [running].
Future<void> markBridgeStopped(
  Directory folder,
  Map<String, Object?> running,
  DateTime now,
) async {
  try {
    final current = jsonDecode(
      await File('${folder.path}/$bridgeConfigFileName').readAsString(),
    );
    if (!_sameRun(current, running)) return;
    await writeBridgeStatus(folder, {
      ...running,
      'status': 'stopped',
      'stoppedAt': now.toUtc().toIso8601String(),
    });
  } on FileSystemException {
    return;
  } on FormatException {
    return;
  }
}

bool _sameRun(Object? current, Map<String, Object?> running) =>
    current is Map<String, Object?> &&
    ['pid', 'port', 'startedAt'].every((key) => current[key] == running[key]);
