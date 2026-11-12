import 'package:flutter/foundation.dart';

import '../../detect/findings_controller.dart';
import '../../model/trace_event.dart';
import '../../search/source_resolver.dart';
import '../trace_recorder.dart';
import '../trace_source.dart';

/// `finding` events (level 1): each finding that appears in the
/// [FindingsController], once while it stays listed.
class FindingSource extends TraceSource with FrameWork {
  FindingSource({required this.findings, required this.resolver});

  /// The controller's findings now; the controller can change.
  final FindingsController Function() findings;
  final SourceResolver resolver;

  TraceRecorder? _recorder;
  FindingsController? _attached;
  Set<String> _seen = <String>{};

  @override
  String get name => 'finding';

  @override
  int get level => 1;

  @override
  bool get isInput => false;

  @override
  void start(TraceRecorder recorder) {
    _recorder = recorder;
    _attach();
  }

  @override
  void stop() {
    _attached?.removeListener(_onChange);
    _attached = null;
    _recorder = null;
  }

  /// Follows a new controller; cheap when it did not change.
  @override
  void afterFrame() => _attach();

  void _attach() {
    final current = findings();
    if (identical(current, _attached)) return;
    _attached?.removeListener(_onChange);
    _attached = current..addListener(_onChange);
    // What is listed now was there before: not new.
    _seen = {for (final f in current.findings) f.key};
  }

  void _onChange() {
    final recorder = _recorder;
    final controller = _attached;
    if (recorder == null || controller == null) return;
    try {
      final now = <String>{};
      for (final finding in controller.findings) {
        now.add(finding.key);
        if (_seen.contains(finding.key)) continue;
        final location = finding.source;
        recorder.add(
          TraceKind.finding,
          widget: finding.data['widget'] is String
              ? finding.data['widget']! as String
              : null,
          source: location == null
              ? null
              : '${resolver.paths.relativePath(location.uri)}:'
                    '${location.line}:${location.column}',
          data: {
            'kind': finding.kind,
            'severity': finding.severity.name,
            'summary': traceValue(finding.summary),
          },
        );
      }
      // A finding that goes away and comes back is new again.
      _seen = now;
    } catch (error) {
      debugPrint('pinpoint: finding source failed: $error');
    }
  }
}
