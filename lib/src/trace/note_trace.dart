import 'package:flutter/widgets.dart';

import '../search/source_resolver.dart';
import 'trace_format.dart';
import 'trace_session.dart';

/// The `trace` for a note on [picked]: the
/// events of its subtree in the 10 seconds before Pinpoint became active
/// (the user saw the problem, then started picking). Null when the
/// recorder is off or nothing was kept.
Map<String, Object?>? traceForNote(
  Element picked, {
  required SourceResolver resolver,
}) {
  final session = TraceSession.current;
  if (session == null) return null;
  final recorder = session.recorder;
  return noteTrace(
    recorder,
    end: session.activeSince ?? recorder.now,
    subtree: subtreeSources(picked, resolver),
  );
}

/// The creation locations (`file:line:column`) of the local widgets in the
/// subtree of [root], [root] included. Bounded like every walk (engineering
/// rule 4); empty when [root] is gone.
Set<String> subtreeSources(Element root, SourceResolver resolver) {
  final subtree = <String>{};
  var visited = 0;
  void visit(Element element) {
    if (++visited > 3000) return;
    final entry = resolver.entryOf(element);
    final location = entry.location;
    if (entry.isLocal && location != null) {
      subtree.add(
        '${resolver.paths.relativePath(location.uri)}:'
        '${location.line}:${location.column}',
      );
    }
    element.visitChildElements(visit);
  }

  try {
    visit(root);
  } catch (_) {
    // Unmounted since the pick: the inputs, routes and errors still help.
  }
  return subtree;
}
