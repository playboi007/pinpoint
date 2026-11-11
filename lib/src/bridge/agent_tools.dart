// Plain Dart: the Milestone 12 tools the bridge offers over MCP. Each one
// runs inside the app, through the command queue.

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
      return const Duration(seconds: 60);
    case 'stress_matrix':
      return const Duration(seconds: 240);
  }
  return const Duration(seconds: 20);
}

const Map<String, Object?> _handle = {
  'type': 'string',
  'description': 'A handle from get_screen or find_widgets, for example h12.',
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
      'detail': {
        'type': 'string',
        'enum': ['compact', 'standard', 'full'],
      },
    },
    ['handle'],
  ),
  _tool(
    'flash',
    'Show a widget to the user',
    'Outlines the widget for 1.5 s in the app, so the user sees which one '
        'you mean.',
    {'handle': _handle},
    ['handle'],
  ),
  _tool(
    'tap',
    'Tap a widget',
    "A synthetic tap at the widget's center. Refused with \"obscured by X\" "
        'when something else is on top (a dialog barrier).',
    {'handle': _handle},
    ['handle'],
  ),
  _tool(
    'long_press',
    'Long-press a widget',
    "A synthetic long press at the widget's center.",
    {'handle': _handle},
    ['handle'],
  ),
  _tool(
    'enter_text',
    'Type into a field',
    'Focuses the text field under the handle and sets its text as typing '
        'would: input formatters and onChanged run.',
    {
      'handle': _handle,
      'text': {'type': 'string'},
    },
    ['handle', 'text'],
  ),
  _tool(
    'scroll',
    'Scroll',
    'Moves the nearest scrollable at or above the handle by dx or dy '
        'logical pixels (positive: further down or right).',
    {
      'handle': _handle,
      'dx': {'type': 'number'},
      'dy': {'type': 'number'},
    },
    ['handle'],
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
      'max_width': {'type': 'integer', 'description': 'Default 800.'},
    },
  ),
  _tool(
    'get_state',
    'Dump state',
    "The widget's nearest State properties, scroll position, focus, text "
        'field value, whether its route is current, the inherited widgets '
        "above it, and the app's state adapters.",
    {'handle': _handle, 'limit': _limit, 'max_chars': _maxChars},
    ['handle'],
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
];
