import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'html_view_elements.dart';
import 'html_view_stub.dart' if (dart.library.js_interop) 'html_view_web.dart';

class HtmlViewScreen extends StatefulWidget {
  const HtmlViewScreen({super.key});

  @override
  State<HtmlViewScreen> createState() => _HtmlViewScreenState();
}

class _HtmlViewScreenState extends State<HtmlViewScreen> {
  final GlobalKey _canvasKey = GlobalKey();
  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFocusNode = FocusNode();

  late final List<PlacedHtmlElement> _elements = <PlacedHtmlElement>[
    PlacedHtmlElement.fromTemplate(
      id: 'el_0',
      template: templateForKind(HtmlElementKind.card),
      x: 32,
      y: 32,
      zIndex: 1,
    ),
  ];

  int _nextId = 1;
  int _nextZIndex = 2;
  String? _selectedId;
  bool _paletteOpen = false;
  bool _showHtmlPreview = false;
  bool _isDraggingFromPalette = false;
  bool _isHoveringCanvas = false;
  String? _lastFeedback;

  @override
  void dispose() {
    _textController.dispose();
    _textFocusNode.dispose();
    super.dispose();
  }

  void _togglePalette() {
    setState(() {
      _paletteOpen = !_paletteOpen;
    });
  }

  void _toggleHtmlPreview() {
    setState(() {
      _showHtmlPreview = !_showHtmlPreview;
    });
  }

  void _syncInspectorText(PlacedHtmlElement? element) {
    final target = element?.text ?? '';
    if (_textController.text != target) {
      _textController.value = TextEditingValue(
        text: target,
        selection: TextSelection.collapsed(offset: target.length),
      );
    }
  }

  void _addElement(HtmlElementTemplate template, {Offset? dropLocalPosition}) {
    final canvasSize = _canvasSize();
    final maxX = math.max(8.0, canvasSize.width - template.defaultWidth - 8.0);
    final maxY = math.max(
      8.0,
      canvasSize.height - template.defaultHeight - 8.0,
    );

    final double targetX;
    final double targetY;
    if (dropLocalPosition != null) {
      targetX = (dropLocalPosition.dx - template.defaultWidth / 2)
          .clamp(8.0, maxX)
          .toDouble();
      targetY = (dropLocalPosition.dy - template.defaultHeight / 2)
          .clamp(8.0, maxY)
          .toDouble();
    } else {
      final step = (_elements.length % 6) * 28.0;
      targetX = (36.0 + step).clamp(8.0, maxX).toDouble();
      targetY = (36.0 + step).clamp(8.0, maxY).toDouble();
    }

    final id = 'el_${_nextId++}';
    final created = PlacedHtmlElement.fromTemplate(
      id: id,
      template: template,
      x: targetX,
      y: targetY,
      zIndex: _nextZIndex++,
    );
    setState(() {
      _elements.add(created);
      _selectedId = id;
      _lastFeedback = 'Added ${template.label} ${template.tag}';
    });
    _syncInspectorText(created);
  }

  Size _canvasSize() {
    final renderObject = _canvasKey.currentContext?.findRenderObject();
    if (renderObject is RenderBox && renderObject.hasSize) {
      return renderObject.size;
    }
    return const Size(720, 460);
  }

  void _moveElement(String id, double x, double y) {
    PlacedHtmlElement? updated;
    setState(() {
      final index = _elements.indexWhere((e) => e.id == id);
      if (index != -1) {
        updated = _elements[index].copyWith(x: x, y: y, zIndex: _nextZIndex++);
        _elements[index] = updated!;
      }
      _selectedId = id;
      _lastFeedback = 'Moved to (${x.round()}, ${y.round()})';
    });
    _syncInspectorText(updated);
  }

  void _selectElement(String id, {bool focusText = false}) {
    PlacedHtmlElement? selected;
    setState(() {
      _selectedId = id;
      final index = _elements.indexWhere((e) => e.id == id);
      if (index != -1) {
        selected = _elements[index].copyWith(zIndex: _nextZIndex++);
        _elements[index] = selected!;
      }
    });
    _syncInspectorText(selected);
    if (focusText) {
      _textFocusNode.requestFocus();
    }
  }

