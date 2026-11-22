import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show TabController;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../core/hook_registry.dart';
import '../model/trace_event.dart';
import '../search/source_resolver.dart';
import '../trace/redact.dart';
import '../trace/story_names.dart';
import '../trace/trace_recorder.dart';
import '../trace/value_diff.dart';
import 'dependencies.dart';
import 'element_label.dart';
import 'stack_frames.dart';

/// What the lens masks in a value: the trace's names, and passwords too (a
/// model that holds one is common state).
const TraceRedact stateRedact = TraceRedact([
  ...TraceRedact.defaults,
  '*password*',
  '*passwd*',
]);

/// Pinpoint's own listener on the objects that notify: the listenables a state
/// owner reads and those that
/// `ValueListenableBuilder`, `ListenableBuilder` and `AnimatedBuilder` in a
/// subtree listen to.
///
/// Each notify becomes a `state.notify` event ([TraceKind.stateNotify]):
/// the owner's type, its identity tag, the first project frame (the method
/// that notified), the cause of the zone it ran in, and for a
/// `ValueListenable` the value before and after. The lens keeps the last
/// value it saw, so "before" needs no reflection.
///
/// Engineering rule 3: this adds listeners only while the lens is on.
/// Every listener is taken off on [stop] (also through [HookRegistry]'s
/// dispose when a registry is given) and when the element that wanted it
/// is gone: [sweep] runs after each frame, and a notify that finds its
/// elements gone takes the listener off too.
class StateListen {
  StateListen({
    required this.recorder,
    required this.resolver,
    this.hooks,
    IdentityTags? tags,
    this.redact = stateRedact,
    this.maxAttachments = defaultMaxAttachments,
    this.projectFiles,
  }) : tags = tags ?? IdentityTags.shared {
    hooks?.onDispose(stop);
  }

  /// Most listenables one lens listens to.
  static const int defaultMaxAttachments = 64;

  /// Most elements one [attachSubtree] walk visits.
  static const int maxWalk = 4000;

  final TraceRecorder recorder;
  final SourceResolver resolver;

  /// When given, [stop] also runs on its dispose.
  final HookRegistry? hooks;

  final IdentityTags tags;
  final TraceRedact redact;
  final int maxAttachments;

  /// The app's own files, to tell its frames from the framework's. Null or
  /// empty: the deny list of [firstProjectFrame] decides.
  final ProjectFiles Function()? projectFiles;

  final Map<Listenable, _Attachment> _attached =
      Map<Listenable, _Attachment>.identity();
  bool _stopped = false;

  /// Listenables attached now.
  int get attached => _attached.length;

  /// Whether [listenable] has Pinpoint's listener now.
  bool isAttached(Listenable listenable) => _attached.containsKey(listenable);

  /// Attaches to the listenable of each of [dependencies] that is one (a
  /// provider scope's value, an `InheritedNotifier`'s notifier). Returns
  /// how many are new.
  int attachDependencies(Iterable<DependencyRef> dependencies) {
    var added = 0;
    for (final dependency in dependencies) {
      final listenable = dependency.listenable;
      if (listenable == null) continue;
      final location = dependency.location;
      if (_attach(
        listenable,
        owner: dependency.type,
        via: dependency.kind,
        element: dependency.element,
        src: location == null
            ? null
            : '${resolver.paths.relativePath(location.uri)}:${location.line}',
      )) {
        added++;
      }
    }
    return added;
  }

  /// Attaches to the listenable of each `ValueListenableBuilder`,
  /// `ListenableBuilder` and `AnimatedBuilder` that the project made, at or
  /// under [root], at most [maxWalk] elements. An `Animation` is passed
  /// over: it notifies on every frame and is not state. Returns how many
  /// are new.
  int attachSubtree(Element root) {
    var added = 0;
    var visited = 0;
    final pending = <Element>[root];
    while (pending.isNotEmpty && visited < maxWalk) {
      final element = pending.removeLast();
      visited++;
      final found = _builderListenable(element);
      // A builder made by the framework (a Scaffold, a Navigator) is not
      // app state. Without creation locations nothing can be told apart,
      // and every builder counts (the attachment cap still holds).
      if (found != null &&
          (!resolver.available || resolver.entryOf(element).isLocal)) {
        final (listenable, via) = found;
        final location = resolver.available
            ? resolver.entryOf(element).location
            : null;
        if (_attach(
          listenable,
          owner: listenable.runtimeType.toString(),
          via: via,
          element: element,
          src: location == null
              ? null
              : '${resolver.paths.relativePath(location.uri)}:${location.line}',
        )) {
          added++;
        }
      }
      try {
        element.visitChildren(pending.add);
      } catch (_) {
        // An element that is not active cannot be walked.
      }
    }
    return added;
  }

