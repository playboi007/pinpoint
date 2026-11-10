# API notes (Session 0)

Result of the "Verify first" lists in `PLAN.md`. Where this file differs from the plan, **follow this file**.

- Flutter 3.47.5 (stable, revision `6a19cca564`), Dart 3.13.4, managed by fvm.
- SDK root: `/Users/mac/fvm/versions/3.47.5`. Below, `$F` means `$SDK/packages/flutter/lib/src`.
- Line numbers are for this SDK version. They will move on upgrade.
- Evidence tags: **[source]** read in SDK code, **[run-vm]** run in `flutter test`, **[run-web]** run on Chrome, **[unverified]** needs a browser or device check.

## Summary

| # | Item | Result |
| --- | --- | --- |
| 1 | `InspectorSerializationDelegate` and `creationLocation` | OK. Plan code works. JSON has extra fields. |
| 2 | Format of `creationLocation.file` on web | Absolute `file:///` URI. |
| 3 | Offstage marking in `debugDescribeChildren()` | OK, but only some render objects mark it. |
| 4 | `describeApproximatePaintClip` | OK, but clips are conditional. |
| 5 | `RenderObject.debugCreator` | OK. |
| 6 | `HardwareKeyboard.addHandler` | **PLAN WRONG.** Returning `true` does not stop the focused field. |
| 7 | Persistent-callback phase | OK, with one caveat. |
| 8 | Debug hook names | Names OK. **DevTools conflict is an assert, not a silent replace.** |
| 9 | `didExceedMaxLines`, `debugImageLabel`, `spacing` | All exist. |
| 10 | Overflow error diagnostics | **PLAN WRONG.** No `DiagnosticsProperty<RenderObject>`. |
| 11 | `ensureSemantics()` handle on web | Framework side OK. Web DOM side **[unverified]**. |
| 12 | `handlePushRoute` / `handlePopRoute` | **PLAN WRONG.** Both are `@protected @visibleForTesting`. |
| 13 | `userUpdateTextEditingValue` | **PLAN INCOMPLETE.** It takes two arguments. |
| 14 | `registerExtension` on web | Works only with a debugger attached (DWDS). |
| 15 | MCP transports and `package:dart_mcp` | Claude Code: stdio, HTTP, SSE. `dart_mcp`: stdio only. |
| 16 | Tool list of the official Dart and Flutter MCP server | 14 tools by default. See overlap list. |
| 17 | Facts found in Session 1 | Freeze jumps on resume; `FocusNode.context` outlives detach; `Overlay.wrap` exists. |
| 18 | Facts found in Session 2 | `RenderObject.constraints` is protected; transient callbacks see old layout; scroll passthrough rules. |
| 19 | Facts found in Session 3 | Read locations from the widget's node; a custom widget shares its build root's render object; refinement cost. |
| 20 | Facts found in Session 4 | `ModalRoute.settingsOf` on an inherited element can self-depend; diagnostics formats; collection cost. |
| 21 | Facts found in Session 5 | A text field outside the Navigator needs a `DismissIntent` action; key results for text fields; a focused field draws frames. |
| 22 | Facts found in Session 6 | `RenderObject.layer` is protected, so capture the whole boundary; `endOfFrame` forces a frame; images in tests need `runAsync`. |
| 23 | Facts found in Session 7 | `dart run pinpoint:bridge` works from a Flutter host app; an early 413 is lost unless the body is read; widget tests fake `HttpClient`. |

---

## 1. `InspectorSerializationDelegate` and `creationLocation` — OK

**[source]** `$F/widgets/widget_inspector.dart:4464`

```dart
InspectorSerializationDelegate({
  this.groupName,                       // String?
  this.summaryTree = false,
  this.maxDescendantsTruncatableNode = -1,
  this.expandPropertyValues = true,
  this.subtreeDepth = 1,
  this.includeProperties = false,
  required this.service,                // WidgetInspectorService
  this.addAdditionalPropertiesCallback,
  this.inDisableWidgetInspectorScope = false,
});
```

The plan code for `locationOf` compiles and works as written. **[run-vm]** `test/source/spike_location_test.dart` passes. Raw output:

```text
{file: file:///Users/mac/Desktop/development/Hobby/PinPoint/test/source/spike_location_test.dart, line: 21, column: 16, name: Text}
```

Details:

- `DiagnosticsNode.toJsonMap(DiagnosticsSerializationDelegate)` is in `$F/foundation/diagnostics.dart:1642`.
- `additionalNodeProperties` (`widget_inspector.dart:4521`) adds `creationLocation`, `locationId` and `createdByLocalProject`.
- `_Location` (`widget_inspector.dart:4185`) has `file`, `line`, `column` (both 1-based) and an optional `name`. The JSON **also carries `name`** (the constructor name, for example `Text`). The plan does not list it. It is free extra data.
- **Debug only.** The body of `toJsonMap` sits inside `assert(...)`. In profile and release it returns `{}`. Guard with `WidgetInspectorService.instance.isWidgetCreationTracked()` (`widget_inspector.dart:2521`, public).
- `WidgetInspectorService`, `InspectorSerializationDelegate` and `DiagnosticsNode` all come from `package:flutter/widgets.dart`. No `src/` import is needed.
- Public helpers exist: `debugIsLocalCreationLocation(Object)` (`:4369`, debug only) and `debugIsWidgetLocalCreation(Widget)` (`:4385`). They use the inspector's own root list. Do not use them for `isLocal`. See the next point.

