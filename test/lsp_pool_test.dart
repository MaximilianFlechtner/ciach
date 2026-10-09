@TestOn('!windows')
library;

import 'dart:io';

import 'package:ciach/src/lsp/lsp_client.dart';
import 'package:ciach/src/lsp/lsp_pool.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = .systemTemp.createTempSync('ciach_lsp_pool_test');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  String fakeDart(String stderrText, int exitCode) {
    final script = File(
      p.join(tmp.path, 'dart'),
    )..writeAsStringSync('#!/bin/sh\necho "$stderrText" >&2\nexit $exitCode\n');
    Process.runSync('chmod', ['+x', script.path]);
    return script.path;
  }

  test('rejects an empty pool', () {
    expect(() => LspPool.start(size: 0), throwsArgumentError);
  });

  test('fails to start like a single server would', () {
    expect(
      LspPool.start(size: 3, dartExecutable: p.join(tmp.path, 'missing')),
      throwsA(isA<ProcessException>()),
    );
  });

  test('a server dying during initialize fails the pool, with every '
      "server's stderr", () async {
    final pool = await LspPool.start(
      size: 2,
      dartExecutable: fakeDart('no analysis today', 3),
    );
    addTearDown(pool.dispose);

    expect(pool.size, 2);
    await expectLater(
      pool.initialize(tmp.uri),
      throwsA(
        isA<AnalysisServerExitedException>().having(
          (e) => e.message,
          'message',
          allOf(contains('code 3'), contains('no analysis today')),
        ),
      ),
    );
    expect(
      pool.stderr,
      allOf(
        contains('--- analysis server 1 ---'),
        contains('--- analysis server 2 ---'),
      ),
    );
  });
}
