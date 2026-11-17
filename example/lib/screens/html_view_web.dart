import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:web/web.dart' as web;

import 'html_view_elements.dart';

/// `package:web` types `MouseEvent.clientX`/`clientY` as `int`, but browsers
/// report fractional `double` coordinates on high-DPI displays; reading as `num`
/// avoids DDC's `_asInt` `TypeError`.
extension type _PointerCoords(JSObject _) implements JSObject {
  external num get clientX;
  external num get clientY;
}

const String _viewType = 'pinpoint-example-html-canvas-v2';
bool _registered = false;

final Map<int, web.HTMLDivElement> _containers = <int, web.HTMLDivElement>{};
final Map<int, _WebHtmlViewCanvasState> _mountedStates =
    <int, _WebHtmlViewCanvasState>{};
final Map<String, VoidCallback> _dragCleanups = <String, VoidCallback>{};

void _ensureRegistered() {
  if (_registered) return;
  ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
    final root = web.document.createElement('div') as web.HTMLDivElement;
    root.setAttribute('data-pp-canvas', '$viewId');
    root.style
      ..position = 'relative'
      ..width = '100%'
      ..height = '100%'
      ..overflow = 'hidden'
      ..boxSizing = 'border-box';
    root.style.setProperty('user-select', 'none');
    root.style.setProperty('touch-action', 'none');

    root.addEventListener(
      'pointerdown',
      ((web.Event event) {
        if (event.target == root) {
          _mountedStates[viewId]?.widget.onBackgroundTap();
        }
      }).toJS,
    );

    _containers[viewId] = root;
    return root;
  });
  _registered = true;
}

/// Builds the interactive web [HtmlElementView] canvas.
Widget buildHtmlView({
  required List<PlacedHtmlElement> elements,
  required String? selectedId,
  required bool isDark,
  required bool disablePointerEvents,
  required void Function(String id, double x, double y) onElementMoved,
  required void Function(String id) onElementSelected,
  required void Function(String id) onElementDoubleTapped,
  required void Function(String id) onElementRemoved,
  required void Function(
    String id,
    PlacedHtmlElement Function(PlacedHtmlElement) update,
    String feedback,
  )
  onElementInteracted,
  required VoidCallback onBackgroundTap,
}) {
  return _WebHtmlViewCanvas(
    elements: elements,
    selectedId: selectedId,
    isDark: isDark,
    disablePointerEvents: disablePointerEvents,
    onElementMoved: onElementMoved,
    onElementSelected: onElementSelected,
    onElementDoubleTapped: onElementDoubleTapped,
    onElementRemoved: onElementRemoved,
    onElementInteracted: onElementInteracted,
    onBackgroundTap: onBackgroundTap,
  );
}

class _WebHtmlViewCanvas extends StatefulWidget {
  const _WebHtmlViewCanvas({
    required this.elements,
    required this.selectedId,
    required this.isDark,
    required this.disablePointerEvents,
    required this.onElementMoved,
    required this.onElementSelected,
    required this.onElementDoubleTapped,
    required this.onElementRemoved,
    required this.onElementInteracted,
    required this.onBackgroundTap,
  });

  final List<PlacedHtmlElement> elements;
  final String? selectedId;
  final bool isDark;
  final bool disablePointerEvents;
  final void Function(String id, double x, double y) onElementMoved;
  final void Function(String id) onElementSelected;
  final void Function(String id) onElementDoubleTapped;
  final void Function(String id) onElementRemoved;
  final void Function(
    String id,
    PlacedHtmlElement Function(PlacedHtmlElement) update,
    String feedback,
  )
  onElementInteracted;
  final VoidCallback onBackgroundTap;

  @override
  State<_WebHtmlViewCanvas> createState() => _WebHtmlViewCanvasState();
}

class _NodeRecord {
  _NodeRecord({required this.wrapper, required this.content});

  final web.HTMLDivElement wrapper;
  final web.HTMLElement content;
}

class _WebHtmlViewCanvasState extends State<_WebHtmlViewCanvas> {
  int? _viewId;
  final Map<String, _NodeRecord> _domNodes = <String, _NodeRecord>{};
  final Map<String, PlacedHtmlElement> _latestItems =
      <String, PlacedHtmlElement>{};
  String? _draggingId;

  @override
  void initState() {
    super.initState();
    _ensureRegistered();
  }

  @override
  void didUpdateWidget(covariant _WebHtmlViewCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncDom();
  }

