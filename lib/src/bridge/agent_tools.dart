// Plain Dart: the Milestone 12 tools the bridge offers over MCP. Each one
// runs inside the app, through the command queue.

import '../trace/trace_causes.dart' show whyLimits;

/// The agent tools, in the order `tools/list` shows them.
const List<String> agentToolNames = [
  'get_screen',
  'find_widgets',
  'inspect',
  'flash',
  'tap',
  'long_press',
  'enter_text',
  'scroll',
  'scroll_to',
  'navigate',
  'back',
  'wait_idle',
  'set_environment',
  'reset_environment',
  'scan',
  'screenshot',
  'get_state',
  'verify_note',
  'stress_matrix',
  'run_steps',
  'get_trace',
  'trace_detail',
  'watch',
  'unwatch',
  'mark',
  'save_tape',
  'replay',
  'resume_replay',
  'stop_replay',
  'why',
  'caused_by',
  'state_flow',
];

/// How long the bridge waits for the app's answer to [tool].
Duration agentToolTimeout(String tool, Map<String, Object?> args) {
  switch (tool) {
    case 'wait_idle':
      final ms = args['timeout_ms'];
      final wait = ms is num ? ms.round().clamp(0, 60000) : 2000;
      return Duration(milliseconds: wait + 5000);
    case 'verify_note':
    case 'scroll_to':
    case 'save_tape':
      return const Duration(seconds: 60);
    case 'stress_matrix':
    case 'replay':
    case 'resume_replay':
      return const Duration(seconds: 240);
    case 'run_steps':
      // The sum of its steps' own timeouts.
      final steps = args['steps'];
      var total = Duration.zero;
      for (final step in steps is List<Object?> ? steps : const <Object?>[]) {
        if (step is Map<String, Object?> && step['tool'] is String) {
          total += agentToolTimeout(step['tool']! as String, step);
        }
      }
      return total > maxRunStepsTimeout ? maxRunStepsTimeout : total;
  }
  return const Duration(seconds: 20);
}

/// The longest the bridge waits for one `run_steps`.
const Duration maxRunStepsTimeout = Duration(seconds: 240);

const Map<String, Object?> _handle = {
  'type': 'string',
  'description':
      'A handle from get_screen or find_widgets, for example h12. Or give '
      'target instead.',
};

const Map<String, Object?> _waitMs = {
  'type': 'integer',
  'description':
      'For a widget that is not there yet while the app is idle (content '
      'that loads): how long to keep looking, at most 10000. While the app '
      'animates, a widget that is coming in is waited for anyway (1 s).',
};

const Map<String, Object?> _target = {
  'type': 'object',
  'description':
      'Instead of a handle: the widget by query, found again on each call '
      '(never stale). Visible matches first; index picks one (default 0).',
  'properties': {
    ..._query,
    'index': {'type': 'integer'},
  },
};

const Map<String, Object?> _limit = {
  'type': 'integer',
  'description': 'Most items in a list (default 20).',
};

const Map<String, Object?> _maxChars = {
  'type': 'integer',
  'description': 'Longest string (default 200).',
};

const Map<String, Object?> _query = {
  'file': {
    'type': 'string',
    'description': 'Source file, for example lib/screens/home.dart.',
  },
  'line': {
    'type': 'integer',
    'description':
        'Line of the constructor call. Matched to the nearest line of the '
        'same widget type after edits.',
  },
  'type': {'type': 'string', 'description': 'Widget type, for example Text.'},
  'text': {'type': 'string', 'description': 'Text the widget shows.'},
  'key': {'type': 'string', 'description': "The widget's key as text."},
};

Map<String, Object?> _tool(
  String name,
  String title,
  String description, [
  Map<String, Object?> properties = const {},
  List<String> required = const [],
]) => {
  'name': name,
  'title': title,
  'description': description,
  'inputSchema': {
    'type': 'object',
    'properties': properties,
    if (required.isNotEmpty) 'required': required,
  },
};

