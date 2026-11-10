import 'dart:math' as math;
import 'dart:ui' show ClipOp;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'device_presets.dart';
import 'environment_controller.dart';

/// Re-provides what the app inherits, with the [environment]'s overrides:
/// `MediaQuery` > `Directionality` > `Theme`.
///
/// `PinPointWrapper` sits in `MaterialApp.builder`: above the Navigator and
/// below the app's own `MediaQuery`, `Theme` and `Directionality`. What
/// this widget provides is what every screen, dialog and sheet sees.
///
/// All three widgets are always built, with the real values when nothing is
/// overridden, so switching an override on or off never changes the shape
/// of the tree and never remounts the app (engineering rule 5).
class EnvironmentHost extends StatelessWidget {
  const EnvironmentHost({
    super.key,
    required this.environment,
    this.themeVariants = const <String, ThemeData>{},
    required this.child,
  });

  final Environment environment;

  /// `PinPointConfig.themeVariants`: themes the app supplies by name.
  final Map<String, ThemeData> themeVariants;

  final Widget child;

  /// The `MediaQuery` the app gets: [real] with the overrides.
  ///
  /// The size is the viewport, so `MediaQuery.sizeOf` and a `LayoutBuilder`
  /// agree. Code that reads `View.of(context).physicalSize` or
  /// `PlatformDispatcher` directly still sees the real window: that is a
  /// finding about the app, not a bug in Pinpoint.
  ///
  /// [brightness] is the overridden theme's brightness, so an app that
  /// reads `platformBrightness` agrees with the theme it gets.
  static MediaQueryData mediaFor(
    MediaQueryData real,
    Environment env, {
    Brightness? brightness,
  }) {
    var data = real;
    if (env.viewport case final size?) data = data.copyWith(size: size);
    if (env.textScale case final scale?) {
      data = data.copyWith(textScaler: TextScaler.linear(scale));
    }
    if (env.boldText case final bold?) data = data.copyWith(boldText: bold);
    if (env.safeArea case final insets?) {
      data = data.copyWith(padding: insets, viewPadding: insets);
    }
    if (env.keyboardHeight case final height? when height > 0) {
      data = data.copyWith(
        viewInsets: data.viewInsets.copyWith(bottom: height),
        // As the engine does: the keyboard covers the bottom inset, so the
        // padding loses it; viewPadding keeps it.
        padding: data.padding.copyWith(
          bottom: math.max(0, data.viewPadding.bottom - height),
        ),
      );
    }
    if (brightness != null) {
      data = data.copyWith(platformBrightness: brightness);
    }
    // The device pixel ratio is never changed: it cannot be faked. A
    // 390-wide viewport on a 1x laptop screen renders at 1x.
    return data;
  }

  /// The theme the app gets, or null for the one it already has.
  ///
  /// `MaterialApp` chose its theme above the wrapper, so overriding
  /// `platformBrightness` alone changes nothing. Light and dark use the
  /// app's own `theme` and `darkTheme`, found as widgets, without a
  /// dependency.
  ThemeData? _overriddenTheme(BuildContext context, ThemeData inherited) {
    ThemeData? theme = themeVariants[environment.themeVariant];
    if (theme == null && environment.brightness != null) {
      final app = context.findAncestorWidgetOfExactType<MaterialApp>();
      theme = environment.brightness == Brightness.dark
          ? app?.darkTheme ?? ThemeData(brightness: Brightness.dark)
          : app?.theme ?? ThemeData();
    }
    if (environment.seedColor case final seed?) {
      final base = theme ?? inherited;
      // Material 3 only: in a Material 2 theme, copyWith(colorScheme:)
      // does not re-derive the component themes, so the colors would mix.
      // The panel says so and disables the switch.
      if (base.useMaterial3) {
        theme = base.copyWith(
          colorScheme: ColorScheme.fromSeed(
            seedColor: seed,
            brightness: base.brightness,
          ),
        );
      }
    }
    return theme;
  }

  @override
  Widget build(BuildContext context) {
    // These subscribe this element, which is Pinpoint's own, never an app
    // element (engineering rule 3). It must rebuild when the real values
    // change anyway.
    final real =
        MediaQuery.maybeOf(context) ??
        MediaQueryData.fromView(View.of(context));
    final inherited = Theme.of(context);
    final theme = _overriddenTheme(context, inherited);
    return MediaQuery(
      data: mediaFor(real, environment, brightness: theme?.brightness),
      child: Directionality(
        // Only the direction: strings stay in the current locale.
        textDirection:
            environment.textDirection ??
            Directionality.maybeOf(context) ??
            TextDirection.ltr,
        child: Theme(data: theme ?? inherited, child: child),
      ),
    );
  }
}