  void _updateSelected(
    PlacedHtmlElement Function(PlacedHtmlElement) transform, {
    String? feedback,
  }) {
    final id = _selectedId;
    if (id == null) return;
    setState(() {
      final index = _elements.indexWhere((e) => e.id == id);
      if (index != -1) {
        _elements[index] = transform(_elements[index]);
      }
      if (feedback != null) {
        _lastFeedback = feedback;
      }
    });
  }

  void _handleElementInteracted(
    String id,
    PlacedHtmlElement Function(PlacedHtmlElement) update,
    String feedback,
  ) {
    PlacedHtmlElement? updated;
    setState(() {
      final index = _elements.indexWhere((e) => e.id == id);
      if (index != -1) {
        updated = update(_elements[index]).copyWith(zIndex: _nextZIndex++);
        _elements[index] = updated!;
      }
      _selectedId = id;
      _lastFeedback = feedback;
    });
    _syncInspectorText(updated);
  }

  void _duplicateSelected() {
    final source = _selectedElement;
    if (source == null) return;
    final canvasSize = _canvasSize();
    final maxX = math.max(8.0, canvasSize.width - source.width - 8.0);
    final maxY = math.max(8.0, canvasSize.height - 80.0);
    final id = 'el_${_nextId++}';
    final copy = PlacedHtmlElement(
      id: id,
      kind: source.kind,
      x: (source.x + 24).clamp(8.0, maxX).toDouble(),
      y: (source.y + 24).clamp(8.0, maxY).toDouble(),
      zIndex: _nextZIndex++,
      text: source.text,
      accentHex: source.accentHex,
      fontSize: source.fontSize,
      width: source.width,
      checked: source.checked,
      clickCount: 0,
      inputValue: source.inputValue,
    );
    setState(() {
      _elements.add(copy);
      _selectedId = id;
      _lastFeedback = 'Duplicated ${templateForKind(source.kind).tag}';
    });
    _syncInspectorText(copy);
  }

  void _bringSelectedToFront() {
    _updateSelected(
      (cur) => cur.copyWith(zIndex: _nextZIndex++),
      feedback: 'Brought to front',
    );
  }

  void _removeElement(String id) {
    setState(() {
      _elements.removeWhere((e) => e.id == id);
      if (_selectedId == id) {
        _selectedId = null;
        _syncInspectorText(null);
      }
      _lastFeedback = 'Removed element';
    });
  }

  void _clearElements() {
    setState(() {
      _elements.clear();
      _selectedId = null;
      _lastFeedback = 'Cleared canvas';
    });
    _syncInspectorText(null);
  }

  PlacedHtmlElement? get _selectedElement {
    final id = _selectedId;
    if (id == null) return null;
    for (final element in _elements) {
      if (element.id == id) return element;
    }
    return null;
  }