  @override
  void reassemble() {
    super.reassemble();
    for (final entry in _domNodes.entries) {
      _dragCleanups.remove(entry.key)?.call();
      entry.value.wrapper.remove();
    }
    _domNodes.clear();
    _syncDom();
  }

  @override
  void dispose() {
    final id = _viewId;
    if (id != null) {
      _mountedStates.remove(id);
      _containers.remove(id);
    }
    for (final id in _domNodes.keys) {
      _dragCleanups.remove(id)?.call();
    }
    _domNodes.clear();
    _latestItems.clear();
    super.dispose();
  }

  void _onPlatformViewCreated(int viewId) {
    _viewId = viewId;
    _mountedStates[viewId] = this;
    _syncDom();
  }

  void _syncDom() {
    final viewId = _viewId;
    if (viewId == null) return;
    final root = _containers[viewId];
    if (root == null) return;

    _applyCanvasTheme(root, widget.isDark, widget.disablePointerEvents);

    final activeIds = <String>{for (final item in widget.elements) item.id};

    // Remove DOM nodes for deleted elements.
    final toRemove = _domNodes.keys
        .where((id) => !activeIds.contains(id))
        .toList();
    for (final id in toRemove) {
      _dragCleanups.remove(id)?.call();
      _domNodes.remove(id)?.wrapper.remove();
      _latestItems.remove(id);
    }

    // Add or update placed elements.
    for (final item in widget.elements) {
      _latestItems[item.id] = item;
      var record = _domNodes[item.id];
      if (record == null) {
        record = _createItemNode(item);
        _domNodes[item.id] = record;
        root.appendChild(record.wrapper);
      }
      _syncItemContent(record.content, item, widget.isDark);
      _applyItemStyle(
        node: record.wrapper,
        item: item,
        selected: item.id == widget.selectedId,
        isDark: widget.isDark,
        isCurrentlyDragging: _draggingId == item.id,
      );
    }
  }

  void _applyCanvasTheme(
    web.HTMLDivElement root,
    bool isDark,
    bool disablePointerEvents,
  ) {
    final pointerValue = disablePointerEvents ? 'none' : 'auto';
    root.style.pointerEvents = pointerValue;

    // Also update the <flt-platform-view> wrapper and its shadow <flt-platform-view-slot>
    // so dragging a Flutter Draggable from the palette drops cleanly onto DragTarget.
    final platformViewHost = root.parentElement;
    if (platformViewHost != null && platformViewHost.isA<web.HTMLElement>()) {
      (platformViewHost as web.HTMLElement).style.pointerEvents = pointerValue;
      final slotParent = platformViewHost.assignedSlot?.parentElement;
      if (slotParent != null && slotParent.isA<web.HTMLElement>()) {
        (slotParent as web.HTMLElement).style.pointerEvents = pointerValue;
      }
    }

    root.style.backgroundColor = isDark ? '#141720' : '#f8fafc';
    root.style.setProperty(
      'background-image',
      isDark
          ? 'radial-gradient(rgba(255,255,255,0.10) 1px, transparent 1px)'
          : 'radial-gradient(rgba(15,23,42,0.12) 1px, transparent 1px)',
    );
    root.style.setProperty('background-size', '20px 20px');
    root.style.fontFamily =
        '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif';
  }

