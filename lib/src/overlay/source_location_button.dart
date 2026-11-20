import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/controls.dart';
import '../theme/pinpoint_motion.dart';
import '../theme/pinpoint_tokens.dart';

/// [path] cut to start at its `lib/`, `test/`, `bin/`, `web/` or
/// `integration_test/` directory, so `/Users/me/app/lib/src/x.dart` shows as
/// `lib/src/x.dart`. A path that is already relative, or has none of those
/// directories, stays as it is.
String shortSourcePath(String path) {
  final normal = path.replaceAll(r'\', '/');
  final absolute =
      normal.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(normal);
  if (!absolute) return normal;
  final segments = normal.split('/');
  const roots = <String>{'lib', 'test', 'bin', 'web', 'integration_test'};
  for (var i = 1; i < segments.length - 1; i++) {
    if (roots.contains(segments[i])) return segments.sublist(i).join('/');
  }
  return normal;
}

/// A small folder button that stands for a source location.
///
/// The location itself is not printed in the row: a long path buries the
/// names beside it. Hover the button for [tipDelay] and a tip says "Show
/// location in code". Click it and a popover opens below it (above when
/// there is no room) with the short path, the line and a Copy button. Esc or
/// a click outside closes the popover.
///
/// The tip and the popover are drawn in the nearest [Overlay], in the
/// drafting look: paper, 1 px ink border, hard shadow. Their fades take
/// their durations from [PinPointMotion], so reduced motion shows them at
/// once.
class SourceLocationButton extends StatefulWidget {
  const SourceLocationButton({
    super.key,
    required this.path,
    this.line,
    this.onToast,
    this.tipKey,
    this.popoverKey,
    this.copyKey,
  });

  /// The words of the tip.
  static const String tipText = 'Show location in code';

  /// How long the pointer must rest on the button before the tip shows.
  static const Duration tipDelay = Duration(seconds: 2);

  /// The path as it is shown, for example `lib/src/main.dart`.
  final String path;

  /// The 1-based line, or null when only the file is known.
  final int? line;

  /// Told "Copied path:line" after a copy. When it is set the popover closes
  /// after the copy, and the caller shows the message as a toast. When it is
  /// null the popover stays open and its button says "Copied".
  final ValueChanged<String>? onToast;

  final Key? tipKey;
  final Key? popoverKey;
  final Key? copyKey;

  /// `path:line`, or `path` with no line.
  String get label => line == null ? path : '$path:$line';

  @override
  State<SourceLocationButton> createState() => _SourceLocationButtonState();
}

class _SourceLocationButtonState extends State<SourceLocationButton>
    with SingleTickerProviderStateMixin {
  final LayerLink _link = LayerLink();
  final OverlayPortalController _tip = OverlayPortalController(
    debugLabel: 'pinpoint location tip',
  );
  final OverlayPortalController _popover = OverlayPortalController(
    debugLabel: 'pinpoint location popover',
  );
  late final AnimationController _fade = AnimationController(vsync: this)
    ..addStatusListener((status) {
      if (status == AnimationStatus.dismissed) _tip.hide();
    });
  Timer? _timer;
  bool _above = false;

  @override
  void dispose() {
    _timer?.cancel();
    _fade.dispose();
    super.dispose();
  }

  void _enter(PointerEnterEvent event) {
    if (_popover.isShowing) return;
    _timer?.cancel();
    _timer = Timer(SourceLocationButton.tipDelay, _showTip);
  }

  void _leave(PointerExitEvent event) => _hideTip();

  void _showTip() {
    _timer = null;
    if (!mounted || _popover.isShowing) return;
    _tip.show();
    final motion = PinPointMotion.of(context);
    _fade.duration = motion.quick;
    unawaited(_fade.forward());
  }

  void _hideTip() {
    _timer?.cancel();
    _timer = null;
    if (!_tip.isShowing) return;
    _fade.duration = PinPointMotion.of(context).snap;
    unawaited(_fade.reverse());
  }

  void _open() {
    _timer?.cancel();
    _timer = null;
    if (_tip.isShowing) {
      _fade.stop();
      _tip.hide();
    }
    final box = context.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize) {
      final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
      _above =
          bottom + _SourcePopover.height + 8 >
          MediaQuery.sizeOf(context).height;
    }
    if (_popover.isShowing) {
      _popover.hide();
    } else {
      _popover.show();
    }
    setState(() {});
  }

  void _close() {
    if (_popover.isShowing) _popover.hide();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _tip,
        overlayChildBuilder: (context) => _anchored(
          tokens,
          below: true,
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: FadeTransition(
                opacity: _fade,
                child: DecoratedBox(
                  key: widget.tipKey,
                  decoration: tokens.surface(1),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    child: Text(
                      SourceLocationButton.tipText,
                      style: tokens.micro.copyWith(color: tokens.ink),
                      softWrap: false,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        child: OverlayPortal(
          controller: _popover,
          overlayChildBuilder: (context) => Stack(
            fit: StackFit.expand,
            children: [
              // A click outside closes the popover.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _close,
                ),
              ),
              _anchored(
                tokens,
                below: !_above,
                child: _SourcePopover(
                  key: widget.popoverKey,
                  path: widget.path,
                  line: widget.line,
                  label: widget.label,
                  copyKey: widget.copyKey,
                  onToast: widget.onToast,
                  onClose: _close,
                ),
              ),
            ],
          ),
          child: MouseRegion(
            onEnter: _enter,
            onExit: _leave,
            child: Semantics(
              label: SourceLocationButton.tipText,
              child: ExcludeSemantics(
                child: DraftIconButton(
                  icon: PinPointIcons.folderOpen,
                  iconSize: 14,
                  extent: 20,
                  onPressed: _open,
                  color: tokens.muted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// [child] at the button's right edge, below it, or above it when [below]
  /// is false. It grows to the left, as the button is at the end of a row.
  Widget _anchored(
    PinPointTokens tokens, {
    required bool below,
    required Widget child,
  }) {
    return Positioned(
      left: 0,
      top: 0,
      child: CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        targetAnchor: below ? Alignment.bottomRight : Alignment.topRight,
        followerAnchor: below ? Alignment.topRight : Alignment.bottomRight,
        offset: Offset(0, below ? 4 : -4),
        child: child,
      ),
    );
  }
}

/// The popover: path, line and Copy.
class _SourcePopover extends StatefulWidget {
  const _SourcePopover({
    super.key,
    required this.path,
    required this.line,
    required this.label,
    required this.copyKey,
    required this.onToast,
    required this.onClose,
  });

  /// About how tall it is, to choose below or above the button.
  static const double height = 116;
  static const double width = 280;

  final String path;
  final int? line;
  final String label;
  final Key? copyKey;
  final ValueChanged<String>? onToast;
  final VoidCallback onClose;

  @override
  State<_SourcePopover> createState() => _SourcePopoverState();
}

class _SourcePopoverState extends State<_SourcePopover> {
  final FocusNode _focus = FocusNode(debugLabel: 'pinpoint location popover');
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    // Takes the focus once it is in the tree, so Esc reaches it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.label));
    if (!mounted) return;
    final toast = widget.onToast;
    if (toast != null) {
      toast('Copied ${widget.label}');
      widget.onClose();
    } else {
      setState(() => _copied = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final slash = widget.path.lastIndexOf('/');
    final directory = slash < 0 ? '' : widget.path.substring(0, slash + 1);
    final file = widget.path.substring(slash + 1);
    final path = tokens.value.copyWith(fontSize: 11, height: 15 / 11);
    final motion = PinPointMotion.of(context);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: motion.quick,
      curve: PinPointMotion.enter,
      builder: (context, t, child) => Opacity(opacity: t, child: child),
      child: Focus(
        focusNode: _focus,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            widget.onClose();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: SizedBox(
          width: _SourcePopover.width,
          child: DraftSurface(
            elevation: 2,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(10, 8, 10, 4),
                  child: CapsText('SOURCE LOCATION'),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: directory,
                          style: path.copyWith(color: tokens.muted),
                        ),
                        TextSpan(
                          text: file,
                          style: path.copyWith(fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  ),
                ),
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: tokens.rule)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.line == null ? '' : 'LINE ${widget.line}',
                          style: tokens.caps,
                        ),
                      ),
                      DraftButton.outline(
                        key: widget.copyKey,
                        label: _copied ? 'Copied' : 'Copy',
                        icon: _copied
                            ? PinPointIcons.check
                            : PinPointIcons.contentCopy,
                        onPressed: _copy,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