**Plan correction (why `createdByLocalProject` is unreliable).** The plan says the flag is set only after an IDE registers roots. The real rule is `_isLocalCreationLocationImpl` (`widget_inspector.dart:1805`):

```dart
final String file = Uri.parse(locationUri).path;
if (_pubRootDirectories == null) return !file.contains('packages/flutter/');
for (final dir in _pubRootDirectories!) { if (file.startsWith(dir)) return true; }
return false;
```

With no roots set, **everything outside `packages/flutter/` is "local"**. That includes `.pub-cache` packages and path dependencies. So the flag is too permissive, not too strict. The plan's conclusion still holds: classify locality in `isLocal` ourselves.

## 2. Format of `creationLocation.file` — absolute `file://` URI

- **[run-web]** `flutter run -d chrome` (DDC, debug), app file and SDK file:
  - app: `file:///Users/mac/Desktop/development/Hobby/PinPoint/example/lib/tmp_probe_main.dart`, line 13, column 15
  - SDK: `file:///Users/mac/fvm/versions/3.47.5/packages/flutter/lib/src/widgets/text.dart`, line 780, column 16
- **[run-vm]** `flutter test`: same `file:///` form.
- **[run-web]** `flutter test --platform chrome`: the test entrypoint is `org-dartlang-app:///tmp_web_probe_test.dart`. The directory is dropped. SDK files stay `file:///`.

Use this in the path normalizer:

1. `file:///...` — the normal case. Strip the scheme and decode percent escapes.
2. `org-dartlang-app:///name.dart` — only seen in `flutter test --platform chrome`. Not a real-app case. Treat as "unknown directory". Do not resolve it against `projectRoot`.
3. `package:` and Windows drive paths — **not seen** on any platform tested. Keep the table-driven tests the plan asks for, but they are low priority.

The plan lists "plain path, or `packages/...`" as possible. Neither appeared.

The location is the **call site**. A `const TmpPinProbe()` written in the app file reports the app file, even though the class lives in the `pinpoint` package. This matches Milestone 3.

**[unverified]** Not probed: widgets from `.pub-cache` packages, `--wasm` builds, profile mode, Windows.

## 3. Offstage marking in `debugDescribeChildren()` — OK, but only some marks

**[source]** `DiagnosticsTreeStyle.offstage` is set in these places only:

| Render object | File:line | What is marked |
| --- | --- | --- |
| `RenderOffstage` | `rendering/proxy_box.dart:3961` | its child when `offstage` |
| `RenderSliverOffstage` | `rendering/proxy_sliver.dart:413` | its child when `offstage` |
| `RenderIndexedStack` | `rendering/stack.dart:883` | all children except `index` |
| sliver keep-alive bucket | `rendering/sliver_multi_box_adaptor.dart:~800` | kept-alive, not laid-out children |
| `_RenderTheater` (Overlay) | `widgets/overlay.dart:1596` | every entry below the first onstage entry |
| view element | `widgets/view.dart:880` | extra views |

Routes under an opaque route are covered by the `_RenderTheater` row. The plan's skip rule is right.

Other facts:

- `debugDescribeChildren()` can return nodes whose `value` is **not** a `RenderObject` (for example `DiagnosticsNode.message('no offstage children')` in the theater). The plan's `child is! RenderObject` skip is needed.
- Flutter's own inspector does the same walk. Copy its shape: `widget_inspector.dart:2931` (`_hitTestHelper`). It:
  - walks children in **reverse** (topmost first),
  - skips `style == offstage` and non-`RenderObject` values,
  - uses `object.describeApproximatePaintClip(child)` in the parent's local space,
  - carries a transform down with `object.applyPaintTransform(child, transform)` instead of calling `getTransformTo` per node,
  - uses `semanticBounds` (the plan uses `paintBounds`; for `RenderBox` both are `Offset.zero & size`).
- The inspector's final sort is by area only (`widget_inspector.dart:2990`). The plan's extra depth and traversal-order tie-breaks are an improvement.
- Using the `applyPaintTransform` approach is also the fallback the plan names for the 8 ms budget.

## 4. `describeApproximatePaintClip` — OK, clips are conditional

**[source]** `$F/rendering/object.dart:3762`

```dart
Rect? describeApproximatePaintClip(covariant RenderObject child) => null;
```

The rect is in **this object's** (the parent's) local coordinate system. It is `null` when the child is not clipped.

Implementers and conditions:

| Class | File:line | Returns a clip when |
| --- | --- | --- |
| `_RenderCustomClip<T>` (`ClipRect`, `ClipRRect`, `ClipPath`, ...) | `rendering/proxy_box.dart:1560` | `clipBehavior != Clip.none` |
| `RenderViewportBase` | `rendering/viewport.dart:886` | `clipBehavior != Clip.none`, except for `ensureSemantics` slivers that are not visible |
| `_RenderSingleChildViewport` | `widgets/single_child_scroll_view.dart:584` | `_shouldClipAtPaintOffset` |
| `RenderListWheelViewport` | `rendering/list_wheel_viewport.dart:1069` | `_shouldClipAtCurrentOffset()` |
| `RenderFlex` | `rendering/flex.dart:1469` | `clipBehavior != none` **and** the flex overflows |
| `RenderStack` | `rendering/stack.dart:742` | `clipBehavior != none` **and** it has visual overflow |
| `RenderEditable` | `rendering/editable.dart:2705` | `clipBehavior != none` **and** `_hasVisualOverflow` |
| `RenderConstraintsTransformBox` | `rendering/shifted_box.dart:1006` | `clipBehavior != none` and it overflows |
| `_RenderTheater` (Overlay) | `widgets/overlay.dart:1577` | `clipBehavior != none` (always `size`) |

