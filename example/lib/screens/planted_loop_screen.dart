import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// The planted loop (PLAN-v2, the real incident): a widget schedules a
/// load from `build`, under a parent that already holds the data. Each
/// rebuild during the load starts the load again.
///
/// To see it with Pinpoint: run `trace_detail({on: true})`, tap "Start",
/// then `get_trace` shows the requests, and `why` on the fifth names the
/// build of [ImproveExistingConfig]. The loop stops after [maxLoads] so the
/// example stays usable.
class PlantedLoopScreen extends StatefulWidget {
  const PlantedLoopScreen({super.key, this.load});

  /// Loads one content type. Default: a `data:` URL through
  /// `package:http`, so the network source records a real request with no
  /// server. Tests pass their own.
  final Future<String> Function(String type)? load;

  static const String route = '/planted-loop';
  static const String title = 'Planted loop';

  @override
  State<PlantedLoopScreen> createState() => _PlantedLoopScreenState();
}

class _PlantedLoopScreenState extends State<PlantedLoopScreen> {
  /// What the parent screen already holds: the child never looks here.
  final Map<String, String> _cache = {'faq': '3 items'};
  int _run = 0;

  static Future<String> _fetch(String type) async {
    final uri = Uri.parse('data:application/json,{"type":"$type","items":3}');
    return (await http.get(uri)).body;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(PlantedLoopScreen.title)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('The parent holds: ${_cache['faq']}'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => setState(() => _run++),
              child: const Text('Start'),
            ),
            const SizedBox(height: 12),
            if (_run > 0)
              ImproveExistingConfig(
                key: ValueKey<int>(_run),
                type: 'faq',
                load: widget.load ?? _fetch,
              ),
          ],
        ),
      ),
    );
  }
}

/// The child with the planted bug.
class ImproveExistingConfig extends StatefulWidget {
  const ImproveExistingConfig({
    super.key,
    required this.type,
    required this.load,
  });

  final String type;
  final Future<String> Function(String type) load;

  /// The loop stops here.
  static const int maxLoads = 6;

  @override
  State<ImproveExistingConfig> createState() => ImproveExistingConfigState();
}

class ImproveExistingConfigState extends State<ImproveExistingConfig> {
  bool _loading = false;
  String? _loadedForType;
  int loads = 0;

  @override
  Widget build(BuildContext context) {
    // The planted bug: a load scheduled from build. Setting `_loading`
    // rebuilds this widget, which schedules the load again before the
    // first answer arrives.
    if (_loadedForType != widget.type &&
        loads < ImproveExistingConfig.maxLoads) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureLoaded());
    }
    return Text(_loading ? 'Loading… ($loads loads)' : 'Loaded ($loads loads)');
  }

  Future<void> _ensureLoaded() async {
    if (!mounted || loads >= ImproveExistingConfig.maxLoads) return;
    setState(() {
      _loading = true;
      loads++;
    });
    try {
      await widget.load(widget.type);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    // The second planted bug: the answer is never remembered, so
    // `_loadedForType` stays null.
  }
}
