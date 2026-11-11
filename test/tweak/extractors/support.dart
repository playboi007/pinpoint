import 'package:flutter/rendering.dart';
import 'package:pinpoint/pinpoint.dart';

/// Applies [value] to [name] in the section [extract] reads from [ro].
void setProperty(
  RenderObject ro,
  InfoExtractor extract,
  String name,
  Object? value,
) {
  final property = extract(ro)!.properties.firstWhere((p) => p.name == name);
  assert(property.editable, '$name is read-only');
  property.applyValue(value);
}

/// [name]'s label as [extract] reads it from [ro] now.
String labelOf(RenderObject ro, InfoExtractor extract, String name) =>
    extract(ro)!.properties.firstWhere((p) => p.name == name).label;