  _NodeRecord _createItemNode(PlacedHtmlElement item) {
    final template = templateForKind(item.kind);
    final wrapper = web.document.createElement('div') as web.HTMLDivElement;
    wrapper.setAttribute('data-pp-id', item.id);
    wrapper.style
      ..position = 'absolute'
      ..boxSizing = 'border-box'
      ..borderRadius = '10px'
      ..padding = '24px 12px 10px 12px'
      ..cursor = 'grab'
      ..transition = 'box-shadow 120ms ease, border-color 120ms ease';
    wrapper.style.setProperty('user-select', 'none');

    // Top mini header bar with tag pill and delete button.
    final header = web.document.createElement('div') as web.HTMLDivElement;
    header.style
      ..position = 'absolute'
      ..top = '5px'
      ..left = '8px'
      ..right = '6px'
      ..display = 'flex'
      ..alignItems = 'center'
      ..justifyContent = 'space-between'
      ..gap = '6px'
      ..fontSize = '10px'
      ..lineHeight = '1';

    final tagPill = web.document.createElement('span') as web.HTMLSpanElement;
    tagPill.textContent = '${template.tag}  ::';
    tagPill.style
      ..fontFamily = 'ui-monospace, SFMono-Regular, Menlo, monospace'
      ..fontWeight = '600'
      ..opacity = '0.72'
      ..letterSpacing = '0.02em';

    final deleteBtn =
        web.document.createElement('button') as web.HTMLButtonElement;
    deleteBtn.type = 'button';
    deleteBtn.title = 'Remove element';
    deleteBtn.textContent = '×';
    deleteBtn.style
      ..border = 'none'
      ..background = 'transparent'
      ..color = 'inherit'
      ..cursor = 'pointer'
      ..fontSize = '14px'
      ..lineHeight = '14px'
      ..padding = '0 4px'
      ..borderRadius = '4px'
      ..opacity = '0.65';

    deleteBtn.addEventListener(
      'pointerdown',
      ((web.Event event) {
        event.stopPropagation();
      }).toJS,
    );
    deleteBtn.addEventListener(
      'click',
      ((web.Event event) {
        event.stopPropagation();
        widget.onElementRemoved(item.id);
      }).toJS,
    );

    header.appendChild(tagPill);
    header.appendChild(deleteBtn);
    wrapper.appendChild(header);

    // Inner real HTML element.
    final content = _buildInnerHtmlElement(item);
    wrapper.appendChild(content);

    wrapper.addEventListener(
      'dblclick',
      ((web.Event event) {
        event.stopPropagation();
        widget.onElementDoubleTapped(item.id);
      }).toJS,
    );
    wrapper.addEventListener(
      'dragstart',
      ((web.Event event) {
        event.preventDefault();
      }).toJS,
    );

    _dragCleanups[item.id]?.call();
    _dragCleanups[item.id] = _attachDragBehavior(wrapper: wrapper, id: item.id);
    return _NodeRecord(wrapper: wrapper, content: content);
  }

