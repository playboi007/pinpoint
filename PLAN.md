# Widget Comment Overlay for Flutter: Implementation Plan

Nov 10, 2026 · @Erick

## Goal and scope

Pinpoint (working name) is a debug-only Flutter package that lets you click any widget in a running app, write a comment, and hand a coding agent the widget's source location, layout context and a screenshot. Web is the first target; only the transport notes are web-specific.

**In scope for v1**

- Core loop (Milestones 1 to 7): inspect mode, pick, info panel with rulers, source refinement, comment, payload, screenshot, file inbox
- Agent loop (Milestone 8): persistent pins, drafts, a two-way bridge with MCP tools, resolve round-trip
- What-if switches (Milestone 9): text scale, bold text, safe areas, fake keyboard, viewport sizes, RTL, dark mode, color scheme, platform, slow motion
- Automatic detection (Milestone 10): overflow, truncated text, oversized images, rebuild heat, accessibility audit, debug paint toggles
- Live tweak (Milestone 11): edit padding, constraints, flex, alignment, text style and decoration on the selected widget, and send the diff
- Agent drive and verify (Milestone 12): synthetic input, reverse lookup, assertions on notes, stress matrix, state dump, service-extension transport

**Out of scope for v1**

- Release-build support beyond a degraded fallback
- True record and replay; the flight-recorder idea is parked
- Inserting or removing widgets live; tweak edits existing properties only
- Writing code from inside the app; the agent edits source

**What works in which build mode**

| Capability | Debug | Profile | Release |
| --- | --- | --- | --- |
| Pick widget by position | Yes | Yes | Yes |
| Source file, line, column | Yes | No | No |
| Readable widget type names on web | Yes | Yes | No (minified) |
| Screenshot | Yes | Yes | Yes |

Source location comes from `--track-widget-creation`, which is on only in debug. Treat the tool as debug-first and default `enabled` to `kDebugMode`.

## Architecture

Everything up to the sinks runs inside the app in the browser; the receiver is a separate Dart process that turns each send into files in the project folder.

&#91;embedded content: data flow · 6 parts in the app, 3 on the dev machine\]

Read it as a snake: top row left to right, middle row right to left, then down to the receiver. The clipboard sink skips the receiver; you paste the Markdown to the agent yourself.

Two boundaries keep the design stable:

- The picker and the screenshot only see the subtree under the app's `RepaintBoundary`. Pinpoint's own UI sits beside it, so it is never picked or captured.
- Every call into Flutter's inspector internals lives in `source_location.dart`. A framework upgrade can break one file, not the package.

From Milestone 8 the receiver becomes a two-way bridge that also serves MCP tools, so resolutions flow back to the pins in the app.

**Core loop inside the app (first slice to build)**

```text
Tap / hover
   |
   v
PinPointWrapper                      owns PinPointController: mode, hovered, selected
   |
   +-- RenderSearch.find(offset)     bounds walk -> candidates, smallest area first
   |      +-- WidgetInfo.fromRenderObject()   geometry, constraints, typed properties
   |      +-- SourceResolver.chain()          nearest local widget, file:line
   |
   +-- InspectorOverlay
          +-- Positioned + IgnorePointer      highlight border and label
          +-- Positioned.fill + CustomPaint   dashed rulers to parent edges and siblings
          +-- Positioned + GestureDetector    draggable InfoPanel: info, tweak, comment
```

This is the proposed PinPoint structure with two changes:

- `RenderSearch` walks render-tree bounds instead of relying on `BoxHitTestResult` alone. Hit testing cannot see padding, `SizedBox` or `IgnorePointer` children. The hit-test path is still computed and breaks ties: an equal-area candidate on the hit path wins.
- `WidgetInfo` keeps the geometry fields and label getters as sketched. The per-type nullable fields (text, decoration) become typed properties grouped in sections. Milestone 11 needs every property to carry its own setter, and each new render type would otherwise add more nullable fields.

```dart
class WidgetInfo {
  final String renderType;          // "RenderParagraph"
  final Size size;                  // logical px
  final Offset globalPosition;
  final Constraints constraints;    // BoxConstraints or SliverConstraints
  final int depth;                  // depth in render tree
  final SourceLocation? source;     // nearest local widget; null outside debug
  final List<InfoSection> sections; // Text, Decoration, Padding, Flex, ...

  String get sizeLabel;        // "320.0 x 48.0"
  String get positionLabel;    // "(12.0, 80.5)"
  String get constraintsLabel; // "tight 320 x 48"
  Rect get globalRect;
}

class InfoProperty<T> {
  final String name;             // "fontSize"
  final T value;
  final String label;            // "16.0", "#FF3B30", "w700 (Bold)"
  final void Function(T)? apply; // null = read-only; set = editable in Milestone 11
}
```

`WidgetInfo` is a live snapshot: `apply` closes over the render object, so it is never serialized. `toJson` emits names and labels only.

**Names to use in code.** Earlier-written milestones use working names; the right-hand column is final.

| Name in milestone text | Name in code |
| --- | --- |
| `PinpointOverlay` | `PinPointWrapper` |
| `WidgetPicker.candidatesAt` | `RenderSearch.find` |
| `_PinpointLayer` | `InspectorOverlay` |
| `CommentPanel` | Comment tab of `InfoPanel` |
| `source_location.dart`, `ancestor_chain.dart` | `source_resolver.dart` |
| receiver | bridge (`bin/bridge.dart`) |

## Package layout and public API

Build it as a standalone package with an `example/` app, so the overlay never depends on any one project's theme or state management. Dependencies stay minimal: `flutter`, `http`, and `dart:io` for the receiver only.

```text
pinpoint/
  lib/
    pinpoint.dart                    # public exports only
    src/
      core/
        pinpoint_wrapper.dart        # PinPointWrapper: host, stable tree
        pinpoint_controller.dart     # mode state machine, hovered, selected
        hook_registry.dart           # install, chain and restore global hooks
        keymap.dart
      search/
        render_search.dart           # RenderSearch.find: bounds walk
        element_lookup.dart          # RenderObject -> Element
        source_resolver.dart         # creationLocation, isLocal, ancestor chain
        source_index.dart            # file:line -> live elements (reverse lookup)
      info/
        widget_info.dart             # WidgetInfo, InfoSection, InfoProperty
        extractors/                  # one file per render type
      overlay/
        inspector_overlay.dart       # highlight, rulers, panels
        highlight_painter.dart
        ruler_painter.dart
        info_panel.dart              # draggable: info, tweak, comment tabs
        comment_form.dart
        pin_marker.dart
        toolbar.dart
      capture/
        context_collector.dart       # WidgetInfo + chain + page -> Annotation
        subtree_outline.dart
        screenshot.dart
      env/
        environment_controller.dart
        environment_host.dart        # MediaQuery, viewport, Theme, Directionality
        device_presets.dart
      detect/
        detector.dart                # Finding, Detector interface, scan runner
        overflow_detector.dart
        truncation_detector.dart
        image_detector.dart
        rebuild_tracker.dart
        a11y_audit.dart
        debug_paint.dart
      tweak/
        tweak_session.dart           # apply, reapply after rebuild, reset, diff
      agent/
        command_channel.dart         # long-poll and service-extension transports
        commands.dart                # find, inspect, tap, scroll, type, navigate
        synthetic_input.dart
        checks.dart                  # assertions on notes
        stress_matrix.dart
        state_dump.dart
      model/
        annotation.dart
      sink/
        pinpoint_sink.dart
        clipboard_sink.dart
        http_sink.dart
        markdown_formatter.dart
  bin/
    bridge.dart                      # receiver (M7) growing into the MCP bridge (M8)
    setup.dart                       # writes agent config and instructions
  example/
  test/
```

**Public surface (everything else stays in `src/`)**

| Symbol | Purpose |
| --- | --- |
| `PinPointWrapper({child, config})` | Wrap in `MaterialApp.builder` |
| `PinPointConfig` | `enabled`, `sinks`, `bridgeUrl`, `shortcut`, `projectRoot`, `localPathHints`, `themeVariants`, `stateAdapters`, `allowAgentControl` |
| `PinPointController` | Optional external control: `startPicking()`, `stop()`, `mode`, `environment` |
| `WidgetInfo`, `InfoProperty` | Read model for a picked widget; usable on its own |
| `PinpointSink`, `ClipboardSink`, `HttpSink` | Where notes go |
| `Annotation` | The payload model, `toJson()` and `toMarkdown()` |
| `StateAdapter` | Optional hook so Bloc, Riverpod or Provider state shows up in state dumps |

Integration in a host app is one line plus a define for the project root:

```dart
MaterialApp(
  builder: (context, child) => PinpointOverlay(
    config: PinpointConfig(
      sinks: [HttpSink(Uri.parse('http://localhost:4747/annotations')), ClipboardSink()],
      projectRoot: const String.fromEnvironment('PINPOINT_ROOT'),
    ),
    child: child!,
  ),
)
```

```bash
flutter run -d chrome --dart-define=PINPOINT_ROOT=$(pwd)
```

Plain Dart classes with manual `toJson` are enough for the model. Skip code generation so the package builds with no `build_runner` step.

## Engineering rules for every milestone

These ten rules prevent the bugs that are hardest to find later. Put them in the agent's instruction file and check them in review.

1. **Global hooks go through `HookRegistry`.** `FlutterError.onError`, `PlatformDispatcher.onError`, `debugOnRebuildDirtyWidget`, `debugOnPaintImage`, `HardwareKeyboard` handlers, `debugDefaultTargetPlatformOverride`, `timeDilation` and the debug paint flags are single global slots. Save the previous value, chain to it, restore it on dispose. One test installs everything, disposes, and asserts every slot is back.
2. **Never force frames when idle.** No `Ticker` or repeating timer that calls `setState` while nothing changes. Do per-frame work in a post-frame callback that a persistent frame callback re-arms, so it runs only when the app draws anyway. A change made during the persistent phase itself does not schedule a new frame, so a highlight updated there can stay one frame stale forever. A tool that keeps the app at 60 fps hides real jank and breaks "wait until idle" in Milestone 12.
3. **Never subscribe app elements.** Calling `Theme.of(element)` or `MediaQuery.of(element)` on a picked element makes it depend on that inherited widget and changes its rebuild behavior. Use `getInheritedWidgetOfExactType` and `findAncestorWidgetOfExactType`.
4. **Every tree walk is bounded and guarded.** Cap nodes and depth, wrap each node's read in `try/catch`, and log the elapsed time in debug. A single custom render object that throws must not kill a pick or a scan.
5. **The app subtree stays structurally constant.** Wrappers Pinpoint adds around the app (`TickerMode`, `EnvironmentHost`, `RepaintBoundary`) are always present and only change their parameters. Adding or removing a wrapper remounts the whole app and loses its state.
6. **Pinpoint UI lives outside the app's `RepaintBoundary`.** That is what keeps it out of picks, screenshots, scans and synthetic taps.
7. **One coordinate space.** All rects are global logical pixels. Convert only at the edges: screenshot cropping and the viewport frame.
8. **Inspector internals are isolated.** Only `source_resolver.dart` and `source_index.dart` touch `WidgetInspectorService`. One test asserts a known file and line, so a Flutter upgrade fails loudly in one place.
9. **Nothing sensitive leaves unmasked.** Truncate every string that leaves the app, and mask text from fields with `obscureText`.
10. **Debug only, provably.** Everything sits behind `enabled`, defaulting to `kDebugMode`. A release build check confirms no Pinpoint code runs. No dependency beyond `http` is added without a recorded decision.

