part of 'annotation.dart';

/// A schema 1 note has no status. It was sent, so it reads as submitted.
NoteStatus _legacyStatus(Map<String, Object?> json) =>
    json['schema'] == 1 ? NoteStatus.submitted : NoteStatus.draft;

Map<String, Object?>? _checkOrNull(Object? json) => switch (json) {
  final Map<String, Object?> check when check['type'] is String => check,
  _ => null,
};

Map<String, Object?>? _tweakOrNull(Object? json) => switch (json) {
  final Map<String, Object?> tweak
      when tweak['property'] is String &&
          tweak['from'] is String &&
          tweak['to'] is String =>
    tweak,
  _ => null,
};

Map<String, Object?>? _roundOrNull(Object? json) => switch (json) {
  final Map<String, Object?> round when round['n'] is int => round,
  _ => null,
};