  web.HTMLElement _buildInnerHtmlElement(PlacedHtmlElement item) {
    switch (item.kind) {
      case HtmlElementKind.heading:
        final h1 = web.document.createElement('h1') as web.HTMLHeadingElement;
        h1.style
          ..margin = '0'
          ..fontWeight = '700'
          ..lineHeight = '1.2'
          ..whiteSpace = 'nowrap';
        return h1;

      case HtmlElementKind.paragraph:
        final p = web.document.createElement('p') as web.HTMLParagraphElement;
        p.style
          ..margin = '0'
          ..lineHeight = '1.45';
        return p;

      case HtmlElementKind.button:
        final btn =
            web.document.createElement('button') as web.HTMLButtonElement;
        btn.type = 'button';
        btn.style
          ..padding = '8px 16px'
          ..borderRadius = '8px'
          ..border = 'none'
          ..color = '#ffffff'
          ..fontWeight = '600'
          ..cursor = 'pointer'
          ..whiteSpace = 'nowrap';
        btn.addEventListener(
          'click',
          ((web.Event event) {
            if (_wrapperWasDragged(btn)) return;
            event.stopPropagation();
            final latest = _latestItems[item.id] ?? item;
            final next = latest.clickCount + 1;
            widget.onElementInteracted(
              item.id,
              (cur) => cur.copyWith(clickCount: cur.clickCount + 1),
              'Clicked <button> "${latest.text}" ($next)',
            );
          }).toJS,
        );
        return btn;

      case HtmlElementKind.input:
        final input =
            web.document.createElement('input') as web.HTMLInputElement;
        input.type = 'text';
        input.style
          ..padding = '7px 10px'
          ..borderRadius = '6px'
          ..backgroundColor = 'rgba(15,23,42,0.08)'
          ..color = 'inherit'
          ..outline = 'none'
          ..boxSizing = 'border-box';
        input.addEventListener(
          'pointerdown',
          ((web.Event event) {
            event.stopPropagation();
            widget.onElementSelected(item.id);
          }).toJS,
        );
        input.addEventListener(
          'input',
          ((web.Event _) {
            final value = input.value;
            widget.onElementInteracted(
              item.id,
              (cur) => cur.copyWith(inputValue: value),
              value.isEmpty ? 'Cleared <input>' : 'Typed "$value" in <input>',
            );
          }).toJS,
        );
        return input;

      case HtmlElementKind.card:
        final card = web.document.createElement('div') as web.HTMLDivElement;
        card.style
          ..padding = '10px 12px'
          ..borderRadius = '8px'
          ..boxSizing = 'border-box';
        final title = web.document.createElement('div') as web.HTMLDivElement;
        title.setAttribute('data-pp-role', 'title');
        title.style
          ..fontWeight = '600'
          ..marginBottom = '4px';
        final sub = web.document.createElement('div') as web.HTMLDivElement;
        sub.textContent = 'Drag to move · Double-click to edit';
        sub.style
          ..fontSize = '11px'
          ..opacity = '0.78';
        card.appendChild(title);
        card.appendChild(sub);
        return card;

      case HtmlElementKind.badge:
        final span = web.document.createElement('span') as web.HTMLSpanElement;
        span.style
          ..display = 'inline-block'
          ..padding = '4px 10px'
          ..borderRadius = '999px'
          ..color = '#ffffff'
          ..fontWeight = '700'
          ..letterSpacing = '0.05em'
          ..whiteSpace = 'nowrap';
        return span;

      case HtmlElementKind.link:
        final anchor = web.document.createElement('a') as web.HTMLAnchorElement;
        anchor.href = '#${item.id}';
        anchor.draggable = false;
        anchor.style
          ..fontWeight = '500'
          ..textDecoration = 'underline'
          ..whiteSpace = 'nowrap'
          ..cursor = 'pointer';
        anchor.addEventListener(
          'click',
          ((web.Event event) {
            event.preventDefault();
            if (_wrapperWasDragged(anchor)) return;
            event.stopPropagation();
            final latest = _latestItems[item.id] ?? item;
            widget.onElementInteracted(
              item.id,
              (cur) => cur.copyWith(clickCount: cur.clickCount + 1),
              'Activated <a> "${latest.text}"',
            );
          }).toJS,
        );
        return anchor;

      case HtmlElementKind.checkbox:
        final label =
            web.document.createElement('label') as web.HTMLLabelElement;
        label.style
          ..display = 'inline-flex'
          ..alignItems = 'center'
          ..gap = '8px'
          ..cursor = 'pointer'
          ..whiteSpace = 'nowrap';
        final box = web.document.createElement('input') as web.HTMLInputElement;
        box.type = 'checkbox';
        box.style.cursor = 'pointer';
        box.addEventListener(
          'pointerdown',
          ((web.Event event) {
            event.stopPropagation();
            widget.onElementSelected(item.id);
          }).toJS,
        );
        box.addEventListener(
          'change',
          ((web.Event _) {
            final checked = box.checked;
            widget.onElementInteracted(
              item.id,
              (cur) => cur.copyWith(checked: checked),
              'Checkbox ${checked ? 'checked' : 'unchecked'}',
            );
          }).toJS,
        );
        final text = web.document.createElement('span') as web.HTMLSpanElement;
        text.setAttribute('data-pp-role', 'label');
        label.appendChild(box);
        label.appendChild(text);
        return label;

      case HtmlElementKind.image:
        final img = web.document.createElement('img') as web.HTMLImageElement;
        img.draggable = false;
        img.style
          ..display = 'block'
          ..borderRadius = '6px';
        return img;

      case HtmlElementKind.divider:
        final hr = web.document.createElement('hr') as web.HTMLHRElement;
        hr.style
          ..border = 'none'
          ..height = '3px'
          ..borderRadius = '999px'
          ..margin = '6px 0';
        return hr;
    }
  }