## Milestone 1: Overlay host and inspect mode

Outcome: the app runs unchanged inside `PinpointOverlay`, and a shortcut toggles a mode in which pointer events stop reaching the app.

1. Create `PinpointOverlay` as a `StatefulWidget`. If `config.enabled` is false, return `child` untouched so release builds carry nothing.
2. Build a tree whose shape never changes between modes, so the app never loses state:

   ```dart
   Stack(
     fit: StackFit.expand, // keep tight constraints for the Navigator
     children: [
       RepaintBoundary(key: _appKey, child: widget.child),
       _PinpointLayer(controller: _controller, appKey: _appKey),
     ],
   )
   ```
3. Give `_PinpointLayer` its own environment: a fixed `Theme`, then an `Overlay` with one `OverlayEntry`, then `Material(type: MaterialType.transparency)`. `MaterialApp.builder` sits above the Navigator, so there is no `Overlay` ancestor, and the comment `TextField` needs one. The fixed theme keeps the tool readable whatever the app's theme is.
4. Implement `PinpointController extends ChangeNotifier` with `enum PinpointMode { idle, picking, commenting, sending }`. Allowed transitions: idle to picking, picking to commenting on select, commenting to sending on submit, any state back one step on Esc, sending to idle on success.
5. Register the global shortcut with `HardwareKeyboard.instance.addHandler`, returning `true` when handled. Default to Alt+Shift+C and make it configurable. Avoid Ctrl/Cmd+Shift+C, which Chrome uses for its own element inspector. Remove the handler in `dispose`.
6. In picking mode, cover the screen with a pointer trap:

   ```dart
   Listener(
     behavior: HitTestBehavior.opaque,
     onPointerHover: (e) => controller.hover(e.position),
     onPointerDown: (e) => controller.select(e.position),
     child: const MouseRegion(
       cursor: SystemMouseCursors.precise,
       child: SizedBox.expand(),
     ),
   )
   ```
7. Add a small draggable launcher button, bottom-right by default, hidden when `config.showLauncher` is false.
8. Override `reassemble()` on the overlay state and clear any selection there. Held `Element` references can go stale across hot reload.

Two additions adopted from Flutter Agentation:

- **Scroll passthrough.** Wheel events over the pointer trap are forwarded to the scrollable under the cursor. It needs the picker, so it is built at the end of Milestone 2.
- **Animation freeze.** Wrap the app in `TickerMode(enabled: !controller.frozen, child: app)`, always present in the tree, toggled with P. It pauses tickers so loaders and transitions can be inspected. It does not pause `Timer` or `Future` based logic.

**Acceptance**

- [ ] A counter in the example app keeps its value across toggling
- [ ] In picking mode, tapping an app button does not fire its `onPressed`
- [ ] The shortcut works while an app `TextField` has focus, and Esc returns to idle
- [ ] With `enabled: false`, `find.byType(PinpointOverlay)` has no Pinpoint descendants
- [ ] Dialogs and pushed routes render beneath the Pinpoint layer

**How I would build it**

1. Controller and state machine first, as plain Dart with unit tests and no widgets.
2. Host widget with the stable `Stack`, then prove state survival with the counter test before adding anything else.
3. Pointer trap, then keyboard through `HookRegistry`, then the launcher, then freeze.
4. Commit after each of the three. Each is independently testable.

**How to verify**

- `flutter analyze && flutter test test/core` passes.
- In Chrome: type into an app text field, press the shortcut, confirm the caret stops receiving keys, press Esc, confirm typing resumes in the same field.
- Open a dialog and a bottom sheet in the example, enter picking, and confirm neither can be dismissed by clicking.
- Toggle freeze on a `CircularProgressIndicator`: it stops; toggle again: it resumes without a jump in app state.

**Watch out for**

- `builder`'s `child` is null when the app has no `home` or routes. Handle it instead of using `child!`.
- A keyboard handler that returns `true` swallows the key for the whole app. Return `true` only for the shortcut itself and for Esc while a Pinpoint mode is active.
- Some key combinations never reach Flutter on web because the browser or OS takes them. Keep the shortcut configurable and always offer the launcher button.
- `StackFit.expand` matters. With the default loose fit the Navigator still fills the screen, but anything that reads its incoming constraints sees different values than without Pinpoint.
- The trap must sit above dialogs. Because the wrapper is in `builder`, it does; if anyone moves it under the Navigator, dialogs escape it.
- On touch devices there is no hover. Selection must work from a tap alone.

## Milestone 2: Widget picking and highlight

Outcome: hovering outlines the widget under the cursor, and clicking selects it and yields its `Element`.

Use a bounds walk of the render tree, the same approach as Flutter's own widget inspector, instead of real hit testing. Real hit testing misses anything that does not take pointer events: padding, `SizedBox`, `IgnorePointer` children, decorative boxes. Those are exactly the things people want to comment on.

1. Write `WidgetPicker.candidatesAt(Offset global)`. Start from the app `RepaintBoundary`'s render object and visit every descendant:

   ```dart
   void visit(RenderObject ro, Rect clip, int depth) {
     if (!ro.attached) return;
     final toGlobal = ro.getTransformTo(null);
     final rect = MatrixUtils.transformRect(toGlobal, ro.paintBounds);
     if (!rect.isEmpty && rect.contains(global)) {
       hits.add(_Hit(ro, rect, depth));
     }
     for (final node in ro.debugDescribeChildren()) {
       if (node.style == DiagnosticsTreeStyle.offstage) continue;
       final child = node.value;
       if (child is! RenderObject) continue;
       var childClip = clip;
       final c = ro.describeApproximatePaintClip(child);
       if (c != null) {
         childClip = clip.intersect(MatrixUtils.transformRect(toGlobal, c));
       }
       if (childClip.contains(global)) visit(child, childClip, depth + 1);
     }
   }
   ```
2. Do not prune on the parent's own bounds. Children can overflow or be translated outside their parent. Prune only on the accumulated clip.
3. Skip offstage children. Routes beneath an opaque route stay in the tree with stale geometry and would otherwise be picked.
4. Sort hits by area ascending, then by depth descending. `List.sort` is not stable, so encode both keys in the comparator.
5. Wrap each node's geometry read in `try/catch`. A render object that has not been laid out yet throws on `paintBounds`.
6. Map `RenderObject` to `Element` in `element_lookup.dart`:

   ```dart
   Element? elementFor(RenderObject ro) {
     final creator = ro.debugCreator;
     if (creator is DebugCreator) return creator.element; // debug
     return _indexByWalkingElements()[ro];                // other modes
   }
   ```

   The fallback walks from the app element with `visitChildren` and fills an identity map from each `RenderObjectElement.renderObject` to its element.
7. Return a `PickResult` holding `element`, `renderObject`, `globalRect`, the full `candidates` list and the current `index`. Clicking the same spot again advances `index`, which covers the rare case where an opaque sibling hides the smallest candidate.
8. Coalesce hover picks to one per frame: store the latest pointer position and compute in a scheduled frame callback.
9. Draw the highlight with a `CustomPainter` driven by a `ValueNotifier<PickResult?>` passed as `repaint`, inside `IgnorePointer`. Paint a translucent fill, a 1.5 px border, and a label pill with the widget name and size, placed above the rect or below when there is no room.
10. While a selection exists, recompute its rect after each frame the app draws (engineering rule 2), instead of a `Ticker`. Clear the selection when `element.mounted` is false.

**Acceptance**

- [ ] Hovering a `Text` outlines exactly the text bounds
- [ ] A bare `SizedBox` and the padding area of a `Padding` can both be selected
- [ ] With an opaque route pushed, nothing on the route beneath is ever picked
- [ ] A list item scrolled under the app bar is not picked when clicking the app bar
- [ ] The outline follows the widget on window resize and clears when the widget unmounts
- [ ] One pick on a 500-item list screen takes under 8 ms in debug; if not, accumulate transforms top-down instead of calling `getTransformTo` per node

**Additions from the PinPoint structure**

1. `WidgetInfo.fromRenderObject(ro)` fills geometry, then runs a registry of extractors, one per render type. Start with two: `RenderParagraph` (text content, font size, weight label such as "w700 (Bold)", color as hex) and `RenderDecoratedBox` with a `BoxDecoration` (background color, border radius, border). Read text style from the first `TextSpan` that carries a style; the root span's style can be null.
2. `RulerPainter` draws dashed lines from the selected rect's four edges to the nearest local ancestor's rect, each labelled with its distance. With Alt held and a second widget hovered, it shows the gaps between the two rects instead. Canvas has no dashed stroke, so draw short segments in a loop.
3. `InfoPanel` is a draggable card (`GestureDetector.onPanUpdate`, clamped to the viewport) showing the `WidgetInfo` labels and sections. It has three tabs: Info now, Comment in Milestone 5, Tweak in Milestone 11. Its position lives in the controller so it survives reselection.
4. Scroll passthrough: on a `PointerScrollEvent` over the trap, find the render object under the cursor, walk up to the nearest `ScrollableState` whose axis matches the larger delta, and call `position.pointerScroll(delta)`.

**How I would build it**

1. Geometry helpers and the walk against fixture trees in widget tests, with no UI.
2. Element lookup, then the highlight painter, then hover coalescing.
3. `WidgetInfo` with the two extractors, then the info panel, then rulers.
4. Scroll passthrough last.

**How to verify**