So: viewports and clip widgets clip, as the plan says. A `Row` or `Stack` clips only when it overflows. Do not expect a clip rect from a normal `Row`.

Related, from the plan's M2 "Watch out for":

- The plan says a singular transform **throws** in `transformRect`. **[source]** `RenderObject.getTransformTo` (`object.dart:3686`) returns `Matrix4.zero()` for a singular path. `MatrixUtils.transformRect` (`painting/matrix_utils.dart:271`) has no throw path. The result can be a non-finite rect. Keep the per-node `try/catch` and also test `rect.isFinite`.
- `getTransformTo` asserts `attached`. Keep the `attached` check.

## 5. `RenderObject.debugCreator` — OK

**[source]**

- Field: `Object? debugCreator;` at `$F/rendering/object.dart:2222`.
- Set to `DebugCreator(this)` inside an `assert` in `RenderObjectElement._debugUpdateRenderObjectOwner` (`widgets/framework.dart:6829`). So it is `null` outside debug.
- `class DebugCreator` (`widgets/framework.dart:7387`) has `final Element element;` and is public.
- The value is the `RenderObjectElement` that owns the render object. The plan's `elementFor` works as written.

## 6. `HardwareKeyboard.addHandler` — PLAN WRONG

**[source]** `$F/services/hardware_keyboard.dart`

```dart
typedef KeyEventCallback = bool Function(KeyEvent event);   // :317
void addHandler(KeyEventCallback handler)                    // :570
void removeHandler(KeyEventCallback handler)                 // :588
```

The doc on `addHandler` says: *"All registered handlers will be invoked in order regardless of their return value."* The dispatch loop (`:615`) never stops early. The return value only reports "handled" to the embedder (add-to-app case).

Focus is a separate path. `FocusManager` receives keys through `KeyEventManager.keyMessageHandler` (`focus_manager.dart:2139`), after the hardware handlers. So:

- **Plan M1 "Watch out for" is wrong:** returning `true` does **not** swallow the key for the app.
- **Plan M1 acceptance "caret stops receiving keys" cannot pass** with a handler alone.

Use instead:

- For the shortcut and Esc: `addHandler` is fine. It sees every key. Keep returning `true` only for keys Pinpoint uses.
- To stop a focused `TextField` from getting keys in picking mode: move focus away. Save `FocusManager.instance.primaryFocus`, call `unfocus()` when picking starts, and restore it on exit (this also matches M5 step 4). Or hold focus in a Pinpoint `Focus` node with `onKeyEvent` that returns `KeyEventResult.handled`.
- Handlers added during dispatch take effect after dispatch (`:571`). A handler that throws is caught and reported (`:626`).

**[unverified]** Whether key events reach Flutter on web while a DOM `<input>` has focus. The engine code is not in the SDK checkout. This is the M1 manual check.

## 7. Persistent-callback phase — OK, with one caveat

**[source]** `$F/scheduler/binding.dart:906`

```dart
void ensureVisualUpdate() {
  switch (schedulerPhase) {
    case SchedulerPhase.idle:
    case SchedulerPhase.postFrameCallbacks:
      scheduleFrame();
      return;
    case SchedulerPhase.transientCallbacks:
    case SchedulerPhase.midFrameMicrotasks:
    case SchedulerPhase.persistentCallbacks:
      return;
  }
}
```

`markNeedsPaint`, `markNeedsLayout` and `scheduleBuildFor` all reach this through `PipelineOwner.requestVisualUpdate` (`rendering/binding.dart:891`). Rule 2 is right: a change made in the persistent phase does not schedule a frame.

Caveats:

- A **post-frame** callback runs in `postFrameCallbacks`, where `ensureVisualUpdate` **does** schedule a frame. A post-frame callback that mutates state on every run keeps the app at full frame rate. Mutate only when the value really changed.
- `scheduleFrame()` itself (`:946`) does not look at the phase. `handleBeginFrame` clears `_hasScheduledFrame` first (`:1254`), so an explicit `scheduleFrame()` in the persistent phase does work.
- `addPersistentFrameCallback(FrameCallback)` (`:781`) has **no remove method**. A callback added once stays for the life of the app. Guard it with a `disposed` flag. `HookRegistry` tests must account for this: this slot cannot be "restored".

## 8. Debug hook names and signatures

| Hook | Declaration | File:line |
| --- | --- | --- |
| `debugOnRebuildDirtyWidget` | `RebuildDirtyWidgetCallback? debugOnRebuildDirtyWidget;` with `typedef void Function(Element e, bool builtOnce)` | `widgets/debug.dart:74`, `:57` |
| `debugOnPaintImage` | `PaintImageCallback? debugOnPaintImage;` with `typedef void Function(ImageSizeInfo info)` | `painting/debug.dart:150`, `:63` |
| `debugPaintSizeEnabled` | `bool` | `rendering/debug.dart:36` |
| `debugPaintBaselinesEnabled` | `bool` | `:39` |
| `debugPaintTextLayoutBoxes` | `bool` (not in plan) | `:48` |
| `debugPaintLayerBordersEnabled` | `bool` | `:51` |
| `debugPaintPointersEnabled` | `bool` | `:59` |
| `debugRepaintRainbowEnabled` | `bool` | `:67` |
| `debugRepaintTextRainbowEnabled` | `bool` (not in plan) | `:70` |
| `timeDilation` | `double get` / `set` (asserts `> 0`) | `scheduler/binding.dart:37`, `:45` |
| `debugDefaultTargetPlatformOverride` | `TargetPlatform? get` / `set` | `foundation/platform.dart:104`, `:106` |
| `FlutterError.onError` | `FlutterExceptionHandler?` static | `foundation/assertions.dart` |