  void _syncItemContent(
    web.HTMLElement content,
    PlacedHtmlElement item,
    bool isDark,
  ) {
    switch (item.kind) {
      case HtmlElementKind.heading:
        content.textContent = item.text;
        content.style
          ..fontSize = '${item.fontSize.round()}px'
          ..color = item.accentHex == '#64748b'
              ? (isDark ? '#f1f5f9' : '#0f172a')
              : item.accentHex;

      case HtmlElementKind.paragraph:
        content.textContent = item.text;
        content.style
          ..fontSize = '${item.fontSize.round()}px'
          ..maxWidth = '${math.max(120, item.width.round() - 24)}px'
          ..color = isDark ? '#cbd5e1' : '#334155';

      case HtmlElementKind.button:
        content.textContent = item.clickCount > 0
            ? '${item.text} (${item.clickCount})'
            : item.text;
        content.style
          ..fontSize = '${item.fontSize.round()}px'
          ..backgroundColor = item.accentHex;

      case HtmlElementKind.input:
        final input = content as web.HTMLInputElement;
        input.placeholder = item.text;
        if (input.value != item.inputValue) {
          input.value = item.inputValue;
        }
        input.style
          ..fontSize = '${item.fontSize.round()}px'
          ..width = '${math.max(120, item.width.round() - 24)}px'
          ..border = '1.5px solid ${item.accentHex}';

      case HtmlElementKind.card:
        content.style
          ..width = '${math.max(140, item.width.round() - 24)}px'
          ..backgroundColor = '${item.accentHex}24'
          ..border = '1px solid ${item.accentHex}88';
        final title = content.querySelector('[data-pp-role="title"]');
        if (title != null && title.isA<web.HTMLElement>()) {
          title.textContent = item.text;
          (title as web.HTMLElement).style.fontSize =
              '${item.fontSize.round()}px';
        }

      case HtmlElementKind.badge:
        content.textContent = item.text;
        content.style
          ..fontSize = '${item.fontSize.round()}px'
          ..backgroundColor = item.accentHex;

      case HtmlElementKind.link:
        content.textContent = item.clickCount > 0
            ? '${item.text} (${item.clickCount})'
            : item.text;
        content.style
          ..fontSize = '${item.fontSize.round()}px'
          ..color = item.accentHex;

      case HtmlElementKind.checkbox:
        content.style.fontSize = '${item.fontSize.round()}px';
        final box = content.querySelector('input[type="checkbox"]');
        if (box != null && box.isA<web.HTMLInputElement>()) {
          (box as web.HTMLInputElement).checked = item.checked;
          box.style.setProperty('accent-color', item.accentHex);
        }
        final textSpan = content.querySelector('[data-pp-role="label"]');
        if (textSpan != null) {
          textSpan.textContent = item.text;
        }

      case HtmlElementKind.image:
        final img = content as web.HTMLImageElement;
        final w = math.max(120, item.width.round() - 24);
        final h = math.max(68, (w * 0.48).round());
        final encodedHex = Uri.encodeComponent(item.accentHex);
        final label = Uri.encodeComponent(item.text);
        img.alt = item.text;
        img.src =
            'data:image/svg+xml;utf8,'
            '<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="$h" viewBox="0 0 $w $h">'
            '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">'
            '<stop offset="0%" stop-color="$encodedHex"/><stop offset="100%" stop-color="%2306b6d4"/>'
            '</linearGradient></defs>'
            '<rect width="$w" height="$h" rx="10" fill="url(%23g)"/>'
            '<circle cx="${(w * 0.25).round()}" cy="${(h * 0.5).round()}" r="${(h * 0.24).round()}" fill="rgba(255,255,255,0.28)"/>'
            '<polygon points="${(w * 0.45).round()},${(h * 0.78).round()} ${(w * 0.62).round()},${(h * 0.30).round()} ${(w * 0.80).round()},${(h * 0.78).round()}" fill="rgba(255,255,255,0.45)"/>'
            '<text x="12" y="18" fill="white" font-size="11" font-family="sans-serif" font-weight="bold">$label</text>'
            '</svg>';
        img.style
          ..width = '${w}px'
          ..height = '${h}px';

      case HtmlElementKind.divider:
        content.style
          ..width = '${math.max(100, item.width.round() - 24)}px'
          ..backgroundColor = item.accentHex;
    }
  }

  static bool _wrapperWasDragged(web.Element inner) {
    final parent = inner.parentElement;
    if (parent == null) return false;
    return parent.getAttribute('data-pp-just-dragged') == '1';
  }

  void _applyItemStyle({
    required web.HTMLDivElement node,
    required PlacedHtmlElement item,
    required bool selected,
    required bool isDark,
    required bool isCurrentlyDragging,
  }) {
    if (!isCurrentlyDragging) {
      node.style.left = '${item.x.toStringAsFixed(1)}px';
      node.style.top = '${item.y.toStringAsFixed(1)}px';
    }
    node.style.zIndex = '${item.zIndex}';
    node.style.color = isDark ? '#e2e8f0' : '#0f172a';
    node.style.backgroundColor = isDark
        ? 'rgba(30, 35, 48, 0.92)'
        : 'rgba(255, 255, 255, 0.95)';
    node.style.border = selected
        ? '1.5px solid ${item.accentHex}'
        : (isDark
              ? '1px solid rgba(148, 163, 184, 0.24)'
              : '1px solid rgba(15, 23, 42, 0.14)');
    node.style.boxShadow = selected
        ? '0 8px 24px ${item.accentHex}44'
        : (isDark
              ? '0 4px 14px rgba(0, 0, 0, 0.35)'
              : '0 4px 14px rgba(15, 23, 42, 0.08)');
  }