  /// Attaches to [listenable] directly (an owner the caller found by
  /// itself). [element] is the element that wants it: when it unmounts, the
  /// listener goes. Returns whether it is new.
  bool attach(
    Listenable listenable, {
    required String owner,
    String via = 'listenable',
    Element? element,
    String? src,
  }) => _attach(listenable, owner: owner, via: via, element: element, src: src);

  static (Listenable, String)? _builderListenable(Element element) {
    final Widget widget;
    try {
      widget = element.widget;
    } catch (_) {
      return null;
    }
    // A type test with `Object?` is true for every `ValueListenableBuilder<T>`.
    if (widget is ValueListenableBuilder<Object?>) {
      return (widget.valueListenable, 'ValueListenableBuilder');
    }
    if (widget is ListenableBuilder) {
      return widget.listenable is Animation
          ? null
          : (widget.listenable, 'ListenableBuilder');
    }
    return null;
  }

  bool _attach(
    Listenable listenable, {
    required String owner,
    required String via,
    Element? element,
    String? src,
  }) {
    if (_stopped) return false;
    final existing = _attached[listenable];
    if (existing != null) {
      if (element != null) existing.elements.add(element);
      return false;
    }
    if (_attached.length >= maxAttachments) return false;
    final shownOwner = clipOwner(owner);
    final verb = controllerVerb(_baseOf(shownOwner));
    final last = _readValue(listenable);
    final attachment = _Attachment(
      listenable: listenable,
      owner: shownOwner,
      via: via,
      tag: tags.of(listenable),
      last: last,
      hasValue: listenable is ValueListenable,
      src: src,
      verb: verb,
      // A controller shows a verb, never a value: a text field's text can
      // be a password.
      snap: verb == null && listenable is ValueListenable
          ? snapshotOf(last, owner: shownOwner, redact: redact)
          : null,
    );
    if (element != null) attachment.elements.add(element);
    attachment.callback = () => _notified(attachment);
    try {
      listenable.addListener(attachment.callback);
    } catch (_) {
      // A disposed notifier asserts on addListener: nothing to follow.
      return false;
    }
    _attached[listenable] = attachment;
    _active.add(this);
    _ensureFrameHook();
    return true;
  }

  static String _baseOf(String type) {
    final open = type.indexOf('<');
    return open < 0 ? type : type.substring(0, open);
  }

  static String clipOwner(String owner) =>
      owner.length > 80 ? '${owner.substring(0, 80)}...' : owner;

  static Object? _readValue(Listenable listenable) {
    if (listenable is! ValueListenable) return null;
    try {
      return listenable.value;
    } catch (_) {
      return null;
    }
  }

  // Runs inside the notifying call: it only reads and
  // records, and a failure here must never reach the app's notifier.
  void _notified(_Attachment attachment) {
    if (_stopped) return;
    try {
      if (attachment.gone) {
        _detach(attachment);
        return;
      }
      final stack = StackTrace.current;
      ProjectFiles? files;
      try {
        files = projectFiles?.call();
      } catch (_) {
        // Without files the deny list decides.
      }
      final frame = firstProjectFrame(stack, resolver.paths, files: files);
      final depth = notifyDepth(stack.toString());
      final data = <String, Object?>{
        'owner': attachment.owner,
        'tag': attachment.tag,
        'via': attachment.via,
        'listenable': attachment.listenable.runtimeType.toString(),
        // 2 or more: this notify ran inside the listener of another one.
        if (depth > 1) 'depth': depth,
        if (frame != null) ...{
          'file': frame.file,
          'line': frame.line,
          'method': frame.method,
        },
        // For the story: where the listening widget is created (the bridge
        // reads the name there), which argument to read, and which instance
        // of a group this is.
        'src': ?attachment.src,
        if (attachment.src != null && builderArgument(attachment.via) != null)
          'srcArg': builderArgument(attachment.via),
        'instance': ?attachment.instance(),
      };
      if (attachment.verb != null) {
        final detail = _detail(attachment.listenable);
        if (detail != null) data['detail'] = detail;
      } else if (attachment.hasValue) {
        final before = attachment.last;
        final after = _readValue(attachment.listenable);
        attachment.last = after;
        data['before'] = _shown(before, attachment.owner);
        data['after'] = _shown(after, attachment.owner);
        if (_sameText(data['before'], data['after'])) data['same'] = true;
        final was = attachment.snap;
        final now = snapshotOf(after, owner: attachment.owner, redact: redact);
        attachment.snap = now;
        if (was != null) {
          data['change'] = diffValues(
            was,
            now,
            sameObject: identical(before, after),
          );
        }
      }
      recorder.add(
        TraceKind.stateNotify,
        widget: attachment.owner,
        source: frame?.where,
        data: data,
      );
    } catch (_) {
      // The lens only observes.
    }
  }

  static bool _sameText(Object? a, Object? b) => '$a' == '$b';

