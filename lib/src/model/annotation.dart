// Plain Dart: no `dart:ui` and no `package:flutter`, so the bridge (`bin/`)
// can read and write the same payload.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../sink/markdown_formatter.dart';
import 'json_read.dart';
import 'note_round.dart';

part 'annotation_budget.dart';
part 'annotation_format.dart';
part 'annotation_json.dart';
part 'annotation_media.dart';
part 'annotation_state.dart';
part 'annotation_target.dart';

/// The payload version. The receiver rejects any other value, so a change
/// to the shape below needs a new number.
///
/// 2: `status`, `anchor`, `messages` and `app.origin`. 3: `environment`.
/// 4: `finding` and `checks`. 5: `tweaks` and `screenshot.beforeAfter`.
/// 6: `verification`. 7: `trace`. 8: `tape`. 9: `stateOwners`; the old
/// `frameworkChain` is ignored and `page.url` has its query values masked.
/// 10: `stateOwners[].dependencies` and the owner kind `reader`.
/// 11: `rounds`, written by the bridge.
const int annotationSchema = 11;

/// The start of the first trace line when rebuilds were not recorded in all
/// or part of the window.
const String traceNotRecorded = 'rebuilds not recorded';

/// Largest JSON for a note, without the screenshot, in UTF-8 bytes.
const int maxPayloadBytes = 8 * 1024;

/// What the note asks for.
enum AnnotationIntent { bug, improve, question }

/// Where a note is in its round trip between the user and the agent.
///
/// The JSON value is the enum name, for example `inProgress`.
enum NoteStatus {
  /// Written but not sent. Never visible to the agent, so half-written
  /// feedback never triggers an edit.
  draft,

  /// Sent: the agent may work on it.
  submitted,

  /// The agent is working on it.
  inProgress,

  /// The agent changed the code; not yet checked.
  fixed,

  /// The user, or a measured check, accepted the result.
  verified,

  /// The agent says it is done. The pin fades but stays until the user
  /// accepts it: an agent can mark a note resolved without fixing it.
  resolved,

  /// The agent will not do it, with a message that says why.
  rejected;

  /// The status named [name], or null.
  static NoteStatus? byName(Object? name) {
    for (final status in values) {
      if (status.name == name) return status;
    }
    return null;
  }

  /// Statuses whose files live in `open/`: the agent's work list.
  static const Set<NoteStatus> open = {submitted, inProgress, fixed};

  /// Statuses whose files live in `resolved/`.
  static const Set<NoteStatus> closed = {verified, resolved, rejected};
}

/// A message on a note, for example the agent's reply when it resolves it.
class NoteMessage {
  const NoteMessage({required this.at, required this.from, required this.text});

  /// [json] as a message, or null when it has no text.
  static NoteMessage? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final text = json['text'];
    if (text is! String) return null;
    final from = json['from'];
    return NoteMessage(
      at: asDate(json['at']) ?? DateTime.utc(1970),
      from: from is String ? from : 'agent',
      text: text,
    );
  }

  final DateTime at;

  /// `agent` or `user`.
  final String from;

  final String text;

  Map<String, Object?> toJson() => {
    'at': formatTimestamp(at),
    'from': from,
    'text': text,
  };
}

/// One note: a comment on a widget, with everything an agent needs to act
/// on it without seeing the app.
///
/// [toJson] keeps a fixed shape: every key is present, with null for a part
/// that could not be read, except [errors] and [truncated], which appear
/// only when not empty, [screenshot], which appears only when the note
/// has one, [environment], which appears only while a what-if override
/// is active, [finding] and [checks], which appear only on a note made
/// from a finding, [tweaks], which appear only while a tweak is active,
/// [verification], which appears once `verify_note` ran, [trace], which
/// appears when the flight recorder ran, and [rounds], which appear once the
/// agent worked the note.
/// `test/goldens/annotation_schema.json` fixes it.
class Annotation {
  const Annotation({
    required this.id,
    required this.createdAt,
    required this.intent,
    required this.comment,
    required this.app,
    required this.page,
    required this.target,
    this.status = NoteStatus.draft,
    this.anchor,
    this.messages = const <NoteMessage>[],
    this.ancestors = const <AncestorInfo>[],
    this.stateOwners = const <StateOwnerInfo>[],
    this.rounds = const <Map<String, Object?>>[],
    this.siblings,
    this.subtree,
    this.inherited,
    this.environment,
    this.finding,
    this.checks = const <Map<String, Object?>>[],
    this.tweaks = const <Map<String, Object?>>[],
    this.verification,
    this.trace,
    this.tape,
    this.screenshot,
    this.errors = const <String>[],
    this.truncated = const <String>[],
  });

  /// For example `pp_20261110_143205_a1f3`. See [annotationId].
  final String id;

  final DateTime createdAt;
  final AnnotationIntent intent;
  final String comment;
  final AppInfo app;
  final PageInfo page;
  final TargetInfo target;

  /// A new note is a draft until it is sent.
  final NoteStatus status;

  /// Where the note's pin belongs. Null when it was not read.
  final NoteAnchor? anchor;

