import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../core/hook_registry.dart';
import '../model/trace_event.dart';
import '../search/source_resolver.dart';
import '../trace/redact.dart';
import '../trace/trace_recorder.dart';
import 'dependencies.dart';
import 'stack_frames.dart';

/// Pinpoint's own listener on the objects that notify (PLAN-v3 Milestone 21,
/// step 2): the listenables a state owner reads (step 1) and those that
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
    this.redact = const TraceRedact(),
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
      if (_attach(
        listenable,
        owner: dependency.type,
        via: dependency.kind,
        element: dependency.element,
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
        if (_attach(
          listenable,
          owner: listenable.runtimeType.toString(),
          via: via,
          element: element,
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
  }) => _attach(listenable, owner: owner, via: via, element: element);

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
  }) {
    if (_stopped) return false;
    final existing = _attached[listenable];
    if (existing != null) {
      if (element != null) existing.elements.add(element);
      return false;
    }
    if (_attached.length >= maxAttachments) return false;
    final attachment = _Attachment(
      listenable: listenable,
      owner: clipOwner(owner),
      via: via,
      tag: tags.of(listenable),
      last: _readValue(listenable),
      hasValue: listenable is ValueListenable,
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

  // Runs inside the notifying call (watch out for): it only reads and
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
      };
      if (attachment.hasValue) {
        final before = attachment.last;
        final after = _readValue(attachment.listenable);
        attachment.last = after;
        data['before'] = _shown(before, attachment.owner);
        data['after'] = _shown(after, attachment.owner);
        if (_sameText(data['before'], data['after'])) data['same'] = true;
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

  /// How many `ChangeNotifier.notifyListeners` calls are on [stack]: 1 for
  /// a plain notify, 2 or more when a notify runs inside the listener of
  /// another one (shape 2 of the lens). A line counts when it names
  /// `notifyListeners` and `change_notifier.dart`, which holds in the VM
  /// and the web formats.
  static int notifyDepth(String stack) {
    var n = 0;
    for (final line in stack.split('\n')) {
      if (line.contains('notifyListeners') &&
          line.contains('change_notifier.dart')) {
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
  });

  final Listenable listenable;
  final String owner;
  final String via;
  final String tag;
  final bool hasValue;

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