  // More about a controller's notify: the tab or page it is on.
  static String? _detail(Listenable listenable) {
    try {
      if (listenable is TabController) return 'index ${listenable.index}';
      if (listenable is PageController && listenable.hasClients) {
        final page = listenable.page;
        if (page != null) return 'page ${page.round()}';
      }
    } catch (_) {
      // A controller that is disposed or has no clients.
    }
    return null;
  }

  /// How many `ChangeNotifier.notifyListeners` calls are on [stack]: 1 for
  /// a plain notify, 2 or more when a notify runs inside the listener of
  /// another one (shape 2 of the lens). Flutter's notifier frames come
  /// from `change_notifier.dart` or, on newer SDKs, `package:listen`.
  static int notifyDepth(String stack) {
    var n = 0;
    for (final line in stack.split('\n')) {
      if (line.contains('notifyListeners') &&
          (line.contains('change_notifier.dart') ||
              line.contains('package:listen/src/listen.dart') ||
              line.contains('packages/listen/src/listen.dart'))) {
        n++;
      }
    }
    return n;
  }

  /// The elements that asked for the listenable tagged [tag] (a builder, a
  /// reader), for the lens' fan-out join. Unmounted ones are left out.
  List<Element> elementsFor(String tag) {
    for (final attachment in _attached.values) {
      if (attachment.tag != tag) continue;
      return [
        for (final element in attachment.elements)
          if (element.mounted) element,
      ];
    }
    return const <Element>[];
  }

  /// [value] made safe for an event: collections have the values of
  /// masked keys replaced ([TraceRedact.json]), a string held by an owner
  /// whose name is masked (`tokenNotifier`) is masked whole, and
  /// everything is clipped ([traceValue]).
  Object? _shown(Object? value, String owner) {
    if (value is String && redact.masks(owner)) return TraceRedact.mask;
    // An object: its text has secret fields masked ([snapshotOf]).
    if (value != null &&
        value is! String &&
        value is! num &&
        value is! bool &&
        value is! Map &&
        value is! List) {
      return snapshotOf(value, owner: owner, redact: redact).text;
    }
    final safe = value is Map || value is List ? redact.json(value) : value;
    return traceValue(safe);
  }

  /// Takes the listener off every listenable whose elements are all
  /// unmounted. Runs after each frame while any listener is attached.
  void sweep() {
    if (_stopped) return;
    for (final attachment in _attached.values.toList()) {
      if (attachment.gone) _detach(attachment);
    }
    if (_attached.isEmpty) _active.remove(this);
  }

  void _detach(_Attachment attachment) {
    _attached.remove(attachment.listenable);
    try {
      attachment.listenable.removeListener(attachment.callback);
    } catch (_) {
      // Already gone.
    }
  }

  /// Takes every listener off. Safe to call more than once; the lens
  /// cannot attach again after it.
  void stop() {
    _stopped = true;
    for (final attachment in _attached.values.toList()) {
      _detach(attachment);
    }
    _attached.clear();
    _active.remove(this);
  }

  // Instances with listeners. One persistent frame callback serves all of
  // them: such a callback cannot be removed (see HookRegistry), so it is
  // added once and does nothing when the set is empty.
  static final Set<StateListen> _active = <StateListen>{};
  static bool _hooked = false;

  static void _ensureFrameHook() {
    if (_hooked) return;
    try {
      SchedulerBinding.instance.addPersistentFrameCallback((_) {
        if (_active.isEmpty) return;
        for (final listen in _active.toList()) {
          listen.sweep();
        }
      });
      _hooked = true;
    } catch (_) {
      // No binding (a plain Dart test): [sweep] can still be called.
    }
  }
}

class _Attachment {
  _Attachment({
    required this.listenable,
    required this.owner,
    required this.via,
    required this.tag,
    required this.last,
    required this.hasValue,
    this.src,
    this.verb,
    this.snap,
  });

  final Listenable listenable;
  final String owner;
  final String via;
  final String tag;
  final bool hasValue;

  /// Where the widget that listens or provides is created.
  final String? src;

  /// The verb of a framework controller, or null.
  final String? verb;

  /// A snapshot of the value at the last notify, for the next diff.
  ValueSnap? snap;

  String? _instance;
  bool _instanceRead = false;

  /// Which instance of a group this is: the nearest `Key`, list index, or
  /// short text of its widget. Read once, on the first notify.
  String? instance() {
    if (_instanceRead) return _instance;
    _instanceRead = true;
    for (final element in elements) {
      if (!element.mounted) continue;
      try {
        _instance = instanceLabel(element);
      } catch (_) {
        // Diagnostics run code written by widget authors.
        _instance = null;
      }
      break;
    }
    return _instance;
  }

  /// The value seen at the last notify (or at attach): "before" for the
  /// next one.
  Object? last;

  /// The elements that wanted this listenable. Gone when none is mounted
  /// (and at least one was given).
  final List<Element> elements = <Element>[];

  late final VoidCallback callback;

  bool get gone =>
      elements.isNotEmpty && elements.every((element) => !element.mounted);
}