  String _buildFullHtmlMarkup() {
    final sorted = List<PlacedHtmlElement>.from(_elements)
      ..sort((a, b) => a.zIndex.compareTo(b.zIndex));
    if (sorted.isEmpty) return '<div class="canvas"></div>';
    final buffer = StringBuffer(
      '<div class="canvas" style="position:relative;">\n',
    );
    for (final item in sorted) {
      buffer.writeln('  ${item.toHtmlSnippet()}');
    }
    buffer.write('</div>');
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final selected = _selectedElement;

    return Scaffold(
      appBar: AppBar(title: const Text('HtmlElementView')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Toolbar(
              paletteOpen: _paletteOpen,
              showHtmlPreview: _showHtmlPreview,
              elementCount: _elements.length,
              onTogglePalette: _togglePalette,
              onToggleHtmlPreview: _toggleHtmlPreview,
              onClear: _elements.isEmpty ? null : _clearElements,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 720;
                  if (wide) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_paletteOpen) ...[
                          SizedBox(
                            width: 248,
                            child: _ComponentPalette(
                              horizontal: false,
                              onTapTemplate: _addElement,
                              onDragStateChanged: _setPaletteDragging,
                              onClose: _togglePalette,
                            ),
                          ),
                          const SizedBox(width: 12),
                        ],
                        Expanded(child: _buildCanvas(theme, isDark)),
                        if (_showHtmlPreview) ...[
                          const SizedBox(width: 12),
                          SizedBox(
                            width: 280,
                            child: _HtmlMarkupPanel(
                              markup: _buildFullHtmlMarkup(),
                              onClose: _toggleHtmlPreview,
                            ),
                          ),
                        ],
                      ],
                    );
                  }

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_paletteOpen) ...[
                        SizedBox(
                          height: 124,
                          child: _ComponentPalette(
                            horizontal: true,
                            onTapTemplate: _addElement,
                            onDragStateChanged: _setPaletteDragging,
                            onClose: _togglePalette,
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      Expanded(child: _buildCanvas(theme, isDark)),
                      if (_showHtmlPreview) ...[
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 132,
                          child: _HtmlMarkupPanel(
                            markup: _buildFullHtmlMarkup(),
                            onClose: _toggleHtmlPreview,
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            _InspectorBar(
              selected: selected,
              lastFeedback: _lastFeedback,
              textController: _textController,
              textFocusNode: _textFocusNode,
              onTextChanged: (value) {
                _updateSelected((cur) => cur.copyWith(text: value));
              },
              onAccentChanged: (hex) {
                _updateSelected(
                  (cur) => cur.copyWith(accentHex: hex),
                  feedback: 'Updated accent color',
                );
              },
              onFontSizeDelta: (delta) {
                _updateSelected(
                  (cur) => cur.copyWith(
                    fontSize: (cur.fontSize + delta).clamp(10, 36).toDouble(),
                  ),
                );
              },
              onWidthDelta: (delta) {
                _updateSelected(
                  (cur) => cur.copyWith(
                    width: (cur.width + delta).clamp(110, 420).toDouble(),
                  ),
                );
              },
              onDuplicate: _duplicateSelected,
              onBringToFront: _bringSelectedToFront,
              onRemoveSelected: selected == null
                  ? null
                  : () => _removeElement(selected.id),
            ),
          ],
        ),
      ),
    );
  }

  void _setPaletteDragging(bool dragging) {
    if (_isDraggingFromPalette == dragging) return;
    setState(() {
      _isDraggingFromPalette = dragging;
      if (!dragging) {
        _isHoveringCanvas = false;
      }
    });
  }

  Widget _buildCanvas(ThemeData theme, bool isDark) {
    final borderColor = _isHoveringCanvas
        ? theme.colorScheme.primary
        : theme.colorScheme.outlineVariant;

    return DragTarget<HtmlElementTemplate>(
      onWillAcceptWithDetails: (_) {
        if (!_isHoveringCanvas) {
          setState(() => _isHoveringCanvas = true);
        }
        return true;
      },
      onLeave: (_) {
        if (_isHoveringCanvas) {
          setState(() => _isHoveringCanvas = false);
        }
      },
      onAcceptWithDetails: (details) {
        final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
        final localOffset = box?.globalToLocal(details.offset);
        setState(() {
          _isHoveringCanvas = false;
          _isDraggingFromPalette = false;
        });
        _addElement(details.data, dropLocalPosition: localOffset);
      },
      builder: (context, candidateData, rejectedData) {
        return Container(
          key: _canvasKey,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: borderColor,
              width: _isHoveringCanvas ? 2.5 : 1.2,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(13),
            child: Stack(
              fit: StackFit.expand,
              children: [
                buildHtmlView(
                  elements: _elements,
                  selectedId: _selectedId,
                  isDark: isDark,
                  disablePointerEvents: _isDraggingFromPalette,
                  onElementMoved: _moveElement,
                  onElementSelected: _selectElement,
                  onElementDoubleTapped: (id) =>
                      _selectElement(id, focusText: true),
                  onElementRemoved: _removeElement,
                  onElementInteracted: _handleElementInteracted,
                  onBackgroundTap: () {
                    if (_selectedId != null) {
                      setState(() => _selectedId = null);
                      _syncInspectorText(null);
                    }
                  },
                ),
                if (_elements.isEmpty)
                  IgnorePointer(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface.withValues(
                            alpha: 0.85,
                          ),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: theme.colorScheme.outlineVariant,
                          ),
                        ),
                        child: Text(
                          'Click Add to choose HTML components or drag & drop them here',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ),
                  ),
                if (_isHoveringCanvas)
                  IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.08,
                        ),
                      ),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Chip(
                            label: Text(
                              'Drop ${candidateData.firstOrNull?.tag ?? 'HTML'} here',
                            ),
                            avatar: const Icon(Icons.add_circle_outline),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.paletteOpen,
    required this.showHtmlPreview,
    required this.elementCount,
    required this.onTogglePalette,
    required this.onToggleHtmlPreview,
    required this.onClear,
  });

  final bool paletteOpen;
  final bool showHtmlPreview;
  final int elementCount;
  final VoidCallback onTogglePalette;
  final VoidCallback onToggleHtmlPreview;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.spaceBetween,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              key: const Key('add_html_element_button'),
              onPressed: onTogglePalette,
              icon: Icon(paletteOpen ? Icons.close : Icons.add),
              label: Text(paletteOpen ? 'Done adding' : 'Add element'),
            ),
            Text(
              paletteOpen
                  ? 'Click a component or drag & drop it onto the HTML view'
                  : 'Click Add element to insert or drag HTML components',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Chip(
              visualDensity: VisualDensity.compact,
              label: Text(
                '$elementCount ${elementCount == 1 ? 'element' : 'elements'}',
              ),
            ),
            OutlinedButton.icon(
              key: const Key('view_html_markup_button'),
              onPressed: onToggleHtmlPreview,
              icon: const Icon(Icons.code, size: 16),
              label: Text(showHtmlPreview ? 'Hide HTML' : 'View HTML'),
            ),
            if (onClear != null)
              TextButton.icon(
                key: const Key('clear_html_elements_button'),
                onPressed: onClear,
                icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                label: const Text('Clear'),
              ),
          ],
        ),
      ],
    );
  }
}