- Turn on `debugPaintSizeEnabled` in the example and compare: Pinpoint's outline must sit exactly on Flutter's own size paint for the same widget.
- Log pick time over 200 hover picks on the long-list screen and report p50 and p95.
- Fixture cases to cover: rotated and scaled subtrees, a `Stack` with overlapping children, a child that overflows its parent, an `Offstage` subtree, an `IndexedStack`, a nested scroll view, a sliver list.
- Ruler labels must add up: left gap plus width plus right gap equals the ancestor's width.

**Watch out for**

- Many wrappers share one rect (`Padding` inside `Align` inside `SizedBox`). Area ties are the norm, so the depth tie-break decides most picks.
- Later siblings paint on top. On an area and depth tie, prefer the later one in traversal order.
- `debugDescribeChildren()` allocates diagnostics nodes for every child. If the walk is over budget, this is the first thing to replace, but any replacement must still skip offstage children.
- Rotated widgets produce an axis-aligned bounding rect. The outline is then larger than the widget; accept that in v1.
- A singular transform (scale 0, mid-animation) throws in `transformRect`. The per-node `try/catch` handles it.
- Clear the hover highlight when the pointer leaves the window, or a stale outline stays on screen.
- Slivers have no `RenderBox` size. `WidgetInfo` takes `Constraints`, not `BoxConstraints`, for this reason.

## Milestone 3: Selection refinement to local-project widgets

Outcome: the default selection is the nearest widget written in the project's own source, and arrow keys move up and down the chain.

The picked render object almost always belongs to a framework-internal widget such as `RichText` or `DecoratedBox`. A widget's creation location is where its constructor call appears in source. A `Text('Save')` written in your file points at your file; the `RichText` it builds points into the Flutter SDK. So "location is inside the project" identifies the widgets you wrote, and the file is the one holding the enclosing `build` method, which is what the agent needs to open.

1. In `source_location.dart`, read the location through the inspector's serializer:

   ```dart
   SourceLocation? locationOf(Element e) {
     final json = e.toDiagnosticsNode().toJsonMap(
       InspectorSerializationDelegate(
         service: WidgetInspectorService.instance,
         subtreeDepth: 0,
         includeProperties: false,
       ),
     );
     final loc = json['creationLocation'];
     if (loc is! Map) return null;
     return SourceLocation(
       file: loc['file'] as String,
       line: loc['line'] as int,
       column: loc['column'] as int,
     );
   }
   ```
2. Classify locality yourself in `isLocal(String file)`. The serializer's `createdByLocalProject` flag is only set once an IDE or DevTools has registered the project's root directories, so it is unreliable from a plain `flutter run`. Rules, in order:
   - If `config.projectRoot` is set: local when the path starts with it and does not contain `/.pub-cache/`.
   - Otherwise: local when the path contains none of `/packages/flutter/`, `/.pub-cache/`, `/bin/cache/`.
   - Any path matching `config.localPathHints` is local, for monorepo packages outside the root.
3. In `ancestor_chain.dart`, build the chain from the picked element upward with `visitAncestorElements`, stopping at the app boundary element. Each entry holds `element`, `name`, `key`, `location` and `isLocal`.
4. Default selection is the first entry with `isLocal == true`. If none exists, keep the picked element and set `sourceUnavailable: true` on the result.
5. Keep every local entry even when several share one render object. They are different lines in source.
6. Navigation: Arrow Up or `[` moves to the next local ancestor, Arrow Down or `]` moves back toward the picked widget. Alt plus arrow steps through the full chain, framework widgets included.
7. Compute the highlight rect from `entry.element.renderObject`, which for a component element resolves to the nearest render object beneath it.
8. Show a breadcrumb in the label, for example `SaveBar > ElevatedButton > Text`, and the location as a path relative to `projectRoot`, for example `lib/widgets/save_bar.dart:42`.

**Acceptance**

- [ ] Clicking a button's label in the example selects the `Text`, with a file under `example/lib` and the correct line
- [ ] Arrow Up moves to the `ElevatedButton`, then to the enclosing custom widget, and the outline grows each time
- [ ] No SDK or pub-cache entry appears in the local chain
- [ ] Without `PINPOINT_ROOT`, classification still works through the exclusion rule
- [ ] In profile mode, selection works and the result carries `sourceUnavailable: true`

**Adopted from Flutter Agentation**

- Guard with `WidgetInspectorService.instance.isWidgetCreationTracked()`. When false, skip all location work and set `sourceUnavailable` once.
- Cache locations in an `Expando` keyed by the widget instance.
- Their path normalizer handles `file://` URIs, `package:` URIs and Windows drive paths. Reimplement those three cases with tests.
- Do not copy their lookup method. It sets the inspector's global selection to read a location, which changes what DevTools shows as selected.

**How I would build it**

1. Start from the session 0 spike that reads one real location.
2. Path normalizer and `isLocal` as pure functions with table-driven tests.
3. Chain building, then default selection, then keyboard navigation, then the breadcrumb label.

**How to verify**

- Use a fixture file with marker comments such as `// PIN:save_text` on known lines. The test reads the file, finds the marker's line, and asserts the resolved location matches. It stays correct when the fixture is edited.
- In Chrome, click five different widgets and open each reported `file:line` in the editor. The cursor must land on the constructor call.
- Run once with `PINPOINT_ROOT` set and once without.

**Watch out for**

- The location is the constructor call site. For a widget built in a helper method, that is the helper, which is the right place to edit.
- Widgets from a path dependency in a monorepo look external unless listed in `localPathHints`.
- Generated files count as local. Skip paths ending in `.g.dart` or `.freezed.dart` when choosing the default selection.
- After the agent edits a file, line numbers shift. Elements pick up new locations on hot reload, but any stored anchor (pins in Milestone 8) must re-match by file, widget type and nearest line.
- File-system case differs by platform. Compare paths case-insensitively on Windows and macOS.

## Milestone 4: Context capture and payload schema

Outcome: `ContextCollector.collect(selection, comment, intent)` returns an `Annotation` an agent can act on without seeing the app.

Target shape, with `schema` as a version number so the receiver can evolve:

```json
{
  "schema": 1,
  "id": "pp_20261110_143205_a1f3",
  "createdAt": "2026-11-10T14:32:05Z",
  "intent": "improve",
  "comment": "Label truncates at narrow widths",
  "app": { "buildMode": "debug", "platform": "web", "projectRoot": "/Users/me/app" },
  "page": {
    "url": "http://localhost:5000/#/orders/12",
    "route": "/orders/:id",
    "viewport": { "width": 1280, "height": 720 },
    "devicePixelRatio": 2,
    "textScale": 1.0,
    "brightness": "dark",
    "locale": "en_US"
  },
  "target": {
    "widget": "Text",
    "description": "Text(\"Save changes\")",
    "key": null,
    "source": { "file": "lib/widgets/save_bar.dart", "line": 42, "column": 18 },
    "sourceUnavailable": false,
    "rect": { "x": 912, "y": 648, "w": 96, "h": 20 },
    "renderObject": "RenderParagraph",
    "constraints": "BoxConstraints(0.0<=w<=96.0, 0.0<=h<=Infinity)",
    "parentData": "offset=Offset(16.0, 10.0)",
    "text": "Save changes",
    "properties": { "maxLines": "1", "overflow": "ellipsis" }
  },
  "ancestors": [
    { "widget": "ElevatedButton", "source": { "file": "lib/widgets/save_bar.dart", "line": 40, "column": 14 } },
    { "widget": "SaveBar", "source": { "file": "lib/pages/order_page.dart", "line": 88, "column": 22 } }
  ],
  "frameworkChain": ["RichText", "Text", "DefaultTextStyle", "ElevatedButton"],
  "siblings": { "parent": "Row", "index": 1, "children": ["Icon", "Text", "Spacer"] },
  "subtree": "Text  lib/widgets/save_bar.dart:42\n  RichText",
  "inherited": { "themeBrightness": "dark", "useMaterial3": true, "textDirection": "ltr" },
  "screenshot": { "file": "pp_20261110_143205_a1f3.png", "pixelRatio": 2 }
}
```

1. Write the model classes in `annotation.dart` with manual `toJson`.
2. Fill `target` from the selected element:
   - `description`: `widget.toStringShort()`
   - `properties`: `widget.toDiagnosticsNode().getProperties()`, keeping those at `DiagnosticLevel.info` or above with a non-null value, as `name: toDescription()`. Cap at 20 entries and 200 characters each.
   - `constraints` and `parentData`: `toString()` of each on the render object. `parentData` carries flex factor, fit and offset. Guard both with `try/catch`.
   - `text`: walk descendants, join `RichText.text.toPlainText()` and `EditableText.controller.text`, cap at 300 characters.
3. Fill `ancestors` from the local chain, nearest first, capped at 12. Fill `frameworkChain` with plain type names, capped at 40.
4. Fill `siblings`: walk up to the first ancestor element with more than one child, list the children's `toStringShort()` and the index of the branch holding the target. Cap at 12 children.
5. Fill `subtree`: depth-first from the target, at most 4 levels and 40 nodes, indented text, with `file:line` appended on local widgets.
6. Fill `page` from the overlay's own `BuildContext`: `MediaQuery` size, device pixel ratio, text scaler and platform brightness, `Localizations.localeOf`, and `Uri.base` when `kIsWeb`.
7. Read inherited data on the target without subscribing it. Use `element.getInheritedWidgetOfExactType<T>()` and `findAncestorWidgetOfExactType<Theme>()`, not `.of(element)`, which would register the app's element as a dependent. The route name through `ModalRoute.of` is the one accepted exception; return null if it throws.
8. Make every `source.file` relative to `projectRoot` and strip any `file://` prefix.
9. Enforce a size budget: the JSON without the screenshot stays under 8 KB. Truncate long strings with an ellipsis.

**Acceptance**

- [ ] A fixture test compares the JSON for a fixed example widget against a golden file, ignoring `id` and `createdAt`
- [ ] Every `source.file` is project-relative when `PINPOINT_ROOT` is set
- [ ] Collecting does not rebuild the target: a build counter around it stays unchanged
- [ ] The payload for one item in a 1,000-child list stays under 8 KB
- [ ] No exception when the target is a sliver or has no `RenderBox`

**How I would build it**

1. Model classes and the golden fixture first, so the schema is fixed before any collection code exists.
2. One collector function per payload field, each wrapped so a failure records the field name in an `errors` list and the note still sends.
3. `target` is built from `WidgetInfo`: geometry and section labels map straight into the payload, so the info panel and the note can never disagree.
4. Size budget and truncation last, tested against the worst screen in the example.

