import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

const String _viewType = 'pinpoint-example-html';
bool _registered = false;

Widget buildHtmlView() {
  if (!_registered) {
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final element = web.document.createElement('div') as web.HTMLDivElement;
      element.textContent = 'Plain HTML element';
      element.style
        ..width = '100%'
        ..height = '100%'
        ..backgroundColor = '#ffe082'
        ..display = 'flex'
        ..alignItems = 'center'
        ..justifyContent = 'center';
      return element;
    });
    _registered = true;
  }
  return const HtmlElementView(viewType: _viewType);
}