`ImageSizeInfo({String? source, required Size displaySize, required Size imageSize})` has getters `displaySizeInBytes` and `decodedSizeInBytes` (`painting/debug.dart:88`).

Behavior that matters for Milestone 10:

- **`debugOnRebuildDirtyWidget` — PLAN WRONG about DevTools.** `Element.rebuild` calls it inside an `assert` (`widgets/framework.dart:5522`), so it is debug only. When DevTools turns on "track rebuilds", the inspector runs `assert(debugOnRebuildDirtyWidget == null)` and then assigns (`widget_inspector.dart:1116`). When it turns tracking off it assigns `null` (`:1123`). So:
  - If Pinpoint's hook is installed first, the DevTools toggle fails with an **assertion error**.
  - If DevTools tracking is turned off later, it **clears Pinpoint's hook silently**.
  - Mitigation: install the hook only while the heat feature is on. Each frame, check `identical(debugOnRebuildDirtyWidget, ours)`. If not, show "tracking taken over" and do not restore over it.
- **`debugOnPaintImage` is called once per distinct size, not once per frame.** `paintImage` (`painting/decoration_image.dart:683`) skips the call when the same `ImageSizeInfo` was reported in the last frame. A steady oversized image is not re-reported. Pinpoint must keep its own record. It runs when `!kReleaseMode`, so profile mode too.
  - `displaySize` is in **physical** pixels: `outputSize * maxDevicePixelRatio`. Compare it with `imageSize` directly.
  - `source` is `debugImageLabel ?? '<Unknown Image(W×H)>'`.
- `flutter test` fails a test that leaves `debugOnPaintImage` set (`debugAssertAllPaintingVarsUnset`, `painting/debug.dart:190`). Reset it in the test body.
- The `debugPaint*` flags are plain top-level variables. To make a change show without a rebuild, mark render objects as needing paint yourself.

## 9. Members that must exist — all present

**[source]**

- `RenderParagraph.didExceedMaxLines` — `bool get`, `rendering/paragraph.dart:1208`.
- `RenderImage.debugImageLabel` — `String? debugImageLabel;` plain field, `rendering/image.dart:104`.
- `RenderFlex.spacing` — `double get spacing` and `set spacing`, `rendering/flex.dart:694`.
- `RenderFlex` overflow state is **private** (`_overflow`, `_hasOverflow`, `flex.dart:623`). The measured overflow detector must recompute from child sizes, as the plan says.

## 10. Overflow error diagnostics — PLAN WRONG

**[source]** `$F/rendering/debug_overflow_indicator.dart:215` (`_reportOverflow`) reports:

```dart
FlutterErrorDetails(
  exception: FlutterError('A $runtimeType overflowed by $overflowText.'),
  library: 'rendering library',
  context: ErrorDescription('during layout'),
  informationCollector: () => <DiagnosticsNode>[
    if (kDebugMode && debugCreator != null) DiagnosticsDebugCreator(debugCreator!),
    ...overflowHints!,
    describeForError('The specific $runtimeType in question is'),
    DiagnosticsNode.message('◢◤' * (FlutterError.wrapWidth ~/ 2), allowWrap: false),
  ],
)
```

There is **no `DiagnosticsProperty<RenderObject>`**. Use one of:

1. Call `details.informationCollector?.call()` and take the first node where `node.value is RenderObject`. `describeForError` (`rendering/object.dart:4163`) returns `toDiagnosticsNode(...)`, so `.value` is the render object.
2. Find the node that `is DiagnosticsDebugCreator` (`rendering/object.dart:6821`, a `DiagnosticsProperty<Object>` named `debugCreator`). Its `.value` is a `DebugCreator`, so `(node.value as DebugCreator).element` gives the **element** directly. Debug only.

Other facts:

- The text is `A RenderFlex overflowed by 23 pixels on the right.` The pixel amount is in the message only. It is not structured data (there is a `TODO(jacobr)` for that).
- The error is reported from `paintOverflowIndicator` (paint phase), not layout, although the context says "during layout".
- It is reported once per render object. `_overflowReportNeeded` (`debug_overflow_indicator.dart:127`) resets only in `reassemble()` and only inside an `assert`. The plan is right that the hook misses repeats.

## 11. `ensureSemantics()` handle on web — framework OK, web unverified

**[source]** `$F/semantics/binding.dart:144`

```dart
SemanticsHandle ensureSemantics()
```

`SemanticsHandle.dispose()` calls `_didDisposeSemanticsHandle` (`:152`). It lowers the handle count and sets `_semanticsEnabled.value = _outstandingHandles > 0`. When the last handle goes, the framework stops building the tree.

The web DOM tree is built by the engine. The engine is not in the SDK checkout. **[unverified]** Check in Chrome that the `flt-semantics` DOM nodes disappear after the handle is disposed. The framework also tracks `platformDispatcher.semanticsEnabled` separately (`:71`), so a user who has turned on accessibility keeps it on.

## 12. `handlePushRoute` and `handlePopRoute` — PLAN WRONG

**[source]** `$F/widgets/binding.dart`

