// Plain Dart: `package:http` works in the browser and in the VM.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../bridge/bridge_protocol.dart';
import '../model/annotation.dart';
import 'pinpoint_sink.dart';

/// Why an [HttpSink] did not deliver a note.
class HttpSinkException implements Exception {
  const HttpSinkException(this.message, {this.statusCode});

  final String message;

  /// The HTTP status, or null when no answer came.
  final int? statusCode;

  @override
  String toString() => message;
}

/// Posts each note as JSON, screenshot included as base64, for example to
/// the local bridge (`dart run pinpoint:bridge`).
class HttpSink extends PinPointSink {
  HttpSink(
    this.url, {
    this.name = 'HTTP',
    this.timeout = const Duration(seconds: 5),
    this._client,
  });

  /// The local bridge at `http://127.0.0.1:<port>/annotations`.
  ///
  /// [port] defaults to the `PINPOINT_BRIDGE_PORT` define, else 4747; it
  /// must match the bridge's `--port`. 127.0.0.1, not localhost: the bridge
  /// listens on IPv4 loopback only, and localhost can resolve to IPv6
  /// first.
  HttpSink.bridge({
    int port = configuredBridgePort,
    String name = 'bridge',
    Duration timeout = const Duration(seconds: 5),
    http.Client? client,
  }) : this(
         Uri.parse('http://127.0.0.1:$port$annotationsPath'),
         name: name,
         timeout: timeout,
         client: client,
       );

  /// Where notes are posted.
  final Uri url;

  @override
  final String name;

  /// How long a send may take before it fails.
  final Duration timeout;

  /// Null: a new client per request, closed after it.
  final http.Client? _client;

  /// The bridge's health check, beside [url]: `.../health`.
  Uri get healthUrl => url.resolve(healthPath.substring(1));

  /// Posts [note]. Throws an [HttpSinkException] on any status but 2xx, on
  /// a refused connection, and after [timeout].
  @override
  Future<void> send(Annotation note) async {
    final body = jsonEncode(note.toJson(includeScreenshotData: true));
    final http.Response response;
    try {
      response = await _use(
        (client) => client.post(
          url,
          headers: const {'content-type': 'application/json'},
          body: body,
        ),
        timeout,
      );
    } on TimeoutException {
      throw HttpSinkException(
        'no answer from ${url.authority} in ${timeout.inSeconds} s',
      );
    } on http.ClientException {
      // On web this is all the browser says, whatever the cause.
      throw HttpSinkException(
        'cannot reach ${url.authority}. Is `dart run pinpoint:bridge` '
        'running on that port?',
      );
    }
    final status = response.statusCode;
    if (status < 200 || status >= 300) {
      throw HttpSinkException(
        'HTTP $status: ${_reason(response.body)}',
        statusCode: status,
      );
    }
  }

  /// Whether [healthUrl] answers 200 within [timeout]. Never throws.
  Future<bool> isReachable({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      final response = await _use((client) => client.get(healthUrl), timeout);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<http.Response> _use(
    Future<http.Response> Function(http.Client client) request,
    Duration timeout,
  ) async {
    final client = _client ?? http.Client();
    try {
      return await request(client).timeout(timeout);
    } finally {
      // Closing an owned client also aborts a request that timed out.
      if (_client == null) client.close();
    }
  }

  /// The bridge's `{"error": ...}` message, else the start of [body].
  static String _reason(String body) {
    try {
      if (jsonDecode(body) case {'error': final String error}) return error;
    } on FormatException {
      // Not JSON; use the text.
    }
    final text = body.trim();
    return text.isEmpty ? 'no reason given' : clipText(text, 160);
  }
}
