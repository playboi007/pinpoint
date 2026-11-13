import '../trace_recorder.dart';
import '../trace_source.dart';

/// One `frame` event per frame the app draws, or per run of frames with
/// nothing else between them (level 1).
///
/// The tick comes from [FrameClock], which reads the persistent frame
/// callback; this source only writes. The event carries the recorder's own
/// time in that frame (`us`), so a frame time read in debug is not taken
/// for the app's alone (watch out for), and the frame's rebuild count while
/// the rebuild source runs.
class FrameSource extends TraceSource with FrameWork {
  FrameSource({required this.builds});

  /// Rebuilds in the frame just flushed, or null while rebuilds are not
  /// recorded.
  final int? Function() builds;

  TraceRecorder? _recorder;

  @override
  String get name => 'frame';

  @override
  int get level => 1;

  @override
  bool get isInput => false;

  @override
  void start(TraceRecorder recorder) => _recorder = recorder;

  @override
  void stop() => _recorder = null;

  @override
  void afterFrame() {
    final recorder = _recorder;
    if (recorder == null) return;
    // Folded into the last frame event when nothing happened since
    // (TraceRecorder.addFrame).
    recorder.addFrame(us: recorder.takeSelfMicros(), builds: builds());
  }
}