**How to verify**

- Sweep test: walk every element on every example screen and run the collector on each. Assert no throw, every payload under 8 KB, and print the slowest collection time.
- Golden JSON test for one fixed widget.
- Feed one real payload to a coding agent with no other context and ask it which file and line to edit and why. If it asks a question the payload could have answered, add that field.

**Watch out for**

- `toStringShort()` and `toDescription()` run code written by widget authors. They can throw or return kilobytes. Guard and truncate each call.
- `Color.toString()` changed format across Flutter releases. Convert colors to hex yourself.
- JSON cannot hold `Infinity` or `NaN`. Unbounded constraints must be strings, and every rect value must be checked with `isFinite`.
- Mask text when any `EditableText` in the subtree has `obscureText: true`.
- `ModalRoute.of` returns null for widgets above the Navigator and for overlay entries. Fall back to the URL.
- With a what-if environment active (Milestone 9), `page` must record both the real viewport and the overridden one.

## Milestone 5: Comment UI

Outcome: after a click, a popover next to the widget takes the comment and submits it to every configured sink.

1. Build `CommentPanel` as a card about 360 px wide. Contents, top to bottom:
   - Breadcrumb of the local chain; each crumb is clickable and reselects that ancestor
   - Widget name and `file:line`, or a "source unavailable" note
   - Intent selector as three chips: Bug, Improve, Question
   - Multiline `TextField`, autofocused, 3 to 8 lines
   - "Include screenshot" checkbox, on by default
   - Buttons: Send, Copy as Markdown, Cancel
2. Place it with a pure function `placePanel(Rect target, Size panel, Size viewport)`. Prefer below the target, then above, then right, then left, and clamp to the viewport with a 12 px margin. A pure function is trivial to unit test.
3. Keyboard: Ctrl or Cmd plus Enter sends, Esc cancels back to picking. Arrow keys must edit text while the field has focus, so ancestor navigation in this mode uses the breadcrumb only.
4. Wrap the panel in its own `FocusScope`. On close, restore the focus node that was primary before picking started.
5. On Send: set mode to `sending`, collect context, capture the screenshot if ticked, then call each sink in order. Show a small toast with the result per sink. If the HTTP sink fails, say so and leave Copy as Markdown available so the comment is never lost.
6. Keep the comment text in the controller until a send succeeds, so a failed send does not clear the field.
7. The panel lives outside the app's `RepaintBoundary`, so it is never picked and never appears in screenshots.

**Acceptance**

- [ ] The panel never overflows the viewport at 360 px and 1920 px widths
- [ ] Ctrl or Cmd plus Enter sends; Esc returns to picking with the selection kept
- [ ] Clicking a breadcrumb reselects and the outline updates
- [ ] With the receiver stopped, the toast reports the failure and the text is still in the field
- [ ] After closing, focus returns to the app field that had it

**How I would build it**

1. `placePanel` as a pure function with tests.
2. The comment form as a tab inside the draggable `InfoPanel` from Milestone 2, driven by a fake sink.
3. Keyboard and focus handling, then the send flow with toasts.

**How to verify**

- Widget tests with a fake sink that can be told to fail.
- In Chrome and Safari: Ctrl or Cmd plus Enter sends, plain Enter inserts a newline, and an IME composition (for example Japanese input) is not cut off by the shortcut.
- Tab key cycles inside the panel and never lands on an app widget behind it.

**Watch out for**

- Autofocusing the comment field steals focus from the app. On mobile web, restoring focus afterwards can reopen the on-screen keyboard; restore only if the app field is still mounted.
- A click outside the panel is ambiguous. Rule: with an empty comment it reselects; with text typed it does nothing, so a stray click never discards a comment.
- Arrow keys belong to the text field while it has focus. Ancestor navigation must not also fire.
- The panel must sit outside the frozen `TickerMode`, or its own caret blink and animations stop when the app is frozen.
- Wrap the panel in a `FocusTraversalGroup` and an `Overlay`-backed `Material`, or text selection handles and the context menu have nowhere to render.

## Milestone 6: Screenshot capture

Outcome: each annotation can carry a PNG crop of the target with its outline drawn on, small enough to POST as base64.

1. Capture from the app's `RepaintBoundary`. The highlight and panel sit outside it, so the image is clean:

   ```dart
   Future<Uint8List> captureTarget(Rect target, double dpr) async {
     await WidgetsBinding.instance.endOfFrame; // toImage asserts nothing needs paint
     final boundary =
         appKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
     final full = await boundary.toImage(pixelRatio: dpr);
     final crop = _cropFor(target, boundary.size);          // logical px
     final src = _scale(crop, dpr);                          // image px
     final recorder = ui.PictureRecorder();
     final canvas = Canvas(recorder)
       ..drawImageRect(full, src, Offset.zero & src.size, Paint())
       ..drawRect(
         _scale(target.shift(-crop.topLeft), dpr),
         Paint()
           ..style = PaintingStyle.stroke
           ..strokeWidth = 2 * dpr
           ..color = const Color(0xFFFF3B30),
       );
     final out = await recorder
         .endRecording()
         .toImage(src.width.round(), src.height.round());
     final bytes = await out.toByteData(format: ui.ImageByteFormat.png);
     full.dispose();
     out.dispose();
     return bytes!.buffer.asUint8List();
   }
   ```
2. `_cropFor` inflates the target by 48 logical px, enforces a minimum of 320 by 200 so small widgets keep their surroundings, and intersects with the boundary's bounds.
3. Use `min(devicePixelRatio, 2)` as the pixel ratio. If the result is wider than `config.maxScreenshotWidth` (default 1600 px), lower the ratio and capture again.
4. The boundary fills the view from the origin, so global and boundary coordinates match. Assert that in debug and convert with `globalToLocal` if it ever fails.
5. Encode as base64 into `screenshot.data` only for sinks that want it. The clipboard sink omits the image.

Known blanks on web: platform views (`HtmlElementView`, embedded maps, iframes) and images served without CORS headers render as empty areas in the capture. Record `screenshot.hasPlatformViews: true` when the subtree contains a `PlatformViewLink` or `HtmlElementView`, so the agent knows the image is partial.

**Acceptance**

- [ ] The PNG decodes, and its size equals the crop size times the pixel ratio
- [ ] The red outline sits on the target within 1 px
- [ ] A 4K viewport capture stays under 1600 px wide
- [ ] Capture works under both CanvasKit and `--wasm` builds
- [ ] Unticking "Include screenshot" sends a payload with no `screenshot` key

**How I would build it**

1. Crop math as pure functions with tests, including fractional pixel ratios.
2. Capture and compose, then encoding, then the width cap.

**How to verify**

- Pixel test: capture a red box on white, decode the PNG, and sample the centre and each corner of the outline.
- Open three real captures by eye: a small icon, a full-width card, a widget at the screen edge.
- Time the capture. Budget is 300 ms on a laptop; PNG encoding dominates, so the width cap is the control.

**Watch out for**

- Fractional device pixel ratios (1.25, 2.625) make the source rect land between pixels. Round outward and clamp to the image bounds, or `drawImageRect` samples outside the image.
- `ui.Image` objects are not garbage collected promptly. Dispose both the full capture and the composed image.
- Debug paint flags (Milestone 10) show up in captures. Record which were on in the payload, or turn them off for the capture frame.
- With a what-if viewport active (Milestone 9), the app boundary no longer starts at the screen origin. Convert the target rect with `globalToLocal` before cropping.
- The screenshot can contain personal data that the text masking never sees. Keep the checkbox visible on every send.

## Milestone 7: Sinks and the local receiver

Outcome: pressing Send in the browser produces files inside the project that a coding agent can read and act on.

**Sinks (in the package)**

1. Define `abstract class PinpointSink { String get name; Future<void> send(Annotation a); }`.
2. `ClipboardSink` copies `a.toMarkdown()` with `Clipboard.setData`. No image.
3. `HttpSink` posts `jsonEncode(a.toJson(includeScreenshotData: true))` with `content-type: application/json`, a 5 second timeout, and throws on any non-2xx status.
4. `MarkdownFormatter` renders the form the agent reads. Lead with the instruction and the location, since that is what the agent acts on:

   ```text
   # Pinpoint pp_20261110_143205_a1f3 (improve)
   
   Comment: Label truncates at narrow widths
   
   Target: Text("Save changes")
   Source: lib/widgets/save_bar.dart:42:18
   Enclosing: ElevatedButton (lib/widgets/save_bar.dart:40) < SaveBar (lib/pages/order_page.dart:88)
   Page: /orders/:id  viewport 1280x720  dark  textScale 1.0
   Layout: rect 912,648 96x20  constraints 0<=w<=96  parent Row, child 2 of 3
   Properties: maxLines=1, overflow=ellipsis
   Screenshot: pp_20261110_143205_a1f3.png
   
   Subtree:
     Text  lib/widgets/save_bar.dart:42
       RichText
   ```

**Receiver (`bin/receiver.dart`, run as `dart run pinpoint:receiver`)**

5. Use `dart:io` `HttpServer` with no extra dependencies. Bind to `InternetAddress.loopbackIPv4` only. Flags: `--port` (default 4747) and `--dir` (default `.pinpoint`).
6. Answer `OPTIONS` with 204 and these headers, and repeat the first one on every response. A JSON POST from a browser always sends a preflight:
   - `Access-Control-Allow-Origin: *`
   - `Access-Control-Allow-Methods: POST, GET, OPTIONS`
   - `Access-Control-Allow-Headers: content-type`
7. `POST /annotations`: parse, reject unless `schema == 1`, decode `screenshot.data` to a PNG, drop the base64 from the JSON, then write three files and return 201 with the id:

   ```text
   .pinpoint/
     open/
       <id>.md
       <id>.json
       <id>.png
     resolved/
   ```
8. `GET /health` returns 200. The overlay calls it when picking starts and shows a small "receiver offline" badge on failure.
9. Print one line per annotation with the path to its `.md` file.
10. Add `.pinpoint/` to the host project's `.gitignore`.

**Agent hand-off**

11. Add a short section to the host project's agent instruction file (`CLAUDE.md` for Claude Code):

    ```text
    ## Pinpoint notes
    UI feedback from the running app lives in .pinpoint/open/*.md.
    When asked to "work the pinpoint notes": for each note, open the Source
    file at the given line, read the comment, view the PNG, make the change,
    run flutter analyze, then move the note's three files to
    .pinpoint/resolved/ and append one line describing the fix to the .md.
    ```
