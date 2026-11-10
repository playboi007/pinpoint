/// Debug-only widget comment overlay.
///
/// Wrap the app in [PinPointWrapper] from `MaterialApp.builder`.
library;

export 'src/core/keymap.dart' show PinPointShortcut;
export 'src/core/pinpoint_config.dart';
export 'src/core/pinpoint_controller.dart';
export 'src/core/pinpoint_wrapper.dart';
export 'src/info/widget_info.dart'
    show InfoExtractor, InfoProperty, InfoSection, WidgetInfo;
export 'src/model/annotation.dart'
    show
        AncestorInfo,
        Annotation,
        AnnotationIntent,
        AppInfo,
        InheritedInfo,
        PageInfo,
        PayloadRect,
        PayloadSize,
        SiblingsInfo,
        SourceRef,
        TargetInfo;