/// The tool definitions for `tools/list`.
final List<Map<String, Object?>> agentTools = [
  _tool(
    'get_screen',
    'Describe the screen',
    'The running app now: route, URL, viewport, what-if environment, and '
        'the local widgets on screen, each with a short-lived handle. Needs '
        '"Allow agent control" on in the app.',
    {'limit': _limit, 'max_chars': _maxChars},
  ),
  _tool(
    'find_widgets',
    'Find widgets',
    'Finds live widgets by source line (reverse lookup), type, text or '
        'key; every given filter must match. Returns handles with rects and '
        'visibility. An item of a lazy list that was never built cannot be '
        'found; use scroll_to.',
    {..._query, 'limit': _limit, 'max_chars': _maxChars},
  ),
  _tool(
    'inspect',
    'Inspect a widget',
    'The note payload for a handle: source, layout, enclosing widgets.',
    {
      'handle': _handle,
      'target': _target,
      'wait_ms': _waitMs,
      'detail': {
        'type': 'string',
        'enum': ['compact', 'standard', 'full'],
      },
    },
  ),
  _tool(
    'flash',
    'Show a widget to the user',
    'Outlines the widget for 1.5 s in the app, so the user sees which one '
        'you mean.',
    {'handle': _handle, 'target': _target, 'wait_ms': _waitMs},
  ),
  _tool(
    'tap',
    'Tap a widget',
    "A synthetic tap at the widget's center. Refused with \"obscured by X\" "
        'when something else is on top (a dialog barrier).',
    {'handle': _handle, 'target': _target, 'wait_ms': _waitMs},
  ),
  _tool(
    'long_press',
    'Long-press a widget',
    "A synthetic long press at the widget's center.",
    {'handle': _handle, 'target': _target, 'wait_ms': _waitMs},
  ),
  _tool(
    'enter_text',
    'Type into a field',
    'Focuses the text field under the handle and sets its text as typing '
        'would: input formatters and onChanged run.',
    {
      'handle': _handle,
      'target': _target,
      'wait_ms': _waitMs,
      'text': {'type': 'string'},
    },
    ['text'],
  ),
  _tool(
    'scroll',
    'Scroll',
    'Moves a list by dy (vertical) or dx (horizontal) logical pixels '
        '(positive: further down or right): the nearest list of that axis '
        'at or above the handle, or the main list of the screen with no '
        'handle.',
    {
      'handle': _handle,
      'target': _target,
      'wait_ms': _waitMs,
      'dx': {'type': 'number'},
      'dy': {'type': 'number'},
    },
  ),
  _tool(
    'scroll_to',
    'Scroll a widget into view',
    'With handle: brings that widget into view. With file, line, type, text '
        'or key: scrolls the list (within, or the main one) step by step '
        'until such a widget is built and visible, then returns its handle.',
    {
      'handle': _handle,
      'within': _handle,
      ..._query,
      'max_steps': {'type': 'integer', 'description': 'Default 30.'},
    },
  ),
  _tool(
    'navigate',
    'Go to a route',
    'Pushes a route by path as if the platform asked (named routes and '
        'Router apps).',
    {
      'path': {'type': 'string', 'description': 'For example /settings.'},
    },
    ['path'],
  ),
  _tool('back', 'Go back', 'Pops the current route, as the back button does.'),
  _tool(
    'wait_idle',
    'Wait until idle',
    'Returns when no frame is scheduled and no animation runs, or with '
        'idle: false at the timeout (a looping spinner never settles).',
    {
      'timeout_ms': {'type': 'integer', 'description': 'Default 2000.'},
    },
  ),
  _tool(
    'set_environment',
    'Set what-if switches',
    'Overrides what the app inherits. Give only the fields to change; null '
        'clears one.',
    {
      'viewport': {
        'type': ['object', 'null'],
        'properties': {
          'width': {'type': 'number'},
          'height': {'type': 'number'},
        },
      },
      'textScale': {
        'type': ['number', 'null'],
      },
      'boldText': {
        'type': ['boolean', 'null'],
      },
      'textDirection': {
        'type': ['string', 'null'],
        'enum': ['ltr', 'rtl', null],
      },
      'brightness': {
        'type': ['string', 'null'],
        'enum': ['light', 'dark', null],
      },
      'platform': {
        'type': ['string', 'null'],
        'description': 'android, iOS, macOS, windows, linux, fuchsia',
      },
      'timeDilation': {
        'type': ['number', 'null'],
      },
      'keyboardHeight': {
        'type': ['number', 'null'],
      },
      'themeVariant': {
        'type': ['string', 'null'],
      },
      'seedColor': {
        'type': ['string', 'null'],
        'description': '#RRGGBB',
      },
    },
  ),
  _tool(
    'reset_environment',
    'Reset what-if switches',
    'Removes every what-if override.',
  ),
  _tool(
    'scan',
    'Scan for problems',
    'Runs the detectors on the current screen: overflow, truncated_text, '
        'oversized_image, accessibility (labels, tap targets, contrast).',
    {
      'kinds': {
        'type': 'array',
        'items': {
          'type': 'string',
          'enum': [
            'overflow',
            'truncated_text',
            'oversized_image',
            'accessibility',
          ],
        },
      },
      'limit': _limit,
    },
  ),
  _tool(
    'screenshot',
    'Screenshot',
    'The whole app, or one widget outlined, downscaled.',
    {
      'handle': _handle,
      'target': _target,
      'wait_ms': _waitMs,
      'max_width': {'type': 'integer', 'description': 'Default 800.'},
    },
  ),
  _tool(
    'get_state',
    'Dump state',
    "The widget's nearest State properties, scroll position, focus, text "
        'field value, whether its route is current, the inherited widgets '
        "above it, and the app's state adapters.",
    {
      'handle': _handle,
      'target': _target,
      'wait_ms': _waitMs,
      'limit': _limit,
      'max_chars': _maxChars,
    },
  ),
  _tool(
    'verify_note',
    'Verify a note',
    "Runs the note's checks in the app under the environment it was filed "
        'in: navigates to its route, waits for idle, finds the widget by '
        'its anchor, measures, takes an after screenshot, and restores the '
        'environment and scroll. Returns pass or fail per check with the '
        'measured values. Ask for a hot reload first.',
    {
      'id': {'type': 'string'},
    },
    ['id'],
  ),
  _tool(
    'stress_matrix',
    'Stress the screen',
    'Varies widths, text scales, directions and brightness (one axis at a '
        'time, or every combination with full, at most 48 runs), scans '
        'each run, and files a draft note per distinct problem.',
    {
      'widths': {
        'type': 'array',
        'items': {'type': 'number'},
      },
      'textScales': {
        'type': 'array',
        'items': {'type': 'number'},
      },
      'directions': {
        'type': 'array',
        'items': {
          'type': 'string',
          'enum': ['ltr', 'rtl'],
        },
      },
      'brightness': {
        'type': 'array',
        'items': {
          'type': 'string',
          'enum': ['light', 'dark'],
        },
      },
      'full': {'type': 'boolean'},
      'kinds': {
        'type': 'array',
        'items': {'type': 'string'},
      },
    },
  ),
  _tool(
    'run_steps',
    'Run several steps',
    'Runs tools in the app in order, in one call, and stops at the first '
        'step that fails. Each step is {tool, …its args} and answers as '
        'that tool would. Name widgets with target, not handles from an '
        'earlier step. End with one find_widgets or get_state step to check '
        'the result: a read right after a change waits until what it reads '
        'stops moving (a route or a sheet coming in). Nothing else waits. '
        'At most 20 steps; not inspect, screenshot, verify_note or '
        'stress_matrix.',
    {
      'steps': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'tool': {'type': 'string'},
          },
          'required': ['tool'],
        },
        'description':
            'For example [{"tool": "enter_text", "target": {"key": '
            '"email"}, "text": "a@b.c"}, {"tool": "scroll", "dy": 400}, '
            '{"tool": "tap", "target": {"text": "Save"}}].',
      },
    },
    ['steps'],
  ),
  _tool(
    'get_trace',
    'Read what happened',
    'The flight recorder: what the app did, one compact line per event '
        '(seq, time, frame, kind, what), equal lines and repeating blocks '
        'folded with ×n. Taps, keys, text, routes, errors, findings, '
        'probes and marks are always recorded; rebuilds (build) and '
        'watched state (state) only while level 3 runs (trace_detail). '
        'Requests are net.request, net.response and net.error, with the '
        'body hash when bodies are read. With PinPoint.run in main, each '
        'line shows its cause (c37): the tap, frame, key or message that '
        'started it; ask why({seq}) for the chain. '
        'partial: true means a limit dropped older events; notes say where '
        'rebuilds were not recorded. Frames are counted, not listed, '
        'unless kinds asks for frame.',
    {
      'since': {
        'description':
            'A seq (412), seconds back ("30s") or "mark" (the last mark).',
      },
      'until': {'description': 'Same forms as since.'},
      'kinds': {
        'type': 'array',
        'items': {'type': 'string'},
        'description':
            'Kinds or prefixes: input, input.pointer, build, state, probe, '
            'route, error, finding, mark, frame, detail.',
      },
      'widget': {
        'type': 'string',
        'description': 'Part of a widget type or of its source file.',
      },
      'cause': {
        'type': 'integer',
        'description':
            'Only the events of one cause: the c37 on each line (needs '
            'PinPoint.run).',
      },
      'limit': {
        'type': 'integer',
        'description': 'Most lines (default 50, newest kept).',
      },
      'detail': {
        'type': 'string',
        'enum': ['compact', 'full'],
        'description': 'full: whole events as JSON.',
      },
      'run': {
        'type': 'string',
        'description':
            'A replay run id (run_…) from replay: reads that run as the '
            'bridge stored it, also after the page reloaded. Without it, '
            'the live record.',
      },
    },
  ),
  _tool(
    'trace_detail',
    'Record rebuilds and state',
    'Starts or stops level 3 recording for you: rebuilds per widget per '
        'frame and watches. Costly per event, so turn it off when done. '
        'Answers which sources run; when another tool (DevTools "track '
        'rebuilds") holds the rebuild slot, it says so and the other level '
        '3 sources still run.',
    {
      'on': {'type': 'boolean'},
    },
    ['on'],
  ),
  _tool(
    'watch',
    'Watch a widget\'s state',
    'Follows the widget\'s own State and the local States above it, up to '
        'its route (ancestors: how many, default 3, at most 8). After each '
        'rebuild of one of them, get_trace shows a state event with only '
        'the values that changed. At most 8 watches; they start level 3. '
        'Only what a State lists in debugFillProperties is seen: private '
        'fields need a probe (PinPoint.probe).',
    {
      'handle': _handle,
      'target': _target,
      'wait_ms': _waitMs,
      'ancestors': {
        'type': 'integer',
        'description': 'Most States followed (default 3).',
      },
    },
  ),
  _tool(
    'unwatch',
    'Stop watching',
    'Removes a watch by id (w1), or every watch with no id. The last one '
        'stops level 3 unless trace_detail or the Timeline holds it.',
    {
      'id': {'type': 'string'},
    },
  ),
  _tool(
    'why',
    'Why did this happen',
    'Walks back from one event (its seq from get_trace): its cause, the '
        'events of that cause before it, and the entry that started it (a '
        'tap, a key, a message). For a frame, the cause that made it '
        'dirty, then that cause, up to 4 frames back; loop: true when each '
        'frame does the same work again. Needs PinPoint.run in main. '
        '$whyLimits',
    {
      'seq': {'type': 'integer', 'description': 'The event, for example 412.'},
    },
    ['seq'],
  ),
  _tool(
    'caused_by',
    'What did this widget start',
    'Everything the widget\'s subtree started: requests, rebuilds, state '
        'changes, timers and errors, as counts and the first few of each. '
        'A cause counts when its tap landed on the subtree or the subtree '
        'rebuilt in it; a frame\'s work is shared by every widget that '
        'rebuilt in it. Rebuilds need level 3 (trace_detail); causes need '
        'PinPoint.run.',
    {
      'handle': _handle,
      'target': _target,
      'wait_ms': _waitMs,
      'since': {
        'description':
            'A seq (412), seconds back ("30s", the default is "10s") or '
            '"mark".',
      },
    },
  ),
  _tool(
    'state_flow',
    'Why a value changed',
    'Use it to learn why two values change together, or what changed a '
        'value. For a widget (usually a screen or a dialog): first call '
        'opens a window of seconds (default and most 30) and answers what '
        'the widget reads (provider and inherited objects with an identity '
        'tag such as #a1, and the line that made them) and where their '
        'classes are. Then act (run_steps) and call state_flow again with '
        'the same target: the answer is the chain, per cause (a tap): '
        'which object notified, from which method and file:line, the code '
        'lines there (a method that sets two fields and calls '
        'notifyListeners once shows both), which widgets rebuilt because '
        'they read it, and one hint: "one method set both values" (one '
        'notify, many readers), "a notifier triggered another" (a notify '
        'inside a listener), or "two readers of one object" (a dialog and '
        'its screen share one tag). For a ValueNotifier the value before '
        'and after is shown; for plain fields read the code lines. A '
        'setState shows its line too. Costs a stack per setState while '
        'open, so it closes by itself. rearm: true opens a new window on '
        'the same widget. Rebuilds need no level 3 from you; causes need '
        'PinPoint.run.',
    {
      'handle': _handle,
      'target': _target,
      'wait_ms': _waitMs,
      'seconds': {
        'type': 'integer',
        'description':
            'Window length for the first call (default 30, at most 30).',
      },
      'rearm': {
        'type': 'boolean',
        'description':
            'Open a new window on this widget even if it was armed lately.',
      },
    },
  ),
  _tool(
    'mark',
    'Mark this moment',
    'Records a mark in the flight recorder, with an optional sentence, '
        'and a thumbnail of the app. Read from it with get_trace since: '
        '"mark".',
    {
      'text': {
        'type': 'string',
        'description': 'For example "the list is empty here".',
      },
    },
  ),
  _tool(
    'save_tape',
    'Save what happened as a tape',
    'Saves the inputs and network answers of the run as a tape on the '
        'bridge, so the run can happen again with replay. since: "start" '
        '(the default: a full tape from app start, replayed after a '
        'restart), "mark", "mark:N" or seconds back (a segment, replayed '
        'from where the app is). A tape over the body limit, or made with '
        'TraceConfig.bodies false, is a segment; partial says what was '
        'lost. Answers the summary only; bodies stay in .pinpoint/tapes/.',
    {
      'since': {'description': '"start", "mark", "mark:2", 30 or "30s".'},
      'name': {'type': 'string', 'description': 'A short name.'},
    },
  ),
  _tool(
    'replay',
    'Replay a tape',
    'Plays a tape\'s inputs into the app while requests are answered from '
        'the tape: the app does what the user did. Inputs go by logical '
        'order: each waits for the answers that came before it and for its '
        'widget (found by anchor, so a moved button is still hit). Real '
        'input is blocked; Esc stops. Answers when it ends or holds: state '
        '(done, held, stopped, diverged), step of total, first_difference '
        '{step, what, expected, got} (route order, request keys, anchors), '
        'unmatched requests, and partial for a partial tape. Read what '
        'happened with get_trace. Needs agent control on.',
    {
      'tape': {'type': 'string', 'description': 'A tape id (tp_…).'},
      'until': {
        'type': 'string',
        'description':
            '"mark", "mark:N" or "step:N": hold there. The app stays in '
            'that moment for get_state, screenshot, inspect; then '
            'resume_replay or stop_replay.',
      },
      'speed': {
        'type': 'number',
        'description': 'Faster than recorded (2, 4); default 1, at most 20.',
      },
      'unmatched': {
        'type': 'string',
        'enum': ['fail', 'passthrough', 'last'],
        'description':
            'A request the tape has no answer for: fail (default, no '
            'request reaches a server), passthrough (to the real server; '
            'use it after a fix that changes requests), last.',
      },
      'latency': {
        'description': '"recorded" (default), "instant", or ms per answer.',
      },
    },
    ['tape'],
  ),
  _tool(
    'resume_replay',
    'Go on after a hold',
    'Goes on with a replay that holds at until. Answers as replay does.',
    const <String, Object?>{},
  ),
  _tool(
    'stop_replay',
    'Stop the replay',
    'Ends the replay that holds, and gives input and the network back. '
        'Answers its last state.',
    const <String, Object?>{},
  ),
];