class _ComponentPalette extends StatelessWidget {
  const _ComponentPalette({
    required this.horizontal,
    required this.onTapTemplate,
    required this.onDragStateChanged,
    required this.onClose,
  });

  final bool horizontal;
  final void Function(HtmlElementTemplate template) onTapTemplate;
  final void Function(bool dragging) onDragStateChanged;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      key: const Key('html_components_palette'),
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'HTML Components',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: 'Close palette',
                  visualDensity: VisualDensity.compact,
                  onPressed: onClose,
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
          if (!horizontal)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                'Click to add or drag & drop onto canvas',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          Expanded(
            child: ListView.separated(
              scrollDirection: horizontal ? Axis.horizontal : Axis.vertical,
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              itemCount: htmlElementTemplates.length,
              separatorBuilder: (context, index) => horizontal
                  ? const SizedBox(width: 8)
                  : const SizedBox(height: 6),
              itemBuilder: (context, index) {
                final template = htmlElementTemplates[index];
                return _PaletteItemTile(
                  template: template,
                  compact: horizontal,
                  onTap: () => onTapTemplate(template),
                  onDragStateChanged: onDragStateChanged,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PaletteItemTile extends StatelessWidget {
  const _PaletteItemTile({
    required this.template,
    required this.compact,
    required this.onTap,
    required this.onDragStateChanged,
  });

  final HtmlElementTemplate template;
  final bool compact;
  final VoidCallback onTap;
  final void Function(bool dragging) onDragStateChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tileContent = Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        key: Key('palette_item_${template.kind.name}'),
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 10,
            vertical: compact ? 6 : 8,
          ),
          child: Row(
            mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
            children: [
              Icon(template.icon, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              if (compact)
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(template.label, style: theme.textTheme.labelLarge),
                    Text(
                      template.tag,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontFamily: 'monospace',
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                )
              else
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              template.label,
                              style: theme.textTheme.labelLarge,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              template.tag,
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontFamily: 'monospace',
                                color: theme.colorScheme.primary,
                              ),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                        ],
                      ),
                      Text(
                        template.description,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              if (!compact) ...[
                const SizedBox(width: 4),
                Icon(
                  Icons.drag_indicator,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ],
          ),
        ),
      ),
    );

    return Draggable<HtmlElementTemplate>(
      data: template,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      onDragStarted: () => onDragStateChanged(true),
      onDragEnd: (_) => onDragStateChanged(false),
      onDraggableCanceled: (_, _) => onDragStateChanged(false),
      onDragCompleted: () => onDragStateChanged(false),
      feedback: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(10),
        color: theme.colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                template.icon,
                size: 18,
                color: theme.colorScheme.onPrimaryContainer,
              ),
              const SizedBox(width: 8),
              Text(
                '${template.label} ${template.tag}',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.45, child: tileContent),
      child: tileContent,
    );
  }
}

class _InspectorBar extends StatelessWidget {
  const _InspectorBar({
    required this.selected,
    required this.lastFeedback,
    required this.textController,
    required this.textFocusNode,
    required this.onTextChanged,
    required this.onAccentChanged,
    required this.onFontSizeDelta,
    required this.onWidthDelta,
    required this.onDuplicate,
    required this.onBringToFront,
    required this.onRemoveSelected,
  });

