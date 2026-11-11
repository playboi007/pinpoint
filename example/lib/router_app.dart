import 'package:flutter/material.dart';
import 'package:pinpoint/pinpoint.dart';

/// Milestone 12: an app that navigates with a `Router` instead of named
/// routes, so the agent's `navigate` and `back` are checked on both kinds.
///
/// `flutter run -d chrome -t lib/router_app.dart`
void main() => runApp(const RouterExampleApp());

class RouterExampleApp extends StatefulWidget {
  const RouterExampleApp({super.key, this.controller});

  /// Pinpoint's controller; the wrapper makes its own when null.
  final PinPointController? controller;

  @override
  State<RouterExampleApp> createState() => _RouterExampleAppState();
}

class _RouterExampleAppState extends State<RouterExampleApp> {
  final _PathDelegate _delegate = _PathDelegate();

  late final RouterConfig<String> _config = RouterConfig<String>(
    routeInformationProvider: PlatformRouteInformationProvider(
      initialRouteInformation: RouteInformation(uri: Uri.parse('/')),
    ),
    routeInformationParser: _PathParser(),
    routerDelegate: _delegate,
    backButtonDispatcher: RootBackButtonDispatcher(),
  );

  @override
  void dispose() {
    _delegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'Pinpoint router example',
    theme: ThemeData(colorSchemeSeed: Colors.teal),
    routerConfig: _config,
    builder: (context, child) => PinPointWrapper(
      controller: widget.controller,
      config: PinPointConfig(sinks: [HttpSink.bridge(), const ClipboardSink()]),
      child: child,
    ),
  );
}

class _PathParser extends RouteInformationParser<String> {
  @override
  Future<String> parseRouteInformation(RouteInformation routeInformation) =>
      Future<String>.value(
        routeInformation.uri.path.isEmpty ? '/' : routeInformation.uri.path,
      );

  @override
  RouteInformation restoreRouteInformation(String configuration) =>
      RouteInformation(uri: Uri.parse(configuration));
}

/// A stack of paths: a new path is pushed on top, `/` starts over.
class _PathDelegate extends RouterDelegate<String>
    with ChangeNotifier, PopNavigatorRouterDelegateMixin<String> {
  @override
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  List<String> _stack = ['/'];

  @override
  String get currentConfiguration => _stack.last;

  @override
  Future<void> setNewRoutePath(String configuration) async {
    _stack = configuration == '/' ? ['/'] : [..._stack, configuration];
    notifyListeners();
  }

  void _open(String path) => setNewRoutePath(path);

  @override
  Widget build(BuildContext context) => Navigator(
    key: navigatorKey,
    pages: [
      for (final path in _stack)
        MaterialPage<void>(
          key: ValueKey<String>(path),
          name: path,
          child: switch (path) {
            '/settings' => const _Page(title: 'Settings'),
            '/about' => const _Page(title: 'About'),
            _ => _Home(open: _open),
          },
        ),
    ],
    onDidRemovePage: (page) {
      _stack = [
        for (final path in _stack)
          if (path != page.name) path,
      ];
      if (_stack.isEmpty) _stack = ['/'];
      notifyListeners();
    },
  );
}

class _Home extends StatelessWidget {
  const _Home({required this.open});

  final ValueChanged<String> open;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Router example')),
    body: ListView(
      children: [
        ListTile(title: const Text('Settings'), onTap: () => open('/settings')),
        ListTile(title: const Text('About'), onTap: () => open('/about')),
      ],
    ),
  );
}

class _Page extends StatelessWidget {
  const _Page({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: Center(child: Text('The $title page')),
  );
}