```dart
@protected @visibleForTesting
Future<bool> handlePushRoute(String route)   // :1256
@protected @visibleForTesting
Future<bool> handlePopRoute()                // :1113
```

Calling them from package code is a `invalid_use_of_protected_member` and `invalid_use_of_visible_for_testing_member` violation. `analysis_options.yaml` makes both errors, so this fails the analyzer.

Use the supported entry point, the navigation platform channel (`SystemChannels.navigation`, `JSONMethodCodec`, `services/system_channels.dart:76`). The framework handles it in `_handleNavigationInvocation` (`widgets/binding.dart:1305`):

| Method | Argument | Calls |
| --- | --- | --- |
| `pushRoute` | `String` | `handlePushRoute` |
| `popRoute` | none | `handlePopRoute` |
| `pushRouteInformation` | `{'location': String, 'state': Object?}` | observers' `didPushRouteInformation` (`:1279`) |

Send a message through `ServicesBinding.instance.defaultBinaryMessenger.handlePlatformMessage('flutter/navigation', const JSONMethodCodec().encodeMethodCall(MethodCall(...)), callback)`. `handlePlatformMessage` is public (`services/platform_channel.dart:61`).

Who listens (all are `WidgetsBindingObserver`s):

- Navigator 1 apps: `_WidgetsAppState.didPushRouteInformation` (`widgets/app.dart:1623`) calls `navigator.pushNamed(...)`. It returns `false` when the app uses a `Router` (`_usesRouterWithDelegates`). Pop: `didPopRoute` (`app.dart:1607`) calls `navigator.maybePop()`.
- Router apps: `PlatformRouteInformationProvider.didPushRouteInformation` (`widgets/router.dart:1590`) and `RootBackButtonDispatcher.didPopRoute` (`router.dart:1112`).

`pushRoute` **pushes** a named route. It does not replace. **[unverified]** The behavior on a real `Router` app was not run. That is the M12 acceptance test.

## 13. `EditableTextState.userUpdateTextEditingValue` — takes two arguments

**[source]** `$F/widgets/editable_text.dart:5147`

```dart
void userUpdateTextEditingValue(TextEditingValue value, SelectionChangedCause? cause)
```

The plan only names the value. Pass a cause (for example `SelectionChangedCause.keyboard`).

Flow: if `value == textEditingValue` it only requests focus and returns. Otherwise it calls `_formatAndSetValue(value, cause, userInteraction: true)` (`:4703`). That applies `widget.inputFormatters` and then calls `widget.onChanged` (`:4766`). The plan's expectation (formatters and `onChanged` run as for typing) is correct.

## 14. `registerExtension` on web

**[source]**

- `void registerExtension(String method, ServiceExtensionHandler handler)` — `dart-sdk/lib/developer/extension.dart:109`. The name must start with `ext.`.
- DDC (`flutter run -d chrome`, debug): `dart-sdk/lib/_internal/js_dev_runtime/patch/developer_patch.dart:92`. It registers **only when a debugger is attached** and the `$emitRegisterEvent` hook (DWDS) exists. Otherwise it prints a `console.warn` and **ignores** the call.
- dart2js (`js_runtime/lib/developer_patch.dart:120`) and dart2wasm (`wasm/standalone/developer_patch.dart:92`): the handler goes into a map. Nothing can call it through the VM service.
- Flutter's own extensions use the same call (`$F/foundation/binding.dart:930`).

So the plan's check is: **works in `flutter run -d chrome` (DWDS attached); not in a served or release build.** The bridge needs the debug service address, as the plan says. **[unverified]** Not run end to end.

## 15. MCP transports

- Claude Code accepts stdio (default), HTTP (`--transport http`) and SSE. **[run]** `claude mcp add --help` shows the HTTP and stdio forms, and `-H` headers for "HTTP/SSE servers".
- `package:dart_mcp` **0.5.2** (published 2026-06-29; `sdk: ^3.7.0`; deps `async`, `collection`, `json_rpc_2`, `meta`, `stream_channel`, `stream_transform`). Servers and clients run over a `StreamChannel<String>`. The package ships **only `stdioChannel`** (`lib/stdio.dart`). There is no HTTP or SSE transport.
- Result: the plan's preferred option (MCP over HTTP on the bridge port) needs a hand-written `StreamChannel` adapter over HTTP. The fallback (stdio shim that forwards to the running bridge) works with `dart_mcp` as is.
- `dart_mcp` has no Flutter dependency, so `bin/bridge.dart` can use it. It is a **new dependency beyond `http`**. Engineering rule 10 needs a recorded decision before adding it.
- Keep every file that `bin/` imports (for example `lib/src/model/annotation.dart`) free of `dart:ui` and `package:flutter`. A plain Dart process cannot import them. **[run]** `dart run pinpoint:bridge` works from `example/`, a Flutter app that depends on the package (Session 7, item 23).

## 16. Official Dart and Flutter MCP server

**[run]** `dart mcp-server` — name `dart and flutter tooling`, version 1.2.2, protocol `2025-06-18`. Tools listed by default (14):

`analyze_files`, `dtd`, `flutter_driver_command`, `get_runtime_errors`, `hot_reload`, `hot_restart`, `lsp`, `pub`, `pub_dev_search`, `read_package_uris`, `rip_grep_packages`, `roots`, `vm_service`, `widget_inspector`.

Do **not** duplicate:

