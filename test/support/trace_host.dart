import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/trace/trace_session.dart';

import 'agent_host.dart';

/// An app under [PinPointWrapper] with no bridge, for the flight recorder's
/// tests (PLAN-v2 Milestone 13).
Widget traceApp({
  required PinPointController controller,
  required Widget home,
  PinPointConfig config = const PinPointConfig(),
  Map<String, WidgetBuilder> routes = const {},
}) => MaterialApp(
  routes: routes,
  builder: (context, child) =>
      PinPointWrapper(controller: controller, config: config, child: child),
  home: home,
);

/// The running session's recorder. Fails when there is none.
TraceRecorder get recorder => TraceSession.current!.recorder;

/// Runs [tool] in the app, as the bridge would, and returns its answer.
Future<Map<String, Object?>> runTool(
  WidgetTester tester,
  PinPointController controller,
  String tool, [
  Map<String, Object?> args = const {},
]) => drive(tester, controller.agent.run(tool, args));

/// Runs [tool] and returns its result; fails when the tool failed.
Future<Map<String, Object?>> toolResult(
  WidgetTester tester,
  PinPointController controller,
  String tool, [
  Map<String, Object?> args = const {},
]) async {
  final answer = await runTool(tester, controller, tool, args);
  expect(answer['ok'], isTrue, reason: '$tool: $answer');
  return answer['result']! as Map<String, Object?>;
}

/// The compact lines of `get_trace` with [args].
Future<List<String>> traceLines(
  WidgetTester tester,
  PinPointController controller, [
  Map<String, Object?> args = const {},
]) async {
  final result = await toolResult(tester, controller, 'get_trace', args);
  final lines = result['lines']! as String;
  return lines.isEmpty ? const <String>[] : lines.split('\n');
}