12. Later option: wrap the same folder in an MCP server exposing list, get and resolve. The file inbox is enough to start.

Web transport limits: `http://localhost` to `http://localhost` works in every major browser. If the app is served from a non-local HTTPS origin, the browser may block or prompt on requests to localhost; use the clipboard sink there.

**Acceptance**

- [ ] A preflight `OPTIONS` request gets 204 with the three headers
- [ ] One Send from Chrome creates the `.md`, `.json` and `.png`, and the JSON holds no base64
- [ ] The receiver refuses connections from another machine on the network
- [ ] With the receiver stopped, the offline badge shows and the clipboard sink still works
- [ ] An agent given only the `.md` and `.png` finds the correct file and line

**How I would build it**

1. Markdown formatter as a pure function with golden tests.
2. The receiver as a plain Dart program with its own tests, before any Flutter code calls it.
3. `HttpSink`, then the health badge, then the agent instruction text.

**How to verify**

```bash
# preflight
curl -i -X OPTIONS http://localhost:4747/annotations \
  -H 'Origin: http://localhost:5000' \
  -H 'Access-Control-Request-Method: POST' \
  -H 'Access-Control-Request-Headers: content-type'

# a real note
curl -i -X POST http://localhost:4747/annotations \
  -H 'content-type: application/json' \
  --data @test/fixtures/note.json

ls .pinpoint/open/
```

- From a second device on the same network, the port must refuse the connection.
- Kill the receiver mid-session and send: the note must survive in the clipboard path.

**Watch out for**

- The note `id` becomes a file name. Validate it against `^[a-z0-9_]+$` on the receiver, or a crafted id writes outside `.pinpoint/`.
- Cap the request body at 10 MB and return 413 above it. Base64 inflates the screenshot by a third.
- Write each file to a temporary name and rename it, so the agent never reads a half-written note.
- Add `Access-Control-Allow-Private-Network: true` to the preflight response. Chrome asks for it when a page calls a more private network address.
- If port 4747 is taken, fail with a message that names the flag to change it, and have the app read the port from config.
- Flutter Agentation binds `0.0.0.0` first. Do not copy that; loopback is the default, and a LAN mode is an explicit flag for phone testing.

## Milestone 8: Pins, drafts and the two-way bridge

Outcome: notes stay on screen as numbered pins, the agent reads and resolves them through MCP tools, and a resolved note clears its pin in the running app.

**Pins and drafts (in the app)**

1. Add `status` to `Annotation`: `draft`, `submitted`, `inProgress`, `fixed`, `verified`, `resolved`, `rejected`. A new note is a draft. Only submitted notes are visible to the agent, so half-written feedback never triggers an edit.
2. Add an `anchor` to each note: source file, line, column, widget type, key, ordinal among matches, and route. A pin cannot hold an `Element`; elements die on rebuild and hot reload.
3. Build `SourceIndex.find(anchor)` in `source_index.dart`: walk the app's elements, resolve each location (cached per widget instance), and match on file plus line. If the exact line is gone, take the same widget type in the same file with the nearest line. Return matches in tree order so `ordinal` picks the right list item.
4. Draw each pin as a numbered marker at the top-right of its anchor's rect, re-resolved after each drawn frame. Hide the pin when its route is not current or the anchor has no match.
5. Clicking a pin opens its note in the `InfoPanel`: comment, status, agent replies, and a Send or Delete action. "Send all" submits every draft.

**Bridge (extends the Milestone 7 receiver; `dart run pinpoint:bridge`)**

6. Keep one JSON file per note in `.pinpoint/` as the store. Moving between `open/` and `resolved/` stays, so the file inbox keeps working without MCP.
7. HTTP for the app, beside the existing `POST /annotations`:
   - `GET /annotations?status=` to reload pins after a restart
   - `PATCH /annotations/<id>` for edits and submits
   - `GET /changes?since=<cursor>` so the app learns what the agent did. The app polls it every 2 seconds, only while the overlay is active.
8. MCP for the agent, first tool set:
   - `list_notes(status, detail)`
   - `get_note(id, detail)`, returning the screenshot as image content
   - `update_note(id, status, message)`
9. `detail` is `compact`, `standard` or `full`. Compact is comment, source and rect. Standard adds layout and ancestors. Full adds subtree, properties and environment. Default to standard.
10. Decide the MCP transport in session 0 after reading the current MCP specification and your agent's documentation. Preferred: the long-running bridge serves MCP over HTTP on the same port. Fallback: a stdio shim that forwards to the running bridge. Check whether `package:dart_mcp` covers the chosen transport before hand-rolling JSON-RPC.
11. `dart run pinpoint:setup` writes an instruction snippet and an example MCP config into `.pinpoint/`, prints what to add where, and edits the user's agent configuration only with `--write`.

**Acceptance**

- [ ] A pin stays on its widget through scroll, window resize and hot reload
- [ ] After the agent inserts ten lines above the widget, the pin still resolves
- [ ] Draft notes never appear in `list_notes`
- [ ] `update_note(id, "resolved")` makes the pin show a tick and fade within 3 seconds
- [ ] Restarting the app with the bridge running restores all open pins
- [ ] `get_note` at `compact` detail is under 600 characters for a typical note

**How I would build it**

1. `SourceIndex` first, tested alone. Pins, tweak re-anchoring and agent verification all depend on it.
2. Statuses and anchors in the model, then pin markers.
3. Bridge HTTP additions with tests, then the app's polling.
4. MCP tools last, tested with a scripted JSON-RPC client before any real agent connects.

**How to verify**

- Scripted MCP session in a Dart test: initialize, list tools, call each tool, assert on the files in `.pinpoint/`.
- Full loop by hand: file two notes, submit one, ask the agent to work its notes, watch one pin resolve and the draft stay untouched.
- Measure `SourceIndex` on the long-list screen: first build and cached lookups. Budget 300 ms cold, 20 ms warm.

**Watch out for**

- Resolving a location costs a diagnostics serialization per element. Cold index builds are the slowest operation in the package; cache per widget instance and filter by widget type before resolving when the anchor names one.
- Two tabs of the same app both poll the bridge. Key notes by app origin and route so pins do not appear in the wrong tab.
- Polling must stop when the overlay is idle, or it keeps the network panel noisy and the tab awake.
- The agent can mark a note resolved without fixing it. Milestone 12 adds `verified`; until then, resolved pins fade but stay listed for the user to confirm.
- An MCP tool result with a large base64 image can blow the agent's context. Send screenshots only at `standard` and above, downscaled to 800 px wide.

## Milestone 9: What-if environment switches

Outcome: a toolbar panel changes what the app inherits (viewport size, text scale, safe areas, keyboard, direction, theme, platform, animation speed) without touching app code, and every note records the active overrides.

Because `PinPointWrapper` sits in `MaterialApp.builder`, it is above the Navigator and below the app's `MediaQuery`, `Theme` and `Directionality`. Anything it re-provides is what every screen sees.

| Switch | Mechanism | Notes |
| --- | --- | --- |
| Viewport size | `Align` + `SizedBox` around the app, plus `MediaQuery.size` | Presets and free width and height fields |
| Text scale | `MediaQuery.textScaler` = `TextScaler.linear(x)` | Steps 0.85, 1.0, 1.3, 1.5, 2.0 |
| Bold text | `MediaQuery.boldText` |  |
| Safe areas | `MediaQuery.padding` and `viewPadding` | Presets: none, notch (top 59, bottom 34), custom |
| Fake keyboard | `MediaQuery.viewInsets.bottom` | Draw a grey block in that area |
| Direction | `Directionality(textDirection: rtl)` | Strings stay in the current locale |
| Dark or light | `Theme(data: ...)` from the app's own themes | See step 4 |
| Color scheme | `Theme` with `ColorScheme.fromSeed` | Material 3 apps only; see pitfalls |
| Platform | `debugDefaultTargetPlatformOverride` | Needs a reassemble to take effect |
| Slow motion | `timeDilation` | 1, 2, 5, 10 |

1. Create `EnvironmentController extends ChangeNotifier` holding one immutable `Environment` value with every field nullable, where null means "not overridden". Add `reset()` and `toJson()`.
2. Restructure the app side of the wrapper once, with every layer always present:

   ```dart
   Align(
     child: SizedBox(
       width: env.viewport?.width ?? double.infinity,
       height: env.viewport?.height ?? double.infinity,
       child: ClipRect(
         child: RepaintBoundary(
           key: _appKey,
           child: EnvironmentHost(
             env: env, // MediaQuery > Directionality > Theme
             child: TickerMode(enabled: !frozen, child: widget.child),
           ),
         ),
       ),
     ),
   )
   ```
3. Build the `MediaQuery` override from the real one with `copyWith`. Set `size` to the viewport so `MediaQuery` and `LayoutBuilder` agree. When the fake keyboard is on, also reduce `padding.bottom` to zero, as the real engine does when the keyboard covers the bottom inset.
4. Dark and light: find the app's own themes with `context.findAncestorWidgetOfExactType<MaterialApp>()` and wrap the child in `Theme(data: app.darkTheme ?? ThemeData.dark())` or `app.theme`. Overriding `platformBrightness` alone does nothing, because `MaterialApp` chose its theme above the wrapper.
5. For apps that switch themes through their own state or use `ThemeExtension` tokens, accept `config.themeVariants`: a map from name to `ThemeData` supplied by the app. When present, the panel lists those instead of guessing.
6. Platform override: set the global through `HookRegistry`, then call `WidgetsBinding.instance.reassembleApplication()`. Restore to null on dispose.
7. Ship presets as data in `device_presets.dart`: 360x800, 390x844, 412x915, 600x960, 820x1180, 1280x800, 1440x900, 1920x1080. Add a rotate button that swaps width and height.
8. Paint the area outside the viewport frame with a neutral checker and show the size as a label above the frame.
9. Add `environment` to the note payload, containing only the overridden fields. Show a persistent chip in the toolbar while any override is active, with one-click reset.

**Acceptance**

- [ ] Switching between three viewport presets keeps a counter's value and a text field's content
- [ ] At 360 wide, a `LayoutBuilder` and `MediaQuery.sizeOf` both report 360
- [ ] Text scale 2.0 visibly enlarges text on every route, including an open dialog
- [ ] RTL flips a `Row` with `MainAxisAlignment.start`
- [ ] The fake keyboard makes a `Scaffold` with `resizeToAvoidBottomInset` shrink its body
- [ ] Dark mode uses the app's own `darkTheme` in the example
- [ ] Disposing the wrapper restores `timeDilation` to 1.0 and the platform override to null
- [ ] A note filed at 360 wide and text scale 1.5 carries both in `environment`