- `hot_reload`, `hot_restart` — the agent already has these. Pinpoint's `verify_note` flow should ask the agent to reload, not do it.
- `get_runtime_errors` — covers runtime error reading. Pinpoint's error capture (M10) is for notes and findings, not for this.
- `widget_inspector` — covers the widget tree and selection. Pinpoint's value is source-line lookup, notes, checks and drive tools.
- `flutter_driver_command` — a different drive path (needs `flutter_driver`). Pinpoint's synthetic input does not need it.

Extra tools exist behind `--enable` (`launch_app`, `list_devices`, `run_tests`, `stop_app`, `get_app_logs`, `get_active_location`, `create_project`, `dart_fix`, `dart_format`, ...). They are off by default. Re-check the list when the server version changes.

## 17. Facts found in Session 1

- **[source]** `Ticker.muted` (`scheduler/ticker.dart:119`) unschedules ticks but keeps `_startTime` (`:277`). After unmuting, elapsed time includes the muted period. `TickerMode` freeze therefore jumps animations forward on resume.
- **[source]** `FocusNode.context` (`widgets/focus_manager.dart:638`) is set in `attach` and never cleared by `detach` (`:223`). Use `context?.mounted` to tell whether a saved node is still in the tree.
- **[source]** `Overlay.wrap({child, clipBehavior, alwaysSizeToContent})` exists (`widgets/overlay.dart:501`). It needs no `OverlayEntry` lifecycle code.
- **[source]** `Material(type: MaterialType.transparency)` does not absorb hits (`material/material.dart:491`). A layer built on it lets pointer events through except where a child takes them.
- **[source]** `MaterialApp.builder` output is wrapped in `ScaffoldMessenger`, `Theme` and the `WidgetsApp` `Shortcuts`, `FocusTraversalGroup` and `Localizations` (`material/app.dart:1042`, `widgets/app.dart:1725`). A Pinpoint focus node that returns `handled` stops keys before those `Shortcuts`.
- **[run-vm]** `WidgetsBinding.reassembleApplication()` completes after the next frame. In a test, pump before awaiting it.

## 18. Facts found in Session 2

- **[source]** `RenderObject.constraints` is `@protected` (`rendering/object.dart:2593`). The `RenderBox` (`box.dart:2558`) and `RenderSliver` (`sliver.dart:1335`) overrides carry no annotation, so read it through a typed receiver (`WidgetInfo` does this in `constraintsOf`). The plan's `ro.constraints` on a plain `RenderObject` fails the strict analyzer.
- **[run-vm]** A transient frame callback (`scheduleFrameCallback`, `scheduler/binding.dart:608`) runs before build and layout of its frame, so it sees the last frame's geometry. After `pointerScroll`, a pick there still finds the item that just scrolled away. Pick in a post-frame callback after anything that moves layout.
- **[run-vm]** `Transform.scale` and `Transform.rotate` keep their own layout box; only the child is transformed. At the center of a scaled-up child, the `RenderTransform` (smaller area) is the smallest candidate. The scaled child wins only outside the original box.
- **[source]** `ScrollPosition.pointerScroll(double)` is public (`widgets/scroll_position.dart:952`). `Scrollable` handles a wheel like this (`widgets/scrollable.dart:933-983`): flip the axis for a mouse wheel while Shift is held, negate the delta for a reversed axis direction, skip when `physics.shouldAcceptUserOffset` is false or the clamped target equals `pixels`, then `pointerScroll(delta)` and `event.respond(allowPlatformDefault: false)`. Pinpoint copies all of it except the Shift flip; it uses the larger delta, as the plan says.
- **[run-vm]** Pick time, 500-item `ListTile` list, VM debug test: p50 0.27 ms, p95 0.87 ms over 200 picks, with `debugDescribeChildren` and transforms carried down.
- **[run-web]** Pick time, example "Long list" screen (1000 items), `flutter run -d chrome` (DDC, debug), 200 hover picks: **p50 5.4 ms, p95 6.6 ms**. Under the 8 ms budget, but DDC is about 20 times slower than the VM test, and the margin at p95 is 1.4 ms. A deeper tree or a larger window can go over. If it does, replace `debugDescribeChildren` first (it allocates a node per child). One pick runs per frame while the pointer moves, so in debug, hover uses about a third of a 16 ms frame.

## 19. Facts found in Session 3

- **[source]** `_getCreationLocation` (`widgets/widget_inspector.dart:4412`) reads `element.widget` for an element, so `widget.toDiagnosticsNode().toJsonMap(...)` gives the same `creationLocation` as the element's node. The widget's node is cheaper: `toJsonMap` calls `getChildren()` (`foundation/diagnostics.dart:1646`), and an element's node describes every child. `SourceResolver` reads the widget's node.
- **[source]** `toJsonMap` registers each new location in a global map (`_locationToId`, `widget_inspector.dart:4420`). It grows with the number of distinct source locations, not with picks. It does not touch `WidgetInspectorService.selection`. **[run-vm]** A test asserts the selection is unchanged.
- **[run-vm]** A custom widget's element has no render object of its own: `Element.renderObject` is the nearest one beneath, the render object of the root of its `build`. So `SaveBar` and the `Padding` it returns share one rect. PLAN Milestone 3 acceptance "the outline grows each time" cannot hold for that step. Navigation still stops on both: they are different lines in source.
- **[run-vm]** Every widget whose constructor call is in a project file is local, framework widgets included (`Row`, `Padding`, `Scaffold`). The local chain for a button label is `Text`, `ElevatedButton`, `Row`, `Padding`, `SaveBar`, `Column`, ... ; the button's own internals are not local.
- **[run-vm]** Refinement cost (chain, then entries up to the first local one), 500-item `ListTile` list, VM debug test, 200 picks: cold cache p50 0.12 ms, p95 0.32 ms; warm p50 0.07 ms, p95 0.12 ms. In addition to the walk. **[unverified]** On web (DDC, about 20 times slower) the cold p95 can add about 6 ms to the 6.6 ms walk; check with `PINPOINT_PICK_TIMINGS`, which from Session 3 times the walk plus the refinement.
- **[run-vm]** Dart 3.13 accepts private named initializing formals (`required this._root`). The call site uses `root:`.