/// Lays the app out at [viewport] and centers it, scaled down when the
/// window is smaller. Paints a neutral checker around it, its size above
/// it, and the fake keyboard over its bottom.
///
/// With no viewport it passes its constraints straight to the app, so the
/// app sees exactly what it would without Pinpoint.
class ViewportFrame extends SingleChildRenderObjectWidget {
  const ViewportFrame({
    super.key,
    this.viewport,
    this.keyboardHeight = 0,
    super.child,
  });

  /// The app's size in logical pixels; null for the whole window.
  final Size? viewport;

  /// Height of the fake keyboard's grey block, at the app's bottom.
  final double keyboardHeight;

  @override
  RenderViewportFrame createRenderObject(BuildContext context) =>
      RenderViewportFrame(viewport: viewport, keyboardHeight: keyboardHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderViewportFrame renderObject,
  ) {
    renderObject
      ..viewport = viewport
      ..keyboardHeight = keyboardHeight;
  }
}

/// The render object of [ViewportFrame].
///
/// The app's boundary is no longer at the screen's origin, and it can be
/// scaled. Everything that maps between the app and the screen goes through
/// [applyPaintTransform], so `getTransformTo(null)` (the picker, the
/// outlines, the pins) and the screenshot's inverse transform stay right.
class RenderViewportFrame extends RenderBox
    with RenderObjectWithChildMixin<RenderBox> {
  RenderViewportFrame({this._viewport, this._keyboardHeight = 0});

  static const Color backdrop = Color(0xFFE6E6E6);
  static const Color checker = Color(0xFFD4D4D4);
  static const Color keyboard = Color(0xFFBDBDBD);
  static const double _square = 12;
  static const double _labelGap = 4;

  Size? get viewport => _viewport;
  Size? _viewport;
  set viewport(Size? value) {
    if (value == _viewport) return;
    _viewport = value;
    markNeedsLayout();
  }

  double get keyboardHeight => _keyboardHeight;
  double _keyboardHeight;
  set keyboardHeight(double value) {
    if (value == _keyboardHeight) return;
    _keyboardHeight = value;
    markNeedsPaint();
  }

  /// The app's scale: 1 unless the window is smaller than the viewport.
  double get scale => _scale;
  double _scale = 1;

  Offset _origin = Offset.zero;

  /// The app's rect in this render object's space.
  Rect get appRect =>
      child == null ? Offset.zero & size : _origin & (child!.size * _scale);

  /// The fake keyboard's rect in this render object's space, or null.
  Rect? get keyboardRect {
    final app = child?.size;
    if (_keyboardHeight <= 0 || app == null) return null;
    final height = math.min(_keyboardHeight, app.height);
    return MatrixUtils.transformRect(
      _childTransform,
      Rect.fromLTWH(0, app.height - height, app.width, height),
    );
  }

  Matrix4 get _childTransform =>
      Matrix4.diagonal3Values(_scale, _scale, 1)
        ..setTranslationRaw(_origin.dx, _origin.dy, 0);

  final LayerHandle<TransformLayer> _transformLayer =
      LayerHandle<TransformLayer>();
  final LayerHandle<ClipRectLayer> _clipLayer = LayerHandle<ClipRectLayer>();

  Path? _checker;
  Size? _checkerSize;
  TextPainter? _label;

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final viewport = _viewport;
    if (viewport == null) {
      return child?.getDryLayout(constraints) ?? constraints.smallest;
    }
    return _frameSize(constraints, viewport);
  }

  static Size _frameSize(BoxConstraints constraints, Size viewport) =>
      constraints.biggest.isFinite
      ? constraints.biggest
      : constraints.constrain(viewport);

  @override
  void performLayout() {
    final child = this.child;
    final viewport = _viewport;
    if (viewport == null) {
      _scale = 1;
      _origin = Offset.zero;
      if (child == null) {
        size = constraints.smallest;
        return;
      }
      child.layout(constraints, parentUsesSize: true);
      size = child.size;
      return;
    }
    size = _frameSize(constraints, viewport);
    child?.layout(BoxConstraints.tight(viewport), parentUsesSize: true);
    // Scale, never overflow: a window smaller than the viewport shows the
    // whole app, smaller.
    _scale = math.min(
      1,
      math.min(size.width / viewport.width, size.height / viewport.height),
    );
    // Whole logical pixels, so text is not blurred by a half-pixel shift.
    _origin = Offset(
      ((size.width - viewport.width * _scale) / 2).floorToDouble(),
      ((size.height - viewport.height * _scale) / 2).floorToDouble(),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.multiply(_childTransform);
  }

  @override
  Rect? describeApproximatePaintClip(RenderObject child) =>
      _viewport == null ? null : appRect;

  @override
  bool hitTestSelf(Offset position) =>
      // The fake keyboard takes the taps on it, as a real one does.
      keyboardRect?.contains(position) ?? false;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    // A pointer outside the frame is over nothing.
    if (!appRect.contains(position)) return false;
    if (keyboardRect?.contains(position) ?? false) return false;
    if (_viewport == null) return child.hitTest(result, position: position);
    return result.addWithPaintTransform(
      transform: _childTransform,
      position: position,
      hitTest: (result, position) => child.hitTest(result, position: position),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final viewport = _viewport;
    if (viewport == null) {
      _transformLayer.layer = null;
      _clipLayer.layer = null;
      context.paintChild(child, offset);
      _paintKeyboard(context.canvas, offset, child.size);
      return;
    }
    _paintBackdrop(context.canvas, offset, viewport);
    _transformLayer.layer = context.pushTransform(
      needsCompositing,
      offset,
      _childTransform,
      (context, offset) {
        // The app's own overflow stays inside the frame.
        _clipLayer.layer = context.pushClipRect(
          needsCompositing,
          offset,
          Offset.zero & viewport,
          (context, offset) {
            context.paintChild(child, offset);
            _paintKeyboard(context.canvas, offset, viewport);
          },
          oldLayer: _clipLayer.layer,
        );
      },
      oldLayer: _transformLayer.layer,
    );
  }

  /// In the app's space: a grey block over its bottom. It is outside the
  /// app's boundary, so screenshots do not show it.
  void _paintKeyboard(Canvas canvas, Offset offset, Size app) {
    if (_keyboardHeight <= 0) return;
    final height = math.min(_keyboardHeight, app.height);
    canvas.drawRect(
      Rect.fromLTWH(
        offset.dx,
        offset.dy + app.height - height,
        app.width,
        height,
      ),
      Paint()..color = keyboard,
    );
  }

  /// The checker around the app, and the size label above it.
  void _paintBackdrop(Canvas canvas, Offset offset, Size viewport) {
    final frame = appRect.shift(offset);
    canvas
      ..save()
      ..clipRect(frame, clipOp: ClipOp.difference)
      ..drawRect(offset & size, Paint()..color = backdrop)
      ..translate(offset.dx, offset.dy)
      ..drawPath(_checkerFor(size), Paint()..color = checker)
      ..restore();

    final label = _labelFor(viewport);
    final room = frame.top - offset.dy;
    final below = offset.dy + size.height - frame.bottom;
    final double top;
    if (room >= label.height + _labelGap) {
      top = frame.top - label.height - _labelGap;
    } else if (below >= label.height + _labelGap) {
      top = frame.bottom + _labelGap;
    } else {
      return;
    }
    label.paint(canvas, Offset(frame.center.dx - label.width / 2, top));
  }

  Path _checkerFor(Size size) {
    if (_checker != null && _checkerSize == size) return _checker!;
    final path = Path();
    for (var y = 0; y * _square < size.height; y++) {
      for (var x = y.isEven ? 0 : 1; x * _square < size.width; x += 2) {
        path.addRect(Rect.fromLTWH(x * _square, y * _square, _square, _square));
      }
    }
    _checkerSize = size;
    return _checker = path;
  }

  TextPainter _labelFor(Size viewport) {
    final text =
        '${sizeLabelOf(viewport)}'
        '${_scale < 1 ? ' at ${(_scale * 100).round()}%' : ''}';
    final current = _label;
    if (current != null && (current.text as TextSpan?)?.text == text) {
      return current;
    }
    current?.dispose();
    return _label = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(fontSize: 12, color: Color(0xFF616161)),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  /// The size label's text after the last paint, or null.
  @visibleForTesting
  String? get debugLabelText => (_label?.text as TextSpan?)?.text;

  @override
  void dispose() {
    _transformLayer.layer = null;
    _clipLayer.layer = null;
    _label?.dispose();
    super.dispose();
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(DiagnosticsProperty<Size?>('viewport', viewport))
      ..add(DoubleProperty('scale', scale, defaultValue: 1.0))
      ..add(DoubleProperty('keyboardHeight', keyboardHeight, defaultValue: 0));
  }
}