**How I would build it**

1. Do the wrapper restructure first and re-run every earlier test. It changes where the app boundary sits, which is the riskiest edit in this milestone.
2. Viewport and `MediaQuery` switches, then direction, then theme, then the two globals.
3. The toolbar panel last; drive everything from tests through the controller before any UI exists.

**How to verify**

- A probe widget in the example prints `MediaQuery` size, text scale, padding, insets, `Directionality`, `Theme.brightness`, `defaultTargetPlatform` and `LayoutBuilder` constraints. Tests and manual checks read the probe.
- Re-run the Milestone 2 picker tests and the Milestone 6 pixel test with a 360x800 viewport active. Outlines and crops must still land on the widget.
- Resize the browser smaller than the chosen viewport: the frame must scroll or scale, not overflow.

**Watch out for**

- The app boundary is no longer at the screen origin. Every place that assumed it (screenshot crop, any `localToGlobal` shortcut) must convert properly. This is why the picker works in global coordinates.
- Code that reads `View.of(context).physicalSize` or `PlatformDispatcher` directly bypasses the override. Report it as a finding in docs, not a bug in Pinpoint.
- Device pixel ratio cannot be faked. A 390-wide viewport on a 1x laptop screen renders at 1x.
- `ThemeData.copyWith(colorScheme:)` does not re-derive component themes in Material 2 apps, so the color-scheme switch can produce mixed colors there. Label it Material 3 only.
- `flutter test` fails any test that leaves `debugDefaultTargetPlatformOverride` set. Reset it in the test's own body before it ends.
- A pointer outside the viewport frame is over nothing. The picker must return no candidates there, and synthetic taps (Milestone 12) must refuse positions outside the frame.
- `reassembleApplication` rebuilds everything and clears held elements, exactly like hot reload. Selection is cleared; pins re-resolve through `SourceIndex`.

## Milestone 10: Automatic problem detection

Outcome: Pinpoint finds overflow, truncated text, oversized images, rebuild hot spots and accessibility problems on the current screen by itself, and each finding becomes a draft note in one click.

Every detector produces the same value, so the UI, the notes and the stress matrix treat them alike:

```dart
class Finding {
  final String kind;        // overflow, truncated_text, oversized_image, ...
  final Severity severity;  // info, warning, error
  final Element? element;   // null when it cannot be located
  final Rect? rect;
  final String summary;     // "Row overflows by 23 px on the right"
  final Map<String, Object?> data;
}

abstract class Detector {
  String get kind;
  List<Finding> scan(RenderObject root); // on demand
}
```

| Detector | How it finds problems | Severity |
| --- | --- | --- |
| Overflow (measured) | For each `RenderFlex`, sum child main-axis sizes plus spacing and compare with its own size | error |
| Overflow and exceptions (captured) | Chain `FlutterError.onError` and `PlatformDispatcher.onError`; read the render object from the error's diagnostics | error |
| Truncated text | Every visible `RenderParagraph` with `didExceedMaxLines == true` | info |
| Oversized images | `debugOnPaintImage` reports decoded size against display size; flag above 2x area | warning |
| Rebuild heat | `debugOnRebuildDirtyWidget` counts per element in a rolling 5 second window | info |
| Accessibility | Semantics tree walk: unlabeled actions, tap targets under 48x48, text contrast under 4.5:1 | warning |
| Debug paint | Toggles for size, baselines, repaint rainbow, layer borders, pointers | (visual aid) |

1. Build the scan runner: "Scan this screen" walks the visible render tree once (reusing the Milestone 2 walk, so offstage and clipped content is skipped) and hands each render object to every scan-type detector.
2. Overflow, measured: implement it yourself. Flutter reports a given overflow only once per render object until the next reassemble, so the error hook alone misses repeat overflows after an environment change.
3. Overflow and exceptions, captured: install through `HookRegistry`, always call the previous handler. For overflow errors, run the error's `informationCollector` and take the `DiagnosticsProperty<RenderObject>` value to get the exact render object. For other errors, keep the exception text, the first eight stack frames, and the widget named in the diagnostics.
4. Truncated text: record the full string and the visible bounds. Truncation is often intended (list titles), so it is `info` and never auto-filed.
5. Oversized images: the callback fires during paint. Only append to a list there; turn entries into findings after the frame. Locate the widget by scanning for a `RenderImage` whose `debugImageLabel` matches the reported source.
6. Rebuild heat: off by default. When on, increment a counter per element in the callback and resolve source locations only when the panel is opened. Exclude Pinpoint's own elements. Show the top ten with counts and tint their rects.
7. Accessibility audit: call `SemanticsBinding.instance.ensureSemantics()`, wait one frame, walk from the root semantics node, then dispose the handle. For contrast, take one screenshot, and for each text paragraph compare the text style color with the most common pixel color inside its rect.
8. Debug paint toggles: set the flag through `HookRegistry`, then mark every render object as needing paint so the change shows without a rebuild.
9. UI: a findings list in the toolbar with a count badge, grouped by kind. Hovering a finding outlines its rect; "Make note" creates a draft with the comment, a suggested check for Milestone 12 (for example `no_overflow`) and the current environment pre-filled.
10. Deduplicate by kind, source location and route, so re-scanning does not pile up copies.

**Acceptance**

- [ ] The example's deliberately overflowing `Row` is found by the measured detector with the right pixel amount
- [ ] After changing viewport width twice, overflow is still reported each time
- [ ] A thrown build error appears as a finding with the widget's file and line
- [ ] A `Text` with `maxLines: 1` and long content is listed with its full string
- [ ] A 2000x2000 image shown at 100x100 is flagged
- [ ] A 24x24 `IconButton` without a tooltip yields two accessibility findings
- [ ] With every detector off, a frame-time comparison against the app without Pinpoint shows no measurable difference
- [ ] Disposing restores all hooks (the `HookRegistry` test)

**How I would build it**

1. `Finding`, the runner and the measured overflow detector, since the stress matrix needs exactly these.
2. Error capture, then truncation, then images.
3. The findings UI and "Make note".
4. Rebuild heat, the accessibility audit and paint toggles last; each is independent and can slip without blocking Milestone 12.

**How to verify**

- Add a "bug zoo" screen to the example with one planted instance of every problem. The test asserts the scan finds exactly those and nothing else on the clean screens.
- Run the scan on a real app of yours and read the list for false positives. Tune thresholds from that, not from the example.
- Toggle each debug paint flag on and off twice and confirm the screen returns to normal.

**Watch out for**

- Never call `setState` or touch widgets inside `onError`, `debugOnPaintImage` or `debugOnRebuildDirtyWidget`. They run during build or paint. Queue and process after the frame.
- DevTools uses the same `debugOnRebuildDirtyWidget` slot for its rebuild counts. If DevTools turns its tracking on after Pinpoint, Pinpoint's callback is replaced. Detect that and show "tracking taken over by DevTools".
- An error inside Pinpoint's own error handler loops. Wrap the handler body in `try/catch` that only prints.
- On web, turning semantics on builds a parallel DOM tree and costs performance. Keep it on only for the audit frame, and confirm in session 0 that disposing the handle really turns it off again.
- Contrast from a screenshot is an estimate. Text over images or gradients gives noisy results; report the measured ratio and mark those as low confidence.
- Measured flex overflow needs a tolerance of about 0.5 px, or rounding produces false errors.
- The verify list in the risks section covers the debug API names used here; several are from memory.

## Milestone 11: Live tweak

Outcome: the Tweak tab of the info panel edits the selected widget's layout and style values in the running app, and the note carries each change as a from-and-to pair the agent can apply in source.

This works because render objects have public setters that relayout or repaint on assignment. `WidgetInfo` already lists each property; here each `InfoProperty` gets its `apply` function.

| Render type | Editable | Created by |
| --- | --- | --- |
| `RenderPadding` | `padding` | `Padding`, `Container(padding, margin)` |
| `RenderConstrainedBox` | `additionalConstraints`: min and max width and height | `SizedBox`, `ConstrainedBox`, `Container(width, height)` |
| `RenderFlex` | `direction`, `mainAxisAlignment`, `crossAxisAlignment`, `mainAxisSize`, `spacing` | `Row`, `Column`, `Flex` |
| `FlexParentData` on a child | `flex`, `fit` | `Expanded`, `Flexible` |
| `RenderPositionedBox` | `alignment`, `widthFactor`, `heightFactor` | `Align`, `Center` |
| `RenderStack`, `StackParentData` | `alignment`, `fit`; `left`, `top`, `right`, `bottom`, `width`, `height` | `Stack`, `Positioned` |
| `RenderParagraph` | font size, weight, color, line height, letter spacing, `textAlign`, `maxLines`, `overflow` | `Text`, `RichText`, `Icon` |
| `RenderDecoratedBox` | color, border radius, border | `DecoratedBox`, `Container(decoration)` |
| `RenderOpacity`, `RenderClipRRect`, `RenderAspectRatio`, `RenderWrap`, `RenderImage` | `opacity`; `borderRadius`; `aspectRatio`; `spacing`, `runSpacing`; `fit` | the widgets of the same name |

1. Add one extractor per row in `info/extractors/`. Each returns an `InfoSection` whose properties carry `apply`. For parent-data properties, `apply` sets the field and then calls `markNeedsLayout()` on the parent render object.
2. For text, rebuild the root span: `paragraph.text = TextSpan(text: old.text, children: old.children, style: old.style?.copyWith(fontSize: v))`. Children that set their own style keep it.
3. Scope the Tweak tab to the selection: show sections for the selected widget's render object and for the render objects between it and the next local ancestor. A `Container` shows its padding, constraints and decoration together, because those render objects all belong to it.
4. Editors: number steppers with steps of 1, 4 and 8 for spacing, a hex field with a swatch for colors, dropdowns for enums, four linked fields for insets. Arrow keys nudge the focused number.
5. Add a constraint chain view: walk up render parents and list each one's type and the constraints it passes down. Incoming constraints cannot be set directly; this view shows which ancestor to tweak instead.
6. Keep a `TweakSession`: a list of `Tweak(anchor, renderType, property, original, value)`. Changes are lost when the owning widget rebuilds, so after each drawn frame compare every tweak's current value with its target and reapply if it was reset.
7. Reset one tweak by applying `original`; reset all by also calling `markNeedsBuild()` on each owning element, which makes the widget write its own values back.
8. Show a persistent "N tweaks active" chip in the toolbar. Tweaked widgets get a dotted outline so a modified screen is never mistaken for the real one.
9. Add the diff to the note:

   ```json
   "tweaks": [
     {
       "renderType": "RenderPadding",
       "property": "padding",
       "from": "EdgeInsets.all(8.0)",
       "to": "EdgeInsets.all(16.0)",
       "createdBy": "Padding",
       "nearestLocal": {
         "widget": "Container",
         "source": { "file": "lib/widgets/save_bar.dart", "line": 31, "column": 12 }
       }
     }
   ]
   ```