  VoidCallback _attachDragBehavior({
    required web.HTMLDivElement wrapper,
    required String id,
  }) {
    var pointerDown = false;
    var activePointerId = -1;
    var startClientX = 0.0;
    var startClientY = 0.0;
    var startLeft = 0.0;
    var startTop = 0.0;
    var currentLeft = 0.0;
    var currentTop = 0.0;
    var moved = false;

    late final JSFunction onWindowMoveJs;
    late final JSFunction onWindowUpJs;

    void detachWindowListeners() {
      web.window.removeEventListener('pointermove', onWindowMoveJs);
      web.window.removeEventListener('pointerup', onWindowUpJs);
      web.window.removeEventListener('pointercancel', onWindowUpJs);
    }

    onWindowMoveJs = ((web.Event event) {
      if (!pointerDown) return;
      final pe = event as web.PointerEvent;
      if (pe.pointerId != activePointerId) return;

      final coords = pe as _PointerCoords;
      final dx = coords.clientX.toDouble() - startClientX;
      final dy = coords.clientY.toDouble() - startClientY;
      if (!moved && (dx.abs() > 4 || dy.abs() > 4)) {
        moved = true;
        wrapper.setAttribute('data-pp-just-dragged', '1');
        wrapper.style.cursor = 'grabbing';
      }
      if (!moved) return;

      final viewId = _viewId;
      final root = viewId == null ? null : _containers[viewId];
      if (root == null) return;

      final rootRect = root.getBoundingClientRect();
      final nodeRect = wrapper.getBoundingClientRect();
      final maxLeft = math.max(8.0, rootRect.width - nodeRect.width - 8.0);
      final maxTop = math.max(8.0, rootRect.height - nodeRect.height - 8.0);

      currentLeft = (startLeft + dx).clamp(8.0, maxLeft).toDouble();
      currentTop = (startTop + dy).clamp(8.0, maxTop).toDouble();

      wrapper.style.left = '${currentLeft.toStringAsFixed(1)}px';
      wrapper.style.top = '${currentTop.toStringAsFixed(1)}px';
    }).toJS;

    onWindowUpJs = ((web.Event event) {
      if (!pointerDown) return;
      final pe = event as web.PointerEvent;
      if (pe.pointerId != activePointerId) return;

      pointerDown = false;
      _draggingId = null;
      wrapper.style.cursor = 'grab';
      detachWindowListeners();

      if (moved) {
        widget.onElementMoved(id, currentLeft, currentTop);
      }
    }).toJS;

    wrapper.addEventListener(
      'pointerdown',
      ((web.Event event) {
        final pe = event as web.PointerEvent;
        if (pe.button != 0) return;

        final viewId = _viewId;
        final root = viewId == null ? null : _containers[viewId];
        if (root == null) return;

        pe.stopPropagation();
        pointerDown = true;
        moved = false;
        activePointerId = pe.pointerId;
        final coords = pe as _PointerCoords;
        startClientX = coords.clientX.toDouble();
        startClientY = coords.clientY.toDouble();

        final rootRect = root.getBoundingClientRect();
        final nodeRect = wrapper.getBoundingClientRect();
        startLeft = nodeRect.left - rootRect.left;
        startTop = nodeRect.top - rootRect.top;
        currentLeft = startLeft;
        currentTop = startTop;

        wrapper.setAttribute('data-pp-just-dragged', '0');
        _draggingId = id;

        web.window.addEventListener('pointermove', onWindowMoveJs);
        web.window.addEventListener('pointerup', onWindowUpJs);
        web.window.addEventListener('pointercancel', onWindowUpJs);

        widget.onElementSelected(id);
      }).toJS,
    );

    return detachWindowListeners;
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: widget.disablePointerEvents,
      child: HtmlElementView(
        viewType: _viewType,
        hitTestBehavior: widget.disablePointerEvents
            ? PlatformViewHitTestBehavior.transparent
            : PlatformViewHitTestBehavior.opaque,
        onPlatformViewCreated: _onPlatformViewCreated,
      ),
    );
  }
}