## 20. Facts found in Session 4

- **[run-vm]** `ModalRoute.settingsOf(context)` (`widgets/routes.dart:1348`) goes through `InheritedModel.inheritFrom` and `dependOnInheritedElement`. Called with the route's own `_ModalScopeStatus` element, that element finds itself (an `InheritedElement` is in its own inherited map) and depends on itself. The next status change (for example a pushed route) fails the assertion in `InheritedElement.notifyClients` (`widgets/framework.dart:6430`, "check that it really is our descendant"). The collector reads the route on the element that owns the picked render object: a `RenderObjectElement` is never an `InheritedElement`.
- **[run-vm]** There is no public route lookup that does not depend: `ModalRoute.of`, `settingsOf`, `isCurrentOf` all subscribe, and `_ModalScopeStatus` is private. `settingsOf` is the narrowest: it rebuilds only when the route's settings change.
- **[run-vm]** `Text.toStringShort()` is just `Text`. The plan's `Text("Save changes")` comes from the `data` property, which has `showName: false`. The collector builds `description` from `toStringShort()` plus the unnamed properties at info level.
- **[run-vm]** `Color` diagnostics are long in this SDK: `MaterialColor(primary value: Color(alpha: 1.0000, red: 0.9569, ...))`. Convert with `toARGB32()` (`formatColor`).
- **[run-vm]** A `TextField`'s `controller` property is at info level and its description holds the text: `TextEditingController#…(TextEditingValue(text: ┤hunter2├, ...))`, with `obscureText: true` too. The collector masks any value that holds an obscured field's text.
- **[run-vm]** `jsonEncode` throws `JsonUnsupportedObjectError` on `double.infinity` and `NaN`. `BoxConstraints.toString()` prints `Infinity` inside a string, which is fine.
- **[run-vm]** A Material button's own widgets are about 38 elements deep. With the plan's cap of 40, `frameworkChain` for a button label ends at the `ElevatedButton`.
- **[run-vm]** Collection cost: sweep of every element on every example screen, VM debug test: 6604 notes, largest 3614 bytes, slowest 13.3 ms (a `Theme` near the top of a screen: its text scan and subtree are the largest). **[unverified]** On web (DDC, about 20 times slower) the slowest can be about 250 ms; it runs once per Send, not per frame.

## 21. Facts found in Session 5