10. In the Markdown form, add one line for the agent: "Apply these as source changes. A value may come from a theme or design token; change the token only if every use should change."
11. Capture a before and after screenshot pair when a note with tweaks is sent.

**Acceptance**

- [ ] Changing padding from 8 to 16 moves the child immediately, and the rulers update
- [ ] Changing font size relayouts the paragraph and its parent
- [ ] Changing `mainAxisAlignment` on a `Row` rearranges its children
- [ ] A tweak survives a `setState` in the owning widget's parent, with at most one frame at the old value
- [ ] Reset all returns every value to the widget's own, verified against a fresh `WidgetInfo`
- [ ] The note lists each tweak with the correct nearest local widget and line
- [ ] Selecting a `Container` shows padding, size and decoration in one tab

**How I would build it**

1. `apply` on the two extractors that already exist (paragraph, decorated box), end to end through the panel, to prove the loop.
2. Padding, constrained box and flex next; these cover most layout feedback.
3. `TweakSession` with reapply and reset, then the note diff.
4. Remaining extractors, one small commit each.

**How to verify**

- For each extractor, a widget test applies a value, pumps, and asserts on the render object's size or the child's offset.
- Rebuild test: tweak, trigger `setState` on an ancestor, pump twice, assert the tweak value is back.
- By hand: fix a real spacing problem in your app with tweaks only, send the note, let the agent apply it, hot reload, reset tweaks. The screen must look the same before and after the reset.

**Watch out for**

- A widget that rebuilds every frame (anything animated) resets the tweak every frame. Detect more than five resets a second and show "this widget is animating; tweak cannot hold".
- Assigning to a render object during layout or paint asserts. Apply only from input handlers and post-frame callbacks.
- `Container(color:)` uses a private render object, not `RenderDecoratedBox`. Treat background color there as read-only in v1 and say so in the panel.
- The render property and the source parameter are not always the same thing. `Container(margin:)` and `Container(padding:)` both become `RenderPadding`. Report `createdBy` and `nearestLocal` and let the agent read the code.
- Tweaks that change layout can move the selected widget out from under the panel. The highlight follows; the panel stays where the user put it.
- Tweak edits existing properties only. "Wrap this in a `Padding`" has no render object to edit, so it stays a written request in the comment.

## Milestone 12: Agent drive and verify

Outcome: the agent can find widgets by source line, operate the running app, re-measure the thing a note complained about, and report pass or fail with a before and after screenshot.

**Command channel**

1. A browser app cannot accept connections, so commands flow through the bridge. The agent calls an MCP tool; the bridge queues a command; the app long-polls `GET /commands?wait=25`, runs it, and posts the result to `POST /commands/<id>/result`.
2. Put this behind a `CommandTransport` interface. Add a second implementation as a spike: register `ext.pinpoint.command` with `dart:developer`'s `registerExtension`, and have the bridge call it over the debug connection. It removes polling and CORS but needs the debug service address, so keep long-poll as the default until the spike proves easier.
3. Agent control is off until the user turns on "Allow agent control" in the toolbar. While a command runs, show an "agent is driving" banner and a dot where each synthetic tap lands. Esc aborts the current command and turns control off.

**Tools exposed to the agent**

| Tool | What it does |
| --- | --- |
| `get_screen()` | Route, URL, viewport, environment, bounded outline of visible local widgets |
| `find_widgets({file, line, type, text, key})` | Reverse lookup through `SourceIndex`; returns short-lived handles with rects and visibility |
| `inspect(handle)` | The Milestone 4 payload for that widget |
| `flash(handle)` | Outlines the widget for 1.5 seconds so the user sees what the agent means |
| `tap(handle)`, `long_press(handle)` | Synthetic pointer sequence at the widget's centre |
| `enter_text(handle, text)` | Focuses the field and sets its value as keyboard input |
| `scroll(handle, dx, dy)`, `scroll_to(handle)` | Moves the nearest scrollable; `scroll_to` brings a widget into view |
| `navigate(path)`, `back()` | Route change as if the platform requested it |
| `wait_idle(timeout_ms)` | Returns when no frame is scheduled and no animation is running |
| `set_environment({...})`, `reset_environment()` | Milestone 9 switches |
| `scan({kinds})` | Milestone 10 detectors on the current screen |
| `screenshot({handle})` | Whole app or one widget, downscaled |
| `get_state(handle)` | State dump, step 9 |
| `verify_note(id)` | Runs the note's checks, step 7 |
| `stress_matrix({...})` | Step 8 |

4. Synthetic input: send `PointerAddedEvent`, `PointerDownEvent`, `PointerUpEvent`, `PointerRemovedEvent` through `GestureBinding.instance.handlePointerEvent`, with a pointer id from a private range, increasing timestamps, and about 50 ms between down and up. Before tapping, hit-test the point and confirm the target or one of its descendants is on the hit path; otherwise return "obscured by X" and do not tap.
5. Text entry: find the `EditableTextState` under the handle, request focus, then call `userUpdateTextEditingValue` with the new value and a collapsed selection at the end, so formatters and `onChanged` run as they would for typing.
6. Navigation and idle: `navigate` calls `WidgetsBinding.instance.handlePushRoute(path)` and `back` calls `handlePopRoute()`, which reach both Navigator routes and Router-based packages. `wait_idle` loops on `endOfFrame` until `hasScheduledFrame` is false and `transientCallbackCount` is zero twice in a row, or returns `idle: false` at the timeout.

**Checks and verification**

7. A note carries `checks`, each run under the environment the note was filed in:

   | Check | Passes when |
   | --- | --- |
   | `no_overflow` | The measured overflow detector finds nothing in the widget's subtree |
   | `not_truncated` | No paragraph in the subtree exceeds its lines |
   | `min_size`, `max_size` | The rect is within the given width and height |
   | `within_parent` | The rect lies inside the nearest local ancestor's rect |
   | `gap_to` | The distance to another anchored widget is within a range |
   | `aligned_with` | A chosen edge matches another widget's within 0.5 px |
   | `text_contains` | The subtree's text contains a string |
   | `contrast_min`, `tap_target_min` | The accessibility measures meet the threshold |
   | `visible` | The widget resolves and is on screen |

   The comment form offers these from a short menu. Notes made from a finding get the matching check automatically. `verify_note(id)` then: applies the note's environment, navigates to its route, waits for idle, resolves the anchor, runs each check, captures an "after" screenshot, restores the environment, and returns pass or fail per check with the measured values. The bridge stores the result, the status moves from `fixed` to `verified`, and the pin shows the outcome for the user to accept.
8. Stress matrix: `stress_matrix({widths, textScales, directions, brightness, full})`. By default it varies one axis at a time around the current environment (for example 4 widths, then 3 text scales, then RTL, then dark: 9 runs). With `full: true` it runs the whole product, capped at 48. Each run sets the environment, waits for idle, scans with the measured overflow, truncation and accessibility detectors, and takes a 400 px thumbnail. The result is a table of runs against findings, and each distinct finding becomes a draft note with its environment and a matching check.
9. State dump: for a handle, return the nearest `State`'s diagnostics properties, the enclosing scroll position (pixels, extents, viewport), whether focus is inside the widget, any `EditableText` value and selection, whether its route is current, and the types of inherited widgets above it (up to 30). `config.stateAdapters` lets the app add Bloc, Riverpod or Provider values.

**Acceptance**

- [ ] With control off, every driving tool returns "agent control is disabled" and nothing happens
- [ ] `find_widgets` with a file and line returns the right widget, and `flash` outlines it
- [ ] `tap` on a button fires `onPressed`; `tap` on a button under a dialog barrier returns "obscured"
- [ ] `enter_text` updates the field, runs its formatter and calls `onChanged`
- [ ] `navigate` works in an example using named routes and in one using a Router
- [ ] `wait_idle` returns `idle: false` on a screen with a looping spinner, without hanging
- [ ] For the planted overflow: `verify_note` fails before the fix and passes after a hot reload with the fix
- [ ] `stress_matrix` on the bug zoo screen reports the planted width-dependent overflow only at the narrow widths
- [ ] Environment and scroll position are restored after `verify_note` and `stress_matrix`

**How I would build it**

1. Command channel with one harmless command (`get_screen`), end to end from a scripted MCP client.
2. `find_widgets`, `inspect`, `flash`: read-only tools that reuse earlier milestones.
3. Checks and `verify_note`. This is the feature that closes the loop, so it comes before driving.
4. `wait_idle`, then `tap`, `scroll`, `enter_text`, `navigate`.
5. `stress_matrix`, which is orchestration over pieces that already exist.
6. State dump and the service-extension spike last.

**How to verify**

- A scripted MCP client test drives the example through: navigate, find, tap, enter text, verify. No real agent in the loop, so the test is deterministic.
- The real loop: plant a bug, file a note with a check, ask the agent to fix and verify. Count how many tool calls and how many tokens of tool output it took, and trim the outputs that were not needed.
- Run `stress_matrix` twice in a row. The second run must report the same findings; any difference means state leaked between runs.

**Watch out for**

- Synthetic events enter the same pipeline as real ones. If Pinpoint's pointer trap is up, it swallows them. Driving commands must leave picking mode first.
- Handles hold elements, which die on rebuild. Give each handle a short lifetime, re-resolve from its anchor on use, and return "stale handle" instead of acting on the wrong widget.
- Lazy lists build only what is visible. `find_widgets` cannot see an item that was never built; `scroll_to` needs a loop that scrolls, waits and searches again, with a step limit.
- Hover and focus effects need mouse-kind events and `PointerHoverEvent`. Touch-kind taps skip them, so a check on a hover state needs an explicit `hover(handle)` tool later.
- After a hot reload the source lines have moved. `verify_note` must go through the anchor's nearest-line matching, never a stored line number alone.
- A check that passes because the widget disappeared is a false pass. Every check fails with "anchor not found" when the widget does not resolve.
- Long-poll requests held open for 25 seconds must be cancelled on dispose and when the tab is hidden.
- Tool output is context the agent pays for. Default every list to 20 items and every string to 200 characters, with an explicit parameter to ask for more.
- Anything on this channel can operate the app. Keep it loopback-only, off by default, and visibly on when it is on.

