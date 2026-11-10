import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// A viewport size the what-if panel offers.
@immutable
class DevicePreset {
  const DevicePreset(this.name, this.size);

  /// For example `Phone`.
  final String name;

  /// Logical pixels.
  final Size size;

  /// For example `390 × 844`.
  String get sizeLabel => sizeLabelOf(size);

  @override
  String toString() => '$name $sizeLabel';
}

/// `390 × 844`, without trailing `.0`.
String sizeLabelOf(Size size) =>
    '${_number(size.width)} × ${_number(size.height)}';

String _number(double value) => value == value.truncateToDouble()
    ? value.toInt().toString()
    : value.toStringAsFixed(1);

/// The viewport presets, smallest first. A rotate button swaps width and
/// height, so there are no landscape copies.
const List<DevicePreset> devicePresets = [
  DevicePreset('Small phone', Size(360, 800)),
  DevicePreset('Phone', Size(390, 844)),
  DevicePreset('Large phone', Size(412, 915)),
  DevicePreset('Small tablet', Size(600, 960)),
  DevicePreset('Tablet', Size(820, 1180)),
  DevicePreset('Laptop', Size(1280, 800)),
  DevicePreset('Desktop', Size(1440, 900)),
  DevicePreset('Full HD', Size(1920, 1080)),
];

/// Text scale steps for `MediaQuery.textScaler`.
const List<double> textScaleSteps = [0.85, 1.0, 1.3, 1.5, 2.0];

/// Slow motion steps for `timeDilation`.
const List<double> slowMotionSteps = [1, 2, 5, 10];

/// Safe area of a phone with a notch and a home indicator.
const EdgeInsets notchSafeArea = EdgeInsets.only(top: 59, bottom: 34);

/// Height of the fake on-screen keyboard, in logical pixels. A phone
/// keyboard is 260 to 340 px high.
const double fakeKeyboardHeight = 300;

/// Seed colors for the color scheme switch.
const List<Color> seedColors = [
  Color(0xFF6750A4),
  Color(0xFF2962FF),
  Color(0xFF00897B),
  Color(0xFFE65100),
  Color(0xFFC2185B),
];