  final PlacedHtmlElement? selected;
  final String? lastFeedback;
  final TextEditingController textController;
  final FocusNode textFocusNode;
  final ValueChanged<String> onTextChanged;
  final ValueChanged<String> onAccentChanged;
  final ValueChanged<double> onFontSizeDelta;
  final ValueChanged<double> onWidthDelta;
  final VoidCallback onDuplicate;
  final VoidCallback onBringToFront;
  final VoidCallback? onRemoveSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = selected;
    if (item == null) {
      return Text(
        lastFeedback != null
            ? '$lastFeedback · Click any element in the HTML view to inspect or edit it.'
            : 'Tip: Drag any element inside the view to move it, click to edit properties, or double-click to edit text.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    final template = templateForKind(item.kind);
    return Card(
      key: const Key('html_element_inspector'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Chip(
              visualDensity: VisualDensity.compact,
              label: Text(
                '${template.label} ${template.tag} · (${item.x.round()}, ${item.y.round()})',
              ),
            ),
            if (item.kind != HtmlElementKind.divider)
              SizedBox(
                width: 210,
                child: TextField(
                  key: const Key('inspector_text_field'),
                  controller: textController,
                  focusNode: textFocusNode,
                  onChanged: onTextChanged,
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    border: const OutlineInputBorder(),
                    labelText: item.kind == HtmlElementKind.input
                        ? 'Placeholder'
                        : 'Text',
                  ),
                ),
              ),
            Wrap(
              spacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final swatch in htmlAccentSwatches)
                  Tooltip(
                    message: swatch.name,
                    child: InkWell(
                      key: Key('accent_swatch_${swatch.name.toLowerCase()}'),
                      customBorder: const CircleBorder(),
                      onTap: () => onAccentChanged(swatch.hex),
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: swatch.color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: item.accentHex == swatch.hex
                                ? theme.colorScheme.onSurface
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: const Key('inspector_size_dec'),
                  tooltip: 'Decrease font size',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onFontSizeDelta(-2),
                  icon: const Icon(Icons.text_decrease, size: 18),
                ),
                Text(
                  '${item.fontSize.round()}px',
                  style: theme.textTheme.labelMedium,
                ),
                IconButton(
                  key: const Key('inspector_size_inc'),
                  tooltip: 'Increase font size',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onFontSizeDelta(2),
                  icon: const Icon(Icons.text_increase, size: 18),
                ),
                const SizedBox(width: 4),
                IconButton(
                  key: const Key('inspector_width_dec'),
                  tooltip: 'Narrower',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onWidthDelta(-20),
                  icon: const Icon(Icons.unfold_less, size: 18),
                ),
                Text(
                  '${item.width.round()}w',
                  style: theme.textTheme.labelMedium,
                ),
                IconButton(
                  key: const Key('inspector_width_inc'),
                  tooltip: 'Wider',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onWidthDelta(20),
                  icon: const Icon(Icons.unfold_more, size: 18),
                ),
              ],
            ),
            Wrap(
              spacing: 4,
              children: [
                IconButton(
                  key: const Key('duplicate_html_element_button'),
                  tooltip: 'Duplicate',
                  visualDensity: VisualDensity.compact,
                  onPressed: onDuplicate,
                  icon: const Icon(Icons.copy, size: 18),
                ),
                IconButton(
                  key: const Key('front_html_element_button'),
                  tooltip: 'Bring to front',
                  visualDensity: VisualDensity.compact,
                  onPressed: onBringToFront,
                  icon: const Icon(Icons.flip_to_front, size: 18),
                ),
                TextButton.icon(
                  key: const Key('remove_selected_html_element_button'),
                  onPressed: onRemoveSelected,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Remove'),
                ),
              ],
            ),
            if (lastFeedback != null)
              Text(
                lastFeedback!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HtmlMarkupPanel extends StatelessWidget {
  const _HtmlMarkupPanel({required this.markup, required this.onClose});

  final String markup;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('html_markup_panel'),
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text('HTML Markup', style: theme.textTheme.titleSmall),
                ),
                IconButton(
                  tooltip: 'Copy HTML',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: markup));
                  },
                  icon: const Icon(Icons.copy_all, size: 18),
                ),
                IconButton(
                  tooltip: 'Close HTML view',
                  visualDensity: VisualDensity.compact,
                  onPressed: onClose,
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: SelectableText(
                markup,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  fontSize: 11.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