  /// Replies from the agent and the user, oldest first.
  final List<NoteMessage> messages;

  /// Local widgets above the target, nearest first.
  final List<AncestorInfo> ancestors;

  /// The objects that hold state for the target, nearest first, at most 4:
  /// a local `State`, or a provider-like scope. Input for the state lens.
  final List<StateOwnerInfo> stateOwners;

  /// The agent's passes on this note, oldest first, written by the bridge.
  /// Read them with [roundViews]. The app never writes them: the bridge keeps
  /// its own copy when a note is sent again.
  final List<Map<String, Object?>> rounds;

  /// [rounds] as typed values, oldest first.
  List<NoteRound> get roundViews => [
    for (final r in rounds) ?NoteRound.fromJson(r),
  ];

  final SiblingsInfo? siblings;

  /// The target's subtree as indented text, `file:line` on local widgets.
  final String? subtree;

  final InheritedInfo? inherited;

  /// The what-if overrides active when the note was filed, only the
  /// overridden fields (`EnvironmentController.toJson`), for example
  /// `{viewport: {width: 360, height: 800}, textScale: 1.5}`. Null when
  /// nothing was overridden. [page] keeps the real window.
  final Map<String, Object?>? environment;

  /// The finding this note was made from (`Finding.toJson`: kind,
  /// severity, summary, key and measured data), or null for a note written
  /// by hand.
  final Map<String, Object?>? finding;

  /// What `verify_note` measures, each with a `type`, for example
  /// `{type: no_overflow}`. Empty when none were chosen.
  final List<Map<String, Object?>> checks;

  /// The last `verify_note` outcome, written by the bridge: `at`,
  /// `passed`, `checks` (each `type`, `passed`, `message`, `measured`),
  /// `found` (where the anchor resolved) and `after` (the after
  /// screenshot's file). Null until a verification ran.
  final Map<String, Object?>? verification;

  /// What happened before the pick: `seconds` (the window), `lines` (at most
  /// 60), `rebuilds` (whether they were recorded) and `partial` with a
  /// `reason` when a limit dropped events. Null when the recorder was off.
  final Map<String, Object?>? trace;

  /// The attached tape: `id`, `kind` (full or segment), `inputs`, `requests`,
  /// `marks`, and `partial` when a limit dropped data. The tape itself is on
  /// the bridge, in `.pinpoint/tapes/`. Null when none is attached.
  final Map<String, Object?>? tape;

  /// Whether the last verification passed; null when none ran.
  bool? get checksPassed => switch (verification?['passed']) {
    final bool passed => passed,
    _ => null,
  };

  /// The live edits on screen when the note was filed (`Tweak.toJson`):
  /// `renderType`, `property`, `from`, `to`, `createdBy` and
  /// `nearestLocal`, for the agent to apply in source. Empty without any.
  final List<Map<String, Object?>> tweaks;

  /// Null when "Include screenshot" was off or the capture failed.
  final ScreenshotInfo? screenshot;

  /// Fields that failed to collect, for example `target.parentData`. The
  /// note is sent anyway.
  final List<String> errors;

  /// Fields cut to keep the payload in its size budget.
  final List<String> truncated;

  Annotation copyWith({
    String? comment,
    AnnotationIntent? intent,
    NoteStatus? status,
    NoteAnchor? Function()? anchor,
    List<NoteMessage>? messages,
    TargetInfo? target,
    List<AncestorInfo>? ancestors,
    List<StateOwnerInfo>? stateOwners,
    List<Map<String, Object?>>? rounds,
    SiblingsInfo? Function()? siblings,
    String? Function()? subtree,
    ScreenshotInfo? Function()? screenshot,
    Map<String, Object?>? Function()? environment,
    Map<String, Object?>? Function()? finding,
    List<Map<String, Object?>>? checks,
    List<Map<String, Object?>>? tweaks,
    Map<String, Object?>? Function()? verification,
    Map<String, Object?>? Function()? trace,
    Map<String, Object?>? Function()? tape,
    List<String>? errors,
    List<String>? truncated,
  }) => Annotation(
    id: id,
    createdAt: createdAt,
    intent: intent ?? this.intent,
    comment: comment ?? this.comment,
    app: app,
    page: page,
    target: target ?? this.target,
    status: status ?? this.status,
    anchor: anchor == null ? this.anchor : anchor(),
    messages: messages ?? this.messages,
    ancestors: ancestors ?? this.ancestors,
    stateOwners: stateOwners ?? this.stateOwners,
    rounds: rounds ?? this.rounds,
    siblings: siblings == null ? this.siblings : siblings(),
    subtree: subtree == null ? this.subtree : subtree(),
    inherited: inherited,
    environment: environment == null ? this.environment : environment(),
    finding: finding == null ? this.finding : finding(),
    checks: checks ?? this.checks,
    tweaks: tweaks ?? this.tweaks,
    verification: verification == null ? this.verification : verification(),
    trace: trace == null ? this.trace : trace(),
    tape: tape == null ? this.tape : tape(),
    screenshot: screenshot == null ? this.screenshot : screenshot(),
    errors: errors ?? this.errors,
    truncated: truncated ?? this.truncated,
  );

