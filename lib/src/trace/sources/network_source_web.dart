import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../../core/hook_registry.dart';
import '../../model/tape.dart' show NetExchange;
import '../../tape/net_matcher.dart';
import '../net_record.dart';
import 'network_source.dart';

/// `window.fetch` and `XMLHttpRequest` on web (PLAN-v2 Milestone 14, step
/// 11). `package:http` uses `fetch` (`browser_client.dart:36`); Dio uses
/// XHR (`dio_web_adapter`). Both are needed.
///
/// Wasm builds use the same `dart:js_interop` calls. Whether the wasm
/// runtime's `package:http` calls the patched `fetch` is a manual check
/// (watch out for).
///
/// Watch out for: WebSockets are not hooked, so they are neither recorded
/// nor answered from a tape: during a replay they reach the server. A
/// server-sent event stream is recorded as `unsupported` and passes
/// through (`NetRecorder._skipReason`, `NetReplay.answer`).
NetworkHooks createPlatformNetworkHooks() => _WebNetworkHooks();

bool _sameJs(JSAny? a, JSAny? b) =>
    a == null ? b == null : (b != null && a.strictEquals(b).toDart);

class _WebNetworkHooks implements NetworkHooks {
  NetRecorder? _net;

  GlobalSlot<JSAny?>? _fetch;
  GlobalSlot<JSAny?>? _open;
  GlobalSlot<JSAny?>? _send;
  GlobalSlot<JSAny?>? _header;

  late final JSFunction _fetchJs = _onFetch.toJS;
  late final JSFunction _openJs = _onOpen.toJSCaptureThis;
  late final JSFunction _sendJs = _onSend.toJSCaptureThis;
  late final JSFunction _headerJs = _onHeader.toJSCaptureThis;

  /// What `open` and `setRequestHeader` learned about each XHR, until its
  /// `send`. A JS `WeakMap`: it adds nothing the app can see on the object.
  late final JSObject _xhrs = (globalContext['WeakMap']! as JSFunction)
      .callAsConstructor<JSObject>();

