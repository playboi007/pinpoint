import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:pinpoint/src/core/hook_registry.dart';
import 'package:pinpoint/src/core/rebuild_hook.dart';
import 'package:pinpoint/src/model/source_location.dart';
import 'package:pinpoint/src/search/source_resolver.dart';
import 'package:pinpoint/src/state/dependencies.dart';
import 'package:pinpoint/src/state/state_lens.dart';
import 'package:pinpoint/src/trace/sources/rebuild_source.dart';
import 'package:pinpoint/src/trace/trace_recorder.dart';

import 'fake_console_filter.dart';

/// A [StateLens] with the parts of a `TraceSession` that it needs, for
/// widget tests: a recorder, the rebuild source, and a frame tick that
/// runs the source after each frame (what the session's clock does).
///
/// Level 3 is held by count, as the session does: the rebuild source runs
/// while the lens holds it.
class LensHost {
  LensHost({required Element? Function() content})
    : resolver = SourceResolver(
        paths: SourcePaths(projectRoot: Directory.current.path),
      ) {
    rebuilds = RebuildSource(
      hook: RebuildHook(hooks),
      content: content,
      resolver: resolver,
    );
    recorder.frameOf = () => frame;
    lens = StateLens(
      recorder: recorder,
      resolver: resolver,
      hooks: hooks,
      rebuildSource: rebuilds,
      content: content,
      demandDetail: () {
        demands++;
        if (demands - releases == 1) rebuilds.start(recorder);
      },
      releaseDetail: () {
        releases++;
        if (demands == releases) rebuilds.stop();
      },
      tags: IdentityTags(),
      consoleFilter: console,
    );
    _hosts.add(this);
    _hook();
  }

  final TraceRecorder recorder = TraceRecorder();
  final HookRegistry hooks = HookRegistry();
  final FakeConsoleFilter console = FakeConsoleFilter();
  final SourceResolver resolver;
  late final RebuildSource rebuilds;
  late final StateLens lens;
  int frame = 0;
  int demands = 0;
  int releases = 0;

  /// Stops the lens and gives every global back.
  void dispose() {
    lens.dispose();
    hooks.dispose();
    _hosts.remove(this);
  }

  static final List<LensHost> _hosts = <LensHost>[];
  static bool _hooked = false;

  // A persistent frame callback cannot be removed: one is added for the
  // process and it serves the hosts alive.
  static void _hook() {
    if (_hooked) return;
    _hooked = true;
    SchedulerBinding.instance.addPersistentFrameCallback((_) {
      for (final host in _hosts.toList()) {
        host.frame++;
        if (host.rebuilds.running) {
          host.rebuilds.afterFrame();
          host.rebuilds.endFrame();
        }
      }
    });
  }
}