  /// This note with [status].
  Annotation withStatus(NoteStatus status) => copyWith(status: status);

  /// This note with [shot] as its screenshot.
  Annotation withScreenshot(ScreenshotInfo? shot) =>
      copyWith(screenshot: () => shot);

  /// This note with [field] named in [errors].
  Annotation withError(String field) =>
      errors.contains(field) ? this : copyWith(errors: [...errors, field]);

  /// This note cut until its JSON is at most [maxBytes] UTF-8 bytes.
  ///
  /// Each step runs only while the note is still too large, least useful
  /// part first: the subtree, then long property values, then the sibling
  /// and state owner lists. The comment, the source and the rect are what the
  /// agent acts on; the comment is cut only as the last resort. Each part
  /// cut is named once in [truncated].
  Annotation fitToBudget({int maxBytes = maxPayloadBytes}) {
    var note = this;
    for (final (name, cut) in _budgetSteps) {
      if (note._bytes <= maxBytes) return note;
      final smaller = cut(note);
      if (smaller == null) continue;
      note = smaller._marked(name);
    }
    if (note._bytes <= maxBytes) return note;
    // Marked first: the name in `truncated` counts toward the budget too.
    return note._marked('comment')._fitComment(maxBytes) ?? note;
  }

  /// [json] (a [toJson] map, as the bridge stores it) as a note, or null
  /// when it has no id. A part of the wrong type is left empty, never thrown
  /// on. The screenshot's PNG is never read: the bridge keeps it beside the
  /// JSON.
  static Annotation? fromJson(Map<String, Object?> json) {
    final id = json.str('id');
    if (id == null) return null;
    return Annotation(
      id: id,
      createdAt: json.date('createdAt') ?? DateTime.utc(1970),
      status: NoteStatus.byName(json['status']) ?? _legacyStatus(json),
      intent:
          asEnum(AnnotationIntent.values, json['intent']) ??
          AnnotationIntent.improve,
      comment: json.str('comment') ?? '',
      app: AppInfo._fromJson(asJsonMap(json['app'])),
      page: PageInfo._fromJson(asJsonMap(json['page'])),
      environment: json.nonEmptyMap('environment'),
      finding: json.nonEmptyMap('finding'),
      checks: json.items('checks', _checkOrNull),
      tweaks: json.items('tweaks', _tweakOrNull),
      verification: json.nonEmptyMap('verification'),
      trace: json.nonEmptyMap(
        'trace',
        where: (t) => t['lines'] is List<Object?>,
      ),
      tape: json.nonEmptyMap('tape', where: (t) => t['id'] is String),
      target: TargetInfo._fromJson(asJsonMap(json['target'])),
      anchor: json.object('anchor', NoteAnchor.fromJson),
      messages: json.items('messages', NoteMessage.fromJson),
      ancestors: json.items('ancestors', AncestorInfo._fromJson),
      stateOwners: json.items('stateOwners', StateOwnerInfo._fromJson),
      rounds: json.items('rounds', _roundOrNull),
      siblings: SiblingsInfo._fromJson(json['siblings']),
      subtree: json.str('subtree'),
      inherited: json.object('inherited', InheritedInfo._fromJson),
      screenshot: json.object('screenshot', ScreenshotInfo._fromJson),
      errors: asStrings(json['errors']),
      truncated: asStrings(json['truncated']),
    );
  }

  /// The note as the Markdown a coding agent reads. Never holds the image.
  String toMarkdown() => markdownFor(this);

  /// The note as JSON. The screenshot's PNG goes in as base64 only with
  /// [includeScreenshotData], for a sink that wants the image (the HTTP
  /// sink). Without it, and in the size budget, the image is left out.
  Map<String, Object?> toJson({bool includeScreenshotData = false}) => {
    'schema': annotationSchema,
    'id': id,
    'createdAt': formatTimestamp(createdAt),
    'status': status.name,
    'intent': intent.name,
    'comment': comment,
    'app': app.toJson(),
    'page': page.toJson(),
    if (environment?.isNotEmpty ?? false) 'environment': environment,
    'finding': ?finding,
    if (checks.isNotEmpty) 'checks': checks,
    if (tweaks.isNotEmpty) 'tweaks': tweaks,
    'verification': ?verification,
    'trace': ?trace,
    'tape': ?tape,
    'target': target.toJson(),
    'anchor': anchor?.toJson(),
    'messages': [for (final m in messages) m.toJson()],
    'ancestors': [for (final a in ancestors) a.toJson()],
    if (stateOwners.isNotEmpty)
      'stateOwners': [for (final o in stateOwners) o.toJson()],
    if (rounds.isNotEmpty) 'rounds': rounds,
    'siblings': siblings?.toJson(),
    'subtree': subtree,
    'inherited': inherited?.toJson(),
    if (screenshot case final shot?)
      'screenshot': shot.toJson(includeData: includeScreenshotData),
    if (errors.isNotEmpty) 'errors': errors,
    if (truncated.isNotEmpty) 'truncated': truncated,
  };
}