## Testing strategy

Most of the logic is testable with `flutter test`, which runs with widget-creation tracking on, so source locations are available in widget tests.

| Layer | What to test | How |
| --- | --- | --- |
| Pure functions | `isLocal`, path normalizer, `placePanel`, crop math, truncation, Markdown formatting, check evaluation | Unit tests with table-driven cases |
| Search | Smallest-area choice, non-hit-testable widgets, offstage routes, clipped list items, cycling | Widget tests: pump a fixed tree under `PinPointWrapper`, call `RenderSearch.find(tester.getCenter(finder))` |
| Source | Default local selection, navigation, no SDK entries, `SourceIndex` after line shifts | Fixture files with marker comments |
| WidgetInfo and tweak | Each extractor reads the right values; each `apply` changes layout; reapply after rebuild; reset | Widget tests asserting on render sizes and offsets |
| Collector | Payload shape, size budget, no rebuild of target, masking | Golden JSON; sweep over every element of the example |
| Wrapper | State kept across toggle and across environment changes, pointer blocked, shortcut, focus restore | Widget tests with `tester.sendKeyEvent` and a counter app |
| Environment | Each switch reaches a probe widget; globals restored | Probe widget assertions |
| Detectors | Planted bugs found, clean screens silent | Bug zoo screen in the example |
| Hooks | Every global slot restored on dispose | One `HookRegistry` test |
| Screenshot | PNG size, outline position, viewport offset | Widget test inside `tester.runAsync`, decode and sample pixels |
| Bridge | Preflight, file output, id validation, body cap, loopback bind, changes cursor | Dart tests on port 0 with `HttpClient` |
| MCP and agent tools | Tool list, each tool's result shape, control toggle, verify flow | Scripted JSON-RPC client against the bridge and a running test app |

The example app doubles as the manual test bed. Give it one screen each for: a long list, a dialog and bottom sheet, a nested navigator, a `CustomPaint`, a form with text fields, and an `HtmlElementView`.

**Manual web pass before calling v1 done**

- [ ] `flutter run -d chrome` with the receiver running: full flow on every example screen
- [ ] Same flow with `flutter run -d chrome --wasm`
- [ ] Browser zoom at 80% and 150%: outline still lines up with the widget
- [ ] Narrow window (400 px): panel placement and launcher stay on screen
- [ ] `flutter build web` release: no Pinpoint code runs, and the bundle size matches a build without the package to within a few KB

## Risks and things to verify

The main risk is API drift: several calls in this plan are written from memory of the Flutter framework and must be checked against the installed SDK before any code depends on them.

**Verify first, in `packages/flutter/lib/src/widgets/widget_inspector.dart` and `rendering/object.dart`**

- [ ] `InspectorSerializationDelegate` constructor parameters, and that `toJsonMap` emits `creationLocation` with `file`, `line`, `column`
- [ ] What `creationLocation.file` looks like in a web debug build: absolute `file://` URI, plain path, or `packages/...` form
- [ ] `debugDescribeChildren()` marks offstage children with `DiagnosticsTreeStyle.offstage`
- [ ] `describeApproximatePaintClip` returns clips for viewports and clip widgets
- [ ] `RenderObject.debugCreator` is a `DebugCreator` in debug and null otherwise
- [ ] `HardwareKeyboard.instance.addHandler` receives keys on web while a text field has focus

**Verify for Milestones 8 to 12**

- [ ] A render change made during the scheduler's persistent-callback phase does not schedule a new frame (engineering rule 2 depends on this)
- [ ] Names and signatures of `debugOnRebuildDirtyWidget`, `debugOnPaintImage`, and the debug paint flags
- [ ] `RenderParagraph.didExceedMaxLines`, `RenderImage.debugImageLabel` and `RenderFlex.spacing` exist in the installed Flutter
- [ ] An overflow error's diagnostics include a `DiagnosticsProperty<RenderObject>` for the overflowing object
- [ ] Disposing the `ensureSemantics()` handle turns semantics off again on web
- [ ] `handlePushRoute` and `handlePopRoute` drive a Router-based app
- [ ] `EditableTextState.userUpdateTextEditingValue` signature
- [ ] `registerExtension` endpoints are callable in a web debug build
- [ ] Which MCP transports your agent accepts, and whether `package:dart_mcp` covers the chosen one
- [ ] The current tool list of the official Dart and Flutter MCP server, so Pinpoint does not duplicate hot reload or error reporting

**Risks**

| Risk | Effect | Mitigation |
| --- | --- | --- |
| Inspector internals change between Flutter releases | Source lookup breaks on upgrade | Isolate in `source_resolver.dart` and `source_index.dart`; one test asserts a known line |
| Scope: twelve milestones | The project stalls before it is useful | Milestones 1 to 8 are a complete product; 9 to 12 are independent and ordered by value |
| Global debug hooks collide with DevTools or the app | Lost callbacks, confusing behavior | `HookRegistry` chains and restores; detect takeover and say so |
| Covered widget picked over the visible one | Wrong target | Hit-path tie-break, click-again cycling, breadcrumb before commenting |
| Large trees make hover picking or `SourceIndex` slow | Jank while picking, slow pins | One pick per frame; caches; type filter before resolving locations |
| Tweaks reset by rebuilds | Flicker, lost edits | Reapply after each frame; warn on animating widgets |
| Synthetic input acts on the wrong widget | The agent changes app state by mistake | Hit-path check, short-lived handles, control off by default, visible banner |
| Agent marks a note fixed without fixing it | False confidence | `verify_note` with measured checks; the user accepts the result |
| Tool output floods the agent's context | Cost, worse reasoning | Detail levels, list and string caps, downscaled screenshots |
| Payload or screenshot contains personal data | Leaks into files or clipboard | Debug-only default, loopback bind, masking, `.pinpoint/` git-ignored |
| Release web build minifies type names | Unreadable payload | Out of scope; later, a marker widget for stable names |
| Hot reload or reassemble invalidates held elements | Crash on stale selection | Clear selection in `reassemble`; anchors re-resolve; check `mounted` |
| Platform views and non-CORS images blank in capture | Misleading screenshot | `hasPlatformViews` flag in the payload |
| Multi-view apps | Coordinates off | v1 assumes a single view; assert it |

## Running this in Claude Code

Export this doc as Markdown, save it as `PLAN.md` at the repo root, and run one session per milestone with a commit between each. A fresh context per milestone keeps the agent on the acceptance list instead of drifting ahead.

| Session | Scope | Depends on | Done when |
| --- | --- | --- | --- |
| 0 | Verify SDK APIs, scaffold package and example app |  | `docs/api-notes.md` exists; spike test reads a real source line |
| 1 | Milestone 1: wrapper, modes, freeze | 0 | Acceptance tests pass; toggle works in Chrome |
| 2 | Milestone 2: search, `WidgetInfo`, info panel, rulers | 1 | Search tests pass; you have hovered around the example yourself |
| 3 | Milestone 3: local-project refinement | 2 | File and line shown are correct in Chrome |
| 4 | Milestone 4: collector and schema | 3 | Golden JSON and sweep tests pass |
| 5 | Milestones 5 and 6: comment tab and screenshot | 4 | Full flow to the clipboard sink works |
| 6 | Milestone 7: HTTP sink and receiver | 4 | Files land in `.pinpoint/open/` |
| 7 | Milestone 8a: `SourceIndex`, statuses, pins | 3, 6 | Pins survive hot reload |
| 8 | Milestone 8b: bridge changes feed, MCP tools, setup | 7 | Agent resolves a note and the pin clears |
| 9 | Milestone 9: what-if environment | 2 | Probe assertions pass; earlier tests pass with a viewport active |
| 10 | Milestone 10: detectors | 2, 9 | Bug zoo found, clean screens silent |
| 11 | Milestone 11: live tweak | 2, 3, 7 | A real spacing fix goes tweak, note, agent, reload |
| 12 | Milestone 12a: command channel, read tools, checks, `verify_note` | 8, 10 | Planted overflow fails then passes |
| 13 | Milestone 12b: driving tools, stress matrix, state dump | 12, 9 | Scripted client drives the example end to end |
| 14 | Hardening: manual web pass, README, risks table | all | Every manual checkbox ticked |

Sessions 0 to 8 give a complete product: pick, comment, hand off, resolve. Session 9 depends only on the search milestone and is the cheapest large win, so it can be pulled forward to right after session 2. If time runs short, stop after any session from 8 onward; each leaves a working tool.

**Session 0 prompt**

```text
Read PLAN.md fully. Do not write feature code yet.
1. Run `flutter --version` and locate the SDK source on disk.
2. Work through the "Verify first" checklist in PLAN.md by reading the SDK
   source. Write the findings to docs/api-notes.md with exact signatures and
   file paths. Where PLAN.md is wrong, state what to use instead.
3. Scaffold the package as in "Package layout": flutter create with the
   package template, an example app with the six screens listed under
   "Testing strategy", empty source files, strict analysis_options.yaml.
4. Write one spike widget test that pumps a Text, reads its creation
   location, and asserts the file name and line.
Stop there and list every deviation from PLAN.md.
```

**Prompt for each milestone session**

```text
Implement Milestone N from PLAN.md. Where docs/api-notes.md differs from
the plan, follow api-notes. Use the final names from the "Names to use in
code" table.
Before writing code, read "Engineering rules for every milestone" and this
milestone's "How I would build it", "How to verify" and "Watch out for".
Follow the build order, one commit per step.
Write tests for the acceptance list first, then the code.
Turn each "Watch out for" item into either a test or a comment at the line
where it applies, and list which you chose.
Finish only when `flutter analyze` is clean and `flutter test` passes.
Do not start the next milestone.
End with: what changed, which acceptance items are covered by tests, which
need a manual check in the browser, and any plan item you could not do as
written and why.
```

**Where to spend your own attention**

- Sessions 2 and 3 carry the real difficulty. Try the picker in the example app by hand before moving on; tests will not tell you whether the selection feels right.
- The agent cannot see the browser unless you give it a browser tool, so do the manual checks yourself after each session.
- From session 6 onward, use Pinpoint on its own example app to file the remaining UI fixes. That exercises the full loop and shows quickly what the payload is missing.
