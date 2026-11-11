import 'dart:ui' show Brightness;

import 'package:flutter/painting.dart';

import '../env/environment_controller.dart';

/// The most runs one `stress_matrix` call makes.
const int stressMaxRuns = 48;

/// One run of the stress matrix: an environment and its short name.
class StressRun {
  const StressRun(this.label, this.environment);

  /// For example `width 320` or `width 320 · text 1.3× · RTL · dark`.
  final String label;

  final Environment environment;
}

/// The runs of a stress matrix around [base] (plan Milestone 12, step 8).
///
/// By default one axis varies at a time, the rest stay as in [base]: each
/// width (at [height], the app's height now), then each text scale, each
/// direction and each brightness: 4 + 3 + 1 + 1 = 9 runs. With [full],
/// every combination, at most [stressMaxRuns].
List<StressRun> stressRuns({
  required Environment base,
  required double height,
  List<double>? widths,
  List<double>? textScales,
  List<TextDirection>? directions,
  List<Brightness>? brightness,
  bool full = false,
}) {
  final ws = widths ?? const [320, 360, 414, 768];
  final ts = textScales ?? const [1.3, 1.6, 2.0];
  final ds = directions ?? const [TextDirection.rtl];
  final bs = brightness ?? const [Brightness.dark];

  String width(double w) => 'width ${_num(w)}';
  String scale(double t) => 'text ${_num(t)}×';
  String direction(TextDirection d) => d.name.toUpperCase();

  if (!full) {
    return [
      for (final w in ws)
        StressRun(width(w), base.copyWith(viewport: () => Size(w, height))),
      for (final t in ts)
        StressRun(scale(t), base.copyWith(textScale: () => t)),
      for (final d in ds)
        StressRun(direction(d), base.copyWith(textDirection: () => d)),
      for (final b in bs) StressRun(b.name, base.copyWith(brightness: () => b)),
    ];
  }
  final runs = <StressRun>[];
  // An empty axis keeps the base value.
  for (final w in ws.isEmpty ? const <double?>[null] : ws) {
    for (final t in ts.isEmpty ? const <double?>[null] : ts) {
      for (final d in ds.isEmpty ? const <TextDirection?>[null] : ds) {
        for (final b in bs.isEmpty ? const <Brightness?>[null] : bs) {
          if (runs.length >= stressMaxRuns) return runs;
          var env = base;
          final label = <String>[];
          if (w != null) {
            env = env.copyWith(viewport: () => Size(w, height));
            label.add(width(w));
          }
          if (t != null) {
            env = env.copyWith(textScale: () => t);
            label.add(scale(t));
          }
          if (d != null) {
            env = env.copyWith(textDirection: () => d);
            label.add(direction(d));
          }
          if (b != null) {
            env = env.copyWith(brightness: () => b);
            label.add(b.name);
          }
          runs.add(StressRun(label.join(' · '), env));
        }
      }
    }
  }
  return runs;
}

String _num(double value) =>
    value == value.roundToDouble() ? '${value.round()}' : '$value';