- **[run-vm]** Esc in a focused `EditableText` runs its `DismissIntent` action (`widgets/editable_text.dart:5642`). With no text menu open, it calls `Actions.invoke(context, intent)` up the tree. In an app a route has that action; `WidgetsApp.defaultActions` (`widgets/app.dart:1408`) does not. A text field above the Navigator (Pinpoint's layer) then fails an assertion ("Unable to find an action for an Intent with type DismissIntent"). Give it `DismissIntent: DoNothingAction(consumesKey: false)`.
- **[source]** `DefaultTextEditingShortcuts` maps plain Enter and Space to `DoNothingAndStopPropagationTextIntent` when a field has focus (`widgets/default_text_editing_shortcuts.dart:328`, "These keys should go to the IME"). A modifier makes a `SingleActivator` miss, so Ctrl+Enter falls through to an outer `Shortcuts`.
- **[source]** `ShortcutManager.handleKeypress` (`widgets/shortcuts.dart:922`) returns `ignored` when the action is disabled (and the manager is not modal). The key goes on up the focus chain. A send action that is disabled while an input method composes lets Enter reach the input method.
- **[source]** `KeyEventResult.skipRemainingHandlers` (`widgets/focus_manager.dart:87`) stops the key going up the focus chain, but the platform still acts on it (the browser types the character). `handled` stops both. A Focus with `skipRemainingHandlers` around Pinpoint's panel keeps typed keys from the app's `Shortcuts` and still lets the field get text.
- **[run-vm]** A focused `TextField` draws frames on its own: about 170 ms after it gains focus (the decoration animates), about 100 ms after a metrics change (it scrolls the caret into view), and a caret blink twice a second. A test that checks `hasScheduledFrame` after a selection must wait about 300 ms, and can set `EditableText.debugDeterministicCursor`.
- **[run-vm]** The first mouse event after a touch tap starts a ticker in Pinpoint's panel that stops after about 150 ms. The owner was not found; it is a Material animation, not a loop.
- **[run-vm]** The `flutter test` font makes every glyph 1 em wide. Labels are wider than in a browser and wrap sooner (in the 360 px panel, the intent chips and the buttons wrap). Size checks in tests are pessimistic.

## 22. Facts found in Session 6

- **[source]** `RenderObject.layer` is `@protected` (`rendering/object.dart:3158`). So `OffsetLayer.toImage(Rect bounds)` (`rendering/layer.dart:1546`), which could render only the crop, cannot be called from package code without failing the strict analyzer. Capture the whole boundary with `RenderRepaintBoundary.toImage` (`rendering/proxy_box.dart:3552`) and crop with `drawImageRect`, as the plan does.
- **[source]** `OffsetLayer.toImage` rounds the image size up: `(pixelRatio * bounds.width).ceil()` (`layer.dart:1553`). At a fractional ratio the full capture is up to one pixel larger than the boundary times the ratio. Pinpoint clamps its source rect to the image it gets.
- **[source]** `RenderRepaintBoundary.toImage` asserts `!debugNeedsPaint` (`proxy_box.dart:3553`). `debugNeedsPaint` returns `false` outside debug (`object.dart:3292`), so profile builds do not check it.
- **[source]** `SchedulerBinding.endOfFrame` (`scheduler/binding.dart:847`) calls `scheduleFrame()` when the phase is idle. Awaiting it always forces a frame. Pinpoint awaits it only when `hasScheduledFrame` is true or a frame is running (`paintSettled`).
- **[run-vm]** In `flutter test`, `RenderRepaintBoundary.toImage`, `Picture.toImage`, `Image.toByteData` and `instantiateImageCodec` finish only inside `tester.runAsync`. `pump` alone never completes them. A test that taps Send must alternate `pump` and a short real delay in `runAsync` (`test/support/finish_send.dart`).
- **[run-vm]** `ui.Image.onCreate` / `onDispose` and `ui.Picture.onCreate` / `onDispose` (`dart:ui`, `painting.dart:1993`, `:8442`) are static hooks. A test can count live images and pictures around a capture.
- **[run-vm]** `PlatformViewLink` with a fake `PlatformViewController` (four members: `viewId`, `dispatchPointerEvent`, `clearFocus`, `dispose`) builds and lays out in a VM test, so platform-view detection is testable without a browser.
- **[run-vm]** `200 * 1.1` is `220.00000000000003`. A plain `ceil()` on a scaled edge adds a pixel; `pixelRectFor` uses a slack of `1e-6`.
- **[run-vm]** The flutter_tester renderer draws solid colours exactly. Pixel tests can sample the outline colour within 8 per channel at ratios 1, 1.25 and 2.
- **[unverified]** Capture under CanvasKit and `--wasm` in Chrome, capture time in a browser (budget 300 ms), and blank platform views on the example's HTML view screen.

## 23. Facts found in Session 7

- **[run]** `cd example && dart run pinpoint:bridge` compiles and runs the bridge from a Flutter host app that depends on `pinpoint` (closes the item 15 check). Everything `bin/bridge.dart` imports is plain Dart; `test/bridge/bridge_options_test.dart` walks the imports to keep it so.
- **[run-vm]** `dart:io` `HttpServer`: when a handler answers and closes while the request body is still unread, the connection is reset, and the client loses the answer too (`HttpException: Connection closed before full header was received`). For the 413 the bridge reads and drops the rest of the body, up to 40 MB, and then answers.
- **[source]** `TestWidgetsFlutterBinding` sets `HttpOverrides.global` to a fake (`flutter_test/lib/src/binding.dart:1289`, `_binding_io.dart:27`) whose responses are all 400 (`_binding_io.dart:365`). A test that talks to a real server over `dart:io` must be a plain `test` in a file with no `testWidgets`. `package:http`'s `MockClient` is not affected.
- **[source]** `package:http` 1.6 does not add `charset` to an `application/json` content type (`request.dart:20`). The request is still not a CORS "simple request", so a browser sends the preflight.
- **[run]** Under fvm, `dart run` is a wrapper process around the Dart VM. A SIGINT sent only to the wrapper (for example `pkill -f pinpoint:bridge`) does not stop the bridge; Ctrl+C in a terminal signals both.
- **[unverified]** In Chrome: the preflight and POST from the app to `http://127.0.0.1:4747`, the Private Network Access header, `Clipboard.setData` after the screenshot's awaits (the click's user activation must still hold), and the toast text for a refused connection (the browser gives only `XMLHttpRequest error`).

---

## Other plan errors and gaps found while scaffolding

- **Names.** Code samples use `PinpointOverlay`, `PinpointController`, `PinpointMode`, `PinpointConfig`. The "Names to use in code" table says `PinPointWrapper`. The public-surface table mixes `PinPointConfig` / `PinPointController` with `PinpointSink` / `ClipboardSink` / `HttpSink`. **Decided in Session 1:** every public type uses `PinPoint…` (`PinPointWrapper`, `PinPointConfig`, `PinPointController`, `PinPointMode`, `PinPointShortcut`, and later `PinPointSink`). The package name stays `pinpoint`. Files are snake_case, so they are not affected.
- **Receiver name.** Milestone 7 says `bin/receiver.dart` and `dart run pinpoint:receiver`. The layout and the names table say `bin/bridge.dart`. The scaffold uses `bin/bridge.dart`.
- **Milestone 1 key claims** (item 6 above). **Done in Session 1:** the `HardwareKeyboard` handler reads the shortcut, Esc and P. To keep keys from the app, a Pinpoint `Focus` node takes primary focus while a mode is active, and its `onKeyEvent` returns `handled`. The app's focus is saved on entry and restored on exit. The Session 0 option "call `unfocus()`" was not used. `unfocus()` moves focus to the enclosing scope, so the app's `Shortcuts` (Tab, arrows) still get keys.
- **Milestone 9 acceptance "Disposing the wrapper restores `timeDilation`"** is fine, but `addPersistentFrameCallback` cannot be undone (item 7). The `HookRegistry` test must not claim to restore that slot.
