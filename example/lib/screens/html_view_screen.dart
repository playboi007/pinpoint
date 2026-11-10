import 'package:flutter/material.dart';

import 'html_view_stub.dart' if (dart.library.js_interop) 'html_view_web.dart';

class HtmlViewScreen extends StatelessWidget {
  const HtmlViewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('HtmlElementView')),
      body: Center(child: SizedBox(width: 320, height: 200, child: buildHtmlView())),
    );
  }
}
