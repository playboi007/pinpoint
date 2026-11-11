/// Debug-only widget comment overlay.
///
/// Wrap the app in [PinPointWrapper] from `MaterialApp.builder`.
library;

export 'src/agent/state_dump.dart' show StateAdapter;
export 'src/core/keymap.dart' show PinPointShortcut;
export 'src/core/pinpoint_config.dart';
export 'src/core/pinpoint_controller.dart'
    show CommentDraft, PinPointController, PinPointMode;
export 'src/core/pinpoint_wrapper.dart';
export 'src/env/environment_controller.dart'
    show Environment, EnvironmentController;
export 'src/info/widget_info.dart'
    show InfoExtractor, InfoProperty, InfoSection, WidgetInfo;
export 'src/model/annotation.dart'
    show
        AncestorInfo,
        Annotation,
        AnnotationIntent,
        AppInfo,
        InheritedInfo,
        NoteAnchor,
        NoteMessage,
        NoteStatus,
        PageInfo,
        PayloadRect,
        PayloadSize,
        ScreenshotInfo,
        SiblingsInfo,
        SourceRef,
        TargetInfo;
export 'src/sink/clipboard_sink.dart' show ClipboardSink;
export 'src/sink/http_sink.dart' show HttpSink, HttpSinkException;
export 'src/sink/pinpoint_sink.dart' show PinPointSink;
export 'src/theme/pinpoint_tokens.dart' show PinPointPalette;