  @override
  bool install(NetRecorder net, HookRegistry hooks) {
    _net = net;
    var any = false;
    if (globalContext['fetch'].isA<JSFunction>()) {
      (_fetch ??= hooks.slot<JSAny?>(
        key: #pinpointFetch,
        read: () => globalContext['fetch'],
        write: (value) => globalContext['fetch'] = value,
        same: _sameJs,
      )).set(_fetchJs);
      any = true;
    }
    final xhr = globalContext['XMLHttpRequest'];
    if (xhr.isA<JSFunction>()) {
      final proto = (xhr! as JSObject)['prototype']! as JSObject;
      GlobalSlot<JSAny?> slot(String name, Symbol key) => hooks.slot<JSAny?>(
        key: key,
        read: () => proto[name],
        write: (value) => proto[name] = value,
        same: _sameJs,
      );
      (_open ??= slot('open', #pinpointXhrOpen)).set(_openJs);
      (_send ??= slot('send', #pinpointXhrSend)).set(_sendJs);
      (_header ??= slot('setRequestHeader', #pinpointXhrHeader)).set(_headerJs);
      any = true;
    }
    return any;
  }

  @override
  void uninstall() {
    _net = null;
    _fetch?.release();
    _open?.release();
    _send?.release();
    _header?.release();
  }

  // ---- fetch ----

  JSAny? _onFetch(JSAny? input, [JSAny? init]) {
    final original = _fetch?.previous;
    if (original == null || !original.isA<JSFunction>()) return null;
    NetCall? call;
    NetAnswer? answer;
    final net = _net;
    if (net != null) {
      try {
        final request = _parseFetch(input, init);
        // Decided before the request event: a replay knows the answer
        // before anything is sent.
        answer = net.replayAnswer(
          method: request.method,
          url: request.url,
          body: request.bytes,
        );
        call = net.request(
          via: 'fetch',
          method: request.method,
          url: request.url,
          headers: request.headers,
          body: request.bytes,
          bodyKind: request.kind,
          bodySize: request.size,
        );
      } catch (_) {
        // The recorder only observes (rule 11): the request goes on.
      }
    }
    final JSAny? result;
    switch (answer) {
      case ServeAnswer():
        // Replay (PLAN-v2 Milestone 15, step 8): no request leaves the
        // page. The app gets a real `Response`, made from the tape.
        result = _served(answer);
      case FailAnswer(:final reason):
        // As the browser fails a fetch: a rejected promise with a
        // TypeError, which package:http turns into a ClientException.
        result = _rejected(reason);
      default:
        // The app gets the very promise the browser's fetch returns: the
        // same response object, the same timing.
        result = (original as JSFunction).callAsFunction(
          globalContext,
          input,
          init,
        );
    }
    if (result != null && result.isA<JSPromise>()) {
      try {
        _follow(call, result as JSObject, _orderOf(answer));
      } catch (_) {}
    }
    return result;
  }

  /// A promise for [answer]'s `Response`, after its delay. The `url` of a
  /// made `Response` is empty: an app that reads `response.url` sees the
  /// difference.
  JSObject _served(ServeAnswer answer) {
    final executor = (JSFunction resolve, JSFunction reject) {
      Timer(answer.delay, () {
        try {
          resolve.callAsFunction(null, _response(answer));
        } catch (error) {
          reject.callAsFunction(null, _typeError('$error'));
        }
      });
    }.toJS;
    return (globalContext['Promise']! as JSFunction)
        .callAsConstructor<JSObject>(executor);
  }

  JSObject _rejected(String reason) => (globalContext['Promise']! as JSObject)
      .callMethod<JSObject>('reject'.toJS, _typeError(reason));

  static JSObject _typeError(String message) =>
      (globalContext['TypeError']! as JSFunction).callAsConstructor<JSObject>(
        message.toJS,
      );

  /// A `Response` with the tape's status, headers and body.
  JSObject _response(ServeAnswer answer) {
    final exchange = answer.exchange;
    final status = exchange.status!;
    final headers = JSObject();
    for (final MapEntry(:key, :value) in _servedHeaders(exchange)) {
      headers[key] = value.toJS;
    }
    final init = JSObject()
      ..['status'] = status.toJS
      ..['headers'] = headers;
    // A body is not allowed with these statuses.
    const noBody = {101, 103, 204, 205, 304};
    return (globalContext['Response']! as JSFunction)
        .callAsConstructor<JSObject>(
          noBody.contains(status) ? null : answer.body.toJS,
          init,
        );
  }

  _Request _parseFetch(JSAny? input, JSAny? init) {
    var method = 'GET';
    var url = '';
    final headers = <String, String>{};
    if (input != null && input.typeofEquals('string')) {
      url = (input as JSString).toDart;
    } else if (input != null && input.instanceOfString('Request')) {
      final request = input as JSObject;
      url = _str(request['url']);
      method = _str(request['method']);
      headers.addAll(_headersOf(request['headers']));
    } else if (input != null) {
      url = _str((input as JSObject).callMethod<JSAny?>('toString'.toJS));
    }
    JSAny? body;
    if (init != null && init.typeofEquals('object')) {
      final options = init as JSObject;
      final m = options['method'];
      if (m != null && m.typeofEquals('string')) method = _str(m);
      headers.addAll(_headersOf(options['headers']));
      body = options['body'];
    }
    final (bytes, kind, size) = _bodyOf(body);
    return _Request(method, url, headers, bytes, kind, size);
  }

  /// Reads the answer as the promise settles. Our `then` is attached before
  /// the app gets the promise, so it runs first, and the clone is made
  /// before the app reads the body. During a replay, the tape's answer [n]
  /// counts as delivered then.
  void _follow(NetCall? call, JSObject promise, int? n) {
    void delivered() {
      if (n != null) _net?.replay?.delivered(n);
    }

    promise.callMethod<JSAny?>(
      'then'.toJS,
      ((JSAny? value) {
        try {
          if (call != null) _onFetchResponse(call, value);
        } catch (_) {}
        delivered();
      }).toJS,
      ((JSAny? error) {
        try {
          call?.fail(_errorText(error));
        } catch (_) {}
        delivered();
      }).toJS,
    );
  }

  void _onFetchResponse(NetCall call, JSAny? value) {
    if (value == null || !value.typeofEquals('object')) return;
    final response = value as JSObject;
    final status = response['status'];
    final read = call.respond(
      status: status.isA<JSNumber>() ? (status! as JSNumber).toDartInt : 0,
      headers: _headersOf(response['headers']),
    );
    if (!read) return;
    // Watch out for: a body is a stream, and reading it to hash it must
    // not consume it for the app. Read a clone: the browser tees the
    // stream, and the app's branch is untouched.
    final clone = response.callMethod<JSObject>('clone'.toJS);
    final body = clone['body'];
    if (body == null || !body.typeofEquals('object')) {
      call.end();
      return;
    }
    _read(call, (body as JSObject).callMethod<JSObject>('getReader'.toJS));
  }

  void _read(NetCall call, JSObject reader) {
    reader
        .callMethod<JSObject>('read'.toJS)
        .callMethod<JSAny?>(
          'then'.toJS,
          ((JSObject result) {
            try {
              final done = result['done'];
              if (done.isA<JSBoolean>() && (done! as JSBoolean).toDart) {
                call.end();
                return;
              }
              final value = result['value'];
              if (value.isA<JSUint8Array>()) {
                call.chunk((value! as JSUint8Array).toDart);
              }
              _read(call, reader);
            } catch (_) {
              call.end(notRead: 'the read failed');
            }
          }).toJS,
          ((JSAny? _) {
            call.end(notRead: 'the read failed');
          }).toJS,
        );
  }

  // ---- XMLHttpRequest ----

  JSAny? _onOpen(
    JSObject self,
    JSAny? method,
    JSAny? url, [
    JSAny? async,
    JSAny? user,
    JSAny? password,
  ]) {
    try {
      if (_net != null) {
        _xhrs.callMethod<JSAny?>(
          'set'.toJS,
          self,
          _Xhr(
            _str(method),
            _str(url),
            async: async == null || async.dartify() != false,
          ).toJSBox,
        );
      }
    } catch (_) {}
    final original = _open?.previous;
    if (original == null || !original.isA<JSFunction>()) return null;
    final open = original as JSFunction;
    // `open(m, u)` is async; `open(m, u, undefined)` is not: keep the
    // caller's arity. An explicit null or undefined counts as left out.
    if (async == null && user == null && password == null) {
      return open.callAsFunction(self, method, url);
    }
    if (user == null && password == null) {
      return open.callAsFunction(self, method, url, async);
    }
    return open.callMethodVarArgs<JSAny?>('call'.toJS, [
      self,
      method,
      url,
      async,
      user,
      password,
    ]);
  }

  JSAny? _onHeader(JSObject self, JSAny? name, JSAny? value) {
    try {
      final box = _xhrs.callMethod<JSAny?>('get'.toJS, self);
      if (box != null && box.typeofEquals('object')) {
        final xhr = (box as JSBoxedDartObject).toDart;
        if (xhr is _Xhr) xhr.headers[_str(name)] = _str(value);
      }
    } catch (_) {}
    final original = _header?.previous;
    if (original == null || !original.isA<JSFunction>()) return null;
    return (original as JSFunction).callAsFunction(self, name, value);
  }

  JSAny? _onSend(JSObject self, [JSAny? body]) {
    final net = _net;
    NetAnswer? answer;
    if (net != null) {
      try {
        answer = _beginXhr(net, self, body);
      } catch (_) {}
    }
    final original = _send?.previous;
    if (original == null || !original.isA<JSFunction>()) return null;
    final send = original as JSFunction;
    final xhr = _xhrOf(self);
    switch (answer) {
      case ServeAnswer() when xhr != null:
        _serveXhr(self, xhr, answer, send);
        return null;
      case FailAnswer() when xhr != null:
        // A scheme the browser cannot load: the XHR fails with a network
        // error, as with the server off. No request leaves the page.
        _reopen(self, 'GET', 'pinpoint-replay:no-answer', xhr.async);
        return send.callAsFunction(self);
      default:
        return send.callAsFunction(self, body);
    }
  }

  _Xhr? _xhrOf(JSObject self) {
    final box = _xhrs.callMethod<JSAny?>('get'.toJS, self);
    if (box == null || !box.typeofEquals('object')) return null;
    final xhr = (box as JSBoxedDartObject).toDart;
    return xhr is _Xhr ? xhr : null;
  }

  /// Opens [self] again through the browser's own `open`, not ours, so
  /// what our `open` learned stays.
  void _reopen(JSObject self, String method, String url, bool async) {
    final open = _open?.previous;
    if (open == null || !open.isA<JSFunction>()) return;
    (open as JSFunction).callAsFunction(
      self,
      method.toJS,
      url.toJS,
      async.toJS,
    );
  }

  /// Serves an XHR from the tape: opened again on a blob URL of the body,
  /// so the browser delivers it with every event the app listens to. A
  /// blob always answers 200, so `status`, `statusText`, `responseURL` and
  /// the header reads are set on this one object to the tape's values.
  void _serveXhr(JSObject self, _Xhr xhr, ServeAnswer answer, JSFunction send) {
    final exchange = answer.exchange;
    final headers = _servedHeaders(exchange).toList();
    final type = [
      for (final MapEntry(:key, :value) in headers)
        if (key.toLowerCase() == 'content-type') value,
    ].firstOrNull;
    final blobInit = JSObject();
    if (type != null) blobInit['type'] = type.toJS;
    final blob = (globalContext['Blob']! as JSFunction)
        .callAsConstructor<JSObject>(<JSAny?>[answer.body.toJS].toJS, blobInit);
    final urlApi = globalContext['URL']! as JSObject;
    final blobUrl = urlApi.callMethod<JSString>('createObjectURL'.toJS, blob);
    _reopen(self, 'GET', blobUrl.toDart, xhr.async);
    final object = globalContext['Object']! as JSObject;
    void define(String name, JSObject descriptor) {
      descriptor['configurable'] = true.toJS;
      object.callMethod<JSAny?>(
        'defineProperty'.toJS,
        self,
        name.toJS,
        descriptor,
      );
    }

    final status = exchange.status!;
    define(
      'status',
      JSObject()
        ..['get'] = (() {
          final state = self['readyState'];
          final ready =
              state.isA<JSNumber>() && (state! as JSNumber).toDartInt >= 2;
          return (ready ? status : 0).toJS;
        }).toJS,
    );
    define('statusText', JSObject()..['value'] = ''.toJS);
    define('responseURL', JSObject()..['value'] = xhr.url.toJS);
    final all = [
      for (final MapEntry(:key, :value) in headers)
        '${key.toLowerCase()}: $value',
    ].join('\r\n');
    define(
      'getAllResponseHeaders',
      JSObject()..['value'] = (() => all.toJS).toJS,
    );
    define(
      'getResponseHeader',
      JSObject()
        ..['value'] = ((JSAny? name) {
          final wanted = _str(name).toLowerCase();
          for (final MapEntry(:key, :value) in headers) {
            if (key.toLowerCase() == wanted) return value.toJS;
          }
          return null;
        }).toJS,
    );
    self.callMethod<JSAny?>(
      'addEventListener'.toJS,
      'loadend'.toJS,
      ((JSAny? _) {
        urlApi.callMethod<JSAny?>('revokeObjectURL'.toJS, blobUrl);
      }).toJS,
      {'once': true}.jsify(),
    );
    if (!xhr.async) {
      // A synchronous XHR cannot wait.
      send.callAsFunction(self);
      return;
    }
    Timer(answer.delay, () => send.callAsFunction(self));
  }

  /// Starts recording an XHR and, during a replay, decides its answer.
  NetAnswer? _beginXhr(NetRecorder net, JSObject self, JSAny? body) {
    final xhr = _xhrOf(self);
    if (xhr == null) return null;
    final (bytes, kind, size) = _bodyOf(body);
    final answer = net.replayAnswer(
      method: xhr.method,
      url: xhr.url,
      body: bytes,
    );
    final n = _orderOf(answer);
    final call = net.request(
      via: 'xhr',
      method: xhr.method,
      url: xhr.url,
      headers: xhr.headers,
      body: bytes,
      bodyKind: kind,
      bodySize: size,
    );
    if (call == null && n == null) return answer;
    String? failure;
    final once = {'once': true}.jsify();
    void on(String type, void Function() handler) => self.callMethod<JSAny?>(
      'addEventListener'.toJS,
      type.toJS,
      ((JSAny? _) {
        try {
          handler();
        } catch (_) {}
      }).toJS,
      once,
    );
    on('error', () => failure ??= 'network error');
    on('abort', () => failure ??= 'aborted');
    on('timeout', () => failure ??= 'timeout');
    on('loadend', () {
      if (call != null) {
        final reason = failure;
        if (reason != null) {
          call.fail(answer is FailAnswer ? answer.reason : reason);
        } else {
          _onXhrLoad(call, self);
        }
      }
      if (n != null) _net?.replay?.delivered(n);
    });
    return answer;
  }

  // Watch out for: for XHR, read `response` after `load`. The browser has
  // the whole body then, and reading it takes nothing from the app.
  void _onXhrLoad(NetCall call, JSObject self) {
    final status = self['status'];
    final read = call.respond(
      status: status.isA<JSNumber>() ? (status! as JSNumber).toDartInt : 0,
      headers: _parseHeaders(
        _str(self.callMethod<JSAny?>('getAllResponseHeaders'.toJS)),
      ),
    );
    if (!read) return;
    final type = _str(self['responseType']);
    if (type.isEmpty || type == 'text') {
      call
        ..chunk(utf8.encode(_str(self['responseText'])))
        ..end();
    } else if (type == 'arraybuffer') {
      final response = self['response'];
      if (response.isA<JSArrayBuffer>()) {
        call.chunk((response! as JSArrayBuffer).toDart.asUint8List());
      }
      call.end();
    } else {
      call.end(notRead: 'responseType $type');
    }
  }
}

/// What an XHR's `open` and `setRequestHeader` said.
class _Xhr {
  _Xhr(this.method, this.url, {this.async = true});

  final String method;
  final String url;

  /// False for `open(m, u, false)`: a synchronous request.
  final bool async;
  final Map<String, String> headers = <String, String>{};
}

/// A fetch request as the recorder and the matcher need it.
class _Request {
  _Request(
    this.method,
    this.url,
    this.headers,
    this.bytes,
    this.kind,
    this.size,
  );

  final String method;
  final String url;
  final Map<String, String> headers;
  final List<int>? bytes;
  final String? kind;
  final int? size;
}

/// The order number in the tape of the exchange [answer] stands for.
int? _orderOf(NetAnswer? answer) => switch (answer) {
  ServeAnswer(:final exchange) => exchange.n,
  PassAnswer(:final exchange) => exchange?.n,
  FailAnswer(:final exchange) => exchange?.n,
  null => null,
};

/// The tape's answer headers that a made answer carries. The body is served
/// decoded and whole, so the encoding and length go; a masked cookie is not
/// set again.
Iterable<MapEntry<String, String>> _servedHeaders(NetExchange exchange) =>
    exchange.headers.entries.where(
      (e) => !const {
        'content-encoding',
        'content-length',
        'transfer-encoding',
        'set-cookie',
      }.contains(e.key.toLowerCase()),
    );

String _str(JSAny? value) {
  if (value == null) return '';
  if (value.typeofEquals('string')) return (value as JSString).toDart;
  return '${value.dartify() ?? ''}';
}

String _errorText(JSAny? error) {
  if (error == null) return 'failed';
  if (error.typeofEquals('object')) {
    final object = error as JSObject;
    final name = _str(object['name']);
    final message = _str(object['message']);
    if (name.isNotEmpty || message.isNotEmpty) return '$name: $message';
  }
  return _str(error);
}

/// Headers from a `Headers` object, an array of pairs, or a plain object.
Map<String, String> _headersOf(JSAny? headers) {
  final out = <String, String>{};
  if (headers == null || !headers.typeofEquals('object')) return out;
  if (headers.instanceOfString('Headers')) {
    (headers as JSObject).callMethod<JSAny?>(
      'forEach'.toJS,
      ((JSAny? value, JSAny? key) {
        out[_str(key)] = _str(value);
      }).toJS,
    );
    return out;
  }
  final array = globalContext['Array']! as JSObject;
  if (array.callMethod<JSBoolean>('isArray'.toJS, headers).toDart) {
    for (final pair in (headers as JSArray<JSAny?>).toDart) {
      if (pair == null || !pair.typeofEquals('object')) continue;
      final items = (pair as JSArray<JSAny?>).toDart;
      if (items.length >= 2) out[_str(items[0])] = _str(items[1]);
    }
    return out;
  }
  final entries = (globalContext['Object']! as JSObject)
      .callMethod<JSArray<JSAny?>>('entries'.toJS, headers);
  for (final pair in entries.toDart) {
    final items = (pair! as JSArray<JSAny?>).toDart;
    out[_str(items[0])] = _str(items[1]);
  }
  return out;
}

/// `getAllResponseHeaders()` text as a map.
Map<String, String> _parseHeaders(String text) => {
  for (final line in const LineSplitter().convert(text))
    if (line.indexOf(':') case final i when i > 0)
      line.substring(0, i).trim(): line.substring(i + 1).trim(),
};

/// A request body's bytes when they are known; otherwise its kind and,
/// for a `Blob`, its size.
(List<int>?, String?, int?) _bodyOf(JSAny? body) {
  if (body == null) return (null, null, null);
  if (body.typeofEquals('string')) {
    return (utf8.encode((body as JSString).toDart), null, null);
  }
  if (!body.typeofEquals('object')) return (null, null, null);
  if (body.instanceOfString('ArrayBuffer')) {
    return ((body as JSArrayBuffer).toDart.asUint8List(), null, null);
  }
  final arrayBuffer = globalContext['ArrayBuffer']! as JSObject;
  if (arrayBuffer.callMethod<JSBoolean>('isView'.toJS, body).toDart) {
    final view = body as JSObject;
    final bytes = (globalContext['Uint8Array']! as JSFunction)
        .callAsConstructor<JSUint8Array>(
          view['buffer'],
          view['byteOffset'],
          view['byteLength'],
        );
    return (bytes.toDart, null, null);
  }
  if (body.instanceOfString('URLSearchParams')) {
    final text = _str((body as JSObject).callMethod<JSAny?>('toString'.toJS));
    return (utf8.encode(text), null, null);
  }
  if (body.instanceOfString('Blob')) {
    final size = (body as JSObject)['size'];
    return (
      null,
      'blob',
      size.isA<JSNumber>() ? (size! as JSNumber).toDartInt : null,
    );
  }
  if (body.instanceOfString('FormData')) return (null, 'form', null);
  return (null, 'stream', null);
}
