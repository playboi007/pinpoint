import 'package:flutter/material.dart';
import 'package:pinpoint/pinpoint.dart';

import 'screens/bug_zoo_screen.dart';
import 'screens/counter_screen.dart';
import 'screens/custom_paint_screen.dart';
import 'screens/dialog_sheet_screen.dart';
import 'screens/environment_probe_screen.dart';
import 'screens/form_screen.dart';
import 'screens/html_view_screen.dart';
import 'screens/long_list_screen.dart';
import 'screens/nested_navigator_screen.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key, this.controller});

  /// Pinpoint's controller; the wrapper makes its own when null. Tests pass
  /// one to drive the what-if switches.
  final PinPointController? controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pinpoint example',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      // Above the Navigator, so dialogs and routes render beneath Pinpoint.
      // Run `dart run pinpoint:bridge` in this folder first: each Send
      // writes the note into .pinpoint/open/. The clipboard sink needs no
      // bridge, so a note is never lost when the bridge is stopped.
      builder: (context, child) => PinPointWrapper(
        controller: controller,
        config: PinPointConfig(
          sinks: [HttpSink.bridge(), const ClipboardSink()],
        ),
        child: child,
      ),
      home: const HomeScreen(),
      // Named, so a note records its route and the agent's `navigate` and
      // `verify_note` can go there.
      routes: {
        for (final screen in HomeScreen.screens)
          screen.route: (_) => screen.build(),
        HomeScreen.bugZooRoute: (_) => const BugZooScreen(),
      },
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  static const String bugZooTitle = 'Bug zoo';
  static const String bugZooRoute = '/bug-zoo';

  static const List<({String title, String route, Widget Function() build})>
  screens = [
    (title: 'Counter and spinner', route: '/counter', build: CounterScreen.new),
    (title: 'Long list', route: '/long-list', build: LongListScreen.new),
    (
      title: 'Dialog and bottom sheet',
      route: '/dialog-sheet',
      build: DialogSheetScreen.new,
    ),
    (
      title: 'Nested navigator',
      route: '/nested',
      build: NestedNavigatorScreen.new,
    ),
    (
      title: 'CustomPaint',
      route: '/custom-paint',
      build: CustomPaintScreen.new,
    ),
    (title: 'Form', route: '/form', build: FormScreen.new),
    (title: 'HtmlElementView', route: '/html-view', build: HtmlViewScreen.new),
    (
      title: 'What-if probe',
      route: '/what-if',
      build: EnvironmentProbeScreen.new,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pinpoint example')),
      body: ListView(
        children: [
          for (final screen in screens)
            ListTile(
              title: Text(screen.title),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).pushNamed(screen.route),
            ),
          // Not in [screens]: its planted errors would fail every test that
          // walks the clean screens.
          ListTile(
            title: const Text(bugZooTitle),
            subtitle: const Text('One planted problem of each kind'),
            trailing: const Icon(Icons.bug_report_outlined),
            onTap: () => Navigator.of(context).pushNamed(bugZooRoute),
          ),
        ],
      ),
    );
  }
}
