import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'html_view_elements.dart';

/// Non-web fallback: previews placed HTML elements in an interactive Flutter
/// canvas so tests and desktop/mobile builds can exercise add, drag-and-drop,
/// selection, and live editing.
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
  return _StubHtmlViewCanvas(
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

class _StubHtmlViewCanvas extends StatelessWidget {
  const _StubHtmlViewCanvas({
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
  Widget build(BuildContext context) {
    final sorted = List<PlacedHtmlElement>.from(elements)
      ..sort((a, b) => a.zIndex.compareTo(b.zIndex));

    return IgnorePointer(
      ignoring: disablePointerEvents,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onBackgroundTap,
            child: ColoredBox(
              color: isDark ? const Color(0xFF141720) : const Color(0xFFF8FAFC),
              child: Stack(
                children: [
                  Positioned(
                    right: 10,
                    bottom: 8,
                    child: IgnorePointer(
                      child: Text(
                        'HtmlElementView preview (web renders real DOM)',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: isDark ? Colors.white38 : Colors.black38,
                        ),
                      ),
                    ),
                  ),
                  for (final item in sorted)
                    _StubPlacedItem(
                      key: ValueKey<String>('stub_item_${item.id}'),
                      item: item,
                      selected: item.id == selectedId,
                      isDark: isDark,
                      maxWidth: constraints.maxWidth,
                      maxHeight: constraints.maxHeight,
                      onMoved: (x, y) => onElementMoved(item.id, x, y),
                      onSelected: () => onElementSelected(item.id),
                      onDoubleTapped: () => onElementDoubleTapped(item.id),
                      onRemoved: () => onElementRemoved(item.id),
                      onInteracted: (update, feedback) =>
                          onElementInteracted(item.id, update, feedback),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _StubPlacedItem extends StatefulWidget {
  const _StubPlacedItem({
    super.key,
    required this.item,
    required this.selected,
    required this.isDark,
    required this.maxWidth,
    required this.maxHeight,
    required this.onMoved,
    required this.onSelected,
    required this.onDoubleTapped,
    required this.onRemoved,
    required this.onInteracted,
  });

  final PlacedHtmlElement item;
  final bool selected;
  final bool isDark;
  final double maxWidth;
  final double maxHeight;
  final void Function(double x, double y) onMoved;
  final VoidCallback onSelected;
  final VoidCallback onDoubleTapped;
  final VoidCallback onRemoved;
  final void Function(
    PlacedHtmlElement Function(PlacedHtmlElement) update,
    String feedback,
  )
  onInteracted;

  @override
  State<_StubPlacedItem> createState() => _StubPlacedItemState();
}

class _StubPlacedItemState extends State<_StubPlacedItem> {
  double? _dragX;
  double? _dragY;

  @override
  void didUpdateWidget(covariant _StubPlacedItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.x != widget.item.x || oldWidget.item.y != widget.item.y) {
      _dragX = null;
      _dragY = null;
    }
  }

  Color _accentColor() {
    final hex = widget.item.accentHex.replaceFirst('#', '');
    final value = int.tryParse(hex, radix: 16);
    if (value == null) return const Color(0xFF6366F1);
    return Color(0xFF000000 | value);
  }

  @override
  Widget build(BuildContext context) {
    final template = templateForKind(widget.item.kind);
    final left = _dragX ?? widget.item.x;
    final top = _dragY ?? widget.item.y;
    final accent = _accentColor();

    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        onTap: widget.onSelected,
        onDoubleTap: widget.onDoubleTapped,
        onPanStart: (_) {
          widget.onSelected();
          setState(() {
            _dragX = widget.item.x;
            _dragY = widget.item.y;
          });
        },
        onPanUpdate: (details) {
          final maxX = math.max(8.0, widget.maxWidth - widget.item.width - 8.0);
          final maxY = math.max(
            8.0,
            widget.maxHeight - template.defaultHeight - 8.0,
          );
          setState(() {
            _dragX = ((_dragX ?? widget.item.x) + details.delta.dx)
                .clamp(8.0, maxX)
                .toDouble();
            _dragY = ((_dragY ?? widget.item.y) + details.delta.dy)
                .clamp(8.0, maxY)
                .toDouble();
          });
        },
        onPanEnd: (_) {
          final finalX = _dragX;
          final finalY = _dragY;
          if (finalX != null && finalY != null) {
            widget.onMoved(finalX, finalY);
          }
        },
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 6, 8, 8),
          decoration: BoxDecoration(
            color: widget.isDark
                ? const Color(0xEB1E2330)
                : const Color(0xF2FFFFFF),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: widget.selected
                  ? accent
                  : (widget.isDark
                        ? Colors.white.withValues(alpha: 0.2)
                        : Colors.black.withValues(alpha: 0.14)),
              width: widget.selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    template.tag,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: widget.onRemoved,
                    child: const Icon(Icons.close, size: 14),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              _buildBody(accent),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(Color accent) {
    final item = widget.item;
    switch (item.kind) {
      case HtmlElementKind.button:
        return FilledButton(
          style: FilledButton.styleFrom(backgroundColor: accent),
          onPressed: () {
            final next = item.clickCount + 1;
            widget.onInteracted(
              (cur) => cur.copyWith(clickCount: cur.clickCount + 1),
              'Clicked <button> "${item.text}" ($next)',
            );
          },
          child: Text(
            item.clickCount > 0 ? '${item.text} (${item.clickCount})' : item.text,
            style: TextStyle(fontSize: item.fontSize),
          ),
        );
      case HtmlElementKind.checkbox:
        return InkWell(
          onTap: () {
            final next = !item.checked;
            widget.onInteracted(
              (cur) => cur.copyWith(checked: next),
              'Checkbox ${next ? 'checked' : 'unchecked'}',
            );
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                item.checked ? Icons.check_box : Icons.check_box_outline_blank,
                color: accent,
                size: 18,
              ),
              const SizedBox(width: 6),
              Text(item.text, style: TextStyle(fontSize: item.fontSize)),
            ],
          ),
        );
      case HtmlElementKind.badge:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: accent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            item.text,
            style: TextStyle(
              color: Colors.white,
              fontSize: item.fontSize,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
      case HtmlElementKind.divider:
        return Container(
          width: math.max(80, item.width - 24),
          height: 3,
          color: accent,
        );
      case HtmlElementKind.heading:
      case HtmlElementKind.paragraph:
      case HtmlElementKind.input:
      case HtmlElementKind.card:
      case HtmlElementKind.link:
      case HtmlElementKind.image:
        return Text(
          item.text,
          style: TextStyle(
            fontSize: item.fontSize,
            color: item.kind == HtmlElementKind.link ? accent : null,
            decoration: item.kind == HtmlElementKind.link
                ? TextDecoration.underline
                : null,
          ),
        );
    }
  }
}
