import 'package:flutter/material.dart';

import 'screens/custom_paint_screen.dart';
import 'screens/dialog_sheet_screen.dart';
import 'screens/form_screen.dart';
import 'screens/html_view_screen.dart';
import 'screens/long_list_screen.dart';
import 'screens/nested_navigator_screen.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pinpoint example',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  static const List<({String title, Widget Function() build})> screens = [
    (title: 'Long list', build: LongListScreen.new),
    (title: 'Dialog and bottom sheet', build: DialogSheetScreen.new),
    (title: 'Nested navigator', build: NestedNavigatorScreen.new),
    (title: 'CustomPaint', build: CustomPaintScreen.new),
    (title: 'Form', build: FormScreen.new),
    (title: 'HtmlElementView', build: HtmlViewScreen.new),
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
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => screen.build()),
              ),
            ),
        ],
      ),
    );
  }
}
