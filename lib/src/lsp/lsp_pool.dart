import 'dart:async';

import 'package:ciach/src/log.dart';
import 'package:ciach/src/lsp/lsp_client.dart';
import 'package:ciach/src/lsp/outline.dart';
import 'package:ciach/src/lsp/semantic_tokens.dart';
import 'package:pro_lsp/pro_lsp.dart' as lsp;

final _log = Logger('ciach.lsp');

/// Several analysis servers behind one [LspClient] interface.
///
/// The Dart analysis server answers requests on a single isolate, so one
/// server keeps one core busy however many requests are in flight. A pool
/// runs [size] identical servers over the same root, opens every file in each,
/// and sends every request to the server with the fewest in flight. Each
/// server sees the same code, so any of them gives the same answer; the cost
/// is memory, since each one holds the whole analysis.
final class LspPool implements LspClient {
  LspPool._(this._servers) : _inFlight = List.filled(_servers.length, 0);

  final List<LspClient> _servers;

  /// Requests currently awaiting each server's answer, by index.
  final List<int> _inFlight;

  /// Where the next tie-break starts, so equally idle servers take turns.
  var _nextTie = 0;

  /// How many servers this pool runs.
  int get size => _servers.length;

  /// Spawns [size] analysis servers; see [LspClient.start].
  ///
  /// If any fails to start, the ones that did are shut down and the first
  /// error is rethrown.
  static Future<LspPool> start({
    required int size,
    String? dartExecutable,
  }) async {
    if (size < 1) {
      throw ArgumentError.value(size, 'size', 'must be positive');
    }
    final started = <LspClient>[];
    AsyncError? failure;
    await Future.wait([
      for (var i = 0; i < size; i++)
        LspClient.start(dartExecutable: dartExecutable).then(
          started.add,
          onError: (Object error, StackTrace stackTrace) =>
              failure ??= AsyncError(error, stackTrace),
        ),
    ]);
    if (failure case final failure?) {
      await Future.wait([for (final server in started) server.dispose()]);
      Error.throwWithStackTrace(failure.error, failure.stackTrace);
    }
    _log.fine('Started $size analysis servers.');
    return LspPool._(started);
  }

  /// Runs [request] on the least busy server.
  Future<T> _dispatch<T>(Future<T> Function(LspClient server) request) async {
    var best = _nextTie;
    for (var offset = 1; offset < _servers.length; offset++) {
      final i = (_nextTie + offset) % _servers.length;
      if (_inFlight[i] < _inFlight[best]) {
        best = i;
      }
    }
    _nextTie = (best + 1) % _servers.length;
    _inFlight[best]++;
    try {
      return await request(_servers[best]);
    } finally {
      _inFlight[best]--;
    }
  }

  /// Runs [action] on every server at once, rethrowing the first failure
  /// once all have settled.
  Future<void> _all(Future<void> Function(LspClient server) action) =>
      Future.wait([for (final server in _servers) action(server)]);

  @override
  String get dartExecutable => _servers.first.dartExecutable;

  /// Every server's stderr, each under a header naming it once there are more.
  @override
  String get stderr => _servers.length == 1
      ? _servers.single.stderr
      : [
          for (final (i, server) in _servers.indexed)
            if (server.stderr.isNotEmpty)
              '--- analysis server ${i + 1} ---\n${server.stderr}',
        ].join('\n');

  /// The same for every server, which all run the same SDK.
  @override
  SemanticTokensLegend get semanticTokensLegend =>
      _servers.first.semanticTokensLegend;

  @override
  Future<void> initialize(Uri rootUri) =>
      _all((server) => server.initialize(rootUri));

  @override
  Future<void> waitForAnalysisComplete({
    Duration timeout = const .new(minutes: 10),
  }) => _all((server) => server.waitForAnalysisComplete(timeout: timeout));

  /// Opens [uri] in every server, so each can answer for it.
  @override
  void didOpen(Uri uri, String text) {
    for (final server in _servers) {
      server.didOpen(uri, text);
    }
  }

  @override
  Future<Outline> outline(
    Uri uri, {
    Duration timeout = const .new(minutes: 2),
  }) => _dispatch((server) => server.outline(uri, timeout: timeout));

  @override
  Future<List<lsp.DocumentSymbol>> documentSymbol(Uri uri) =>
      _dispatch((server) => server.documentSymbol(uri));

  @override
  Future<List<lsp.Location>> references(
    Uri uri,
    lsp.Position position, {
    bool includeDeclaration = false,
  }) => _dispatch(
    (server) => server.references(
      uri,
      position,
      includeDeclaration: includeDeclaration,
    ),
  );

  @override
  Future<List<lsp.Location>> definition(Uri uri, lsp.Position position) =>
      _dispatch((server) => server.definition(uri, position));

  @override
  Future<List<SemanticToken>> semanticTokens(Uri uri, List<String> lines) =>
      _dispatch((server) => server.semanticTokens(uri, lines));

  @override
  Future<lsp.Location?> superOf(Uri uri, lsp.Position position) =>
      _dispatch((server) => server.superOf(uri, position));

  @override
  Future<List<lsp.Location>> implementations(Uri uri, lsp.Position position) =>
      _dispatch((server) => server.implementations(uri, position));

  @override
  Future<List<lsp.SelectionRange?>> selectionRanges(
    Uri uri,
    List<lsp.Position> positions,
  ) => _dispatch((server) => server.selectionRanges(uri, positions));

  @override
  Future<void> dispose() => _all((server) => server.dispose());
}
