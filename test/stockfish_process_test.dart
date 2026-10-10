import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stockfish_engine_flutter/stockfish_engine_flutter.dart';

/// Sink target that records written bytes, or fails like a broken pipe.
class _FakeStdin implements StreamConsumer<List<int>> {
  final written = <int>[];
  bool failOnWrite = false;

  String get text => utf8.decode(written);

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      if (failOnWrite) throw const SocketException('Broken pipe');
      written.addAll(chunk);
    }
  }

  @override
  Future<void> close() async {}
}

class _FakeProcess implements Process {
  final _exit = Completer<int>();
  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final stdinTarget = _FakeStdin();
  late final IOSink _stdin = IOSink(stdinTarget);
  bool killed = false;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  IOSink get stdin => _stdin;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  int get pid => 4242;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!_exit.isCompleted) _exit.complete(-15);
    return true;
  }

  /// Simulates the engine exiting by itself.
  void exit(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  void emitLine(String line) => _stdout.add(utf8.encode('$line\n'));
}

void main() {
  late List<_FakeProcess> processes;

  setUp(() {
    processes = [];
    Stockfish.processLauncherForTesting = () async {
      final p = _FakeProcess();
      processes.add(p);
      return p;
    };
  });

  tearDown(() async {
    // `Stockfish` keeps a process-wide singleton; make sure no instance leaks
    // into the next test. The factory disposes any existing instance.
    Stockfish.processLauncherForTesting = () async => _FakeProcess();
    Stockfish().dispose();
    await Future<void>.delayed(Duration.zero);
    Stockfish.processLauncherForTesting = null;
  });

  Future<void> pumpEvents() => Future<void>.delayed(Duration.zero);

  test('becomes ready, relays stdout and writes stdin', () async {
    final engine = await stockfishAsync();
    expect(engine.state.value, StockfishState.ready);

    final lines = <String>[];
    engine.stdout.listen(lines.add);
    processes.single.emitLine('readyok');
    await pumpEvents();
    expect(lines, ['readyok']);

    engine.stdin = 'isready';
    await pumpEvents();
    expect(processes.single.stdinTarget.text, 'isready\n');

    engine.dispose();
    expect(engine.state.value, StockfishState.disposed);
    expect(processes.single.killed, isTrue);
  });

  test('exit code 0 that we did not initiate is treated as cleanup', () async {
    final engine = await stockfishAsync();
    processes.single.exit(0);
    await pumpEvents();
    expect(engine.state.value, StockfishState.disposed);
    expect(() => engine.stdin = 'uci', throwsStateError);
  });

  test('non-zero exit puts the engine in the error state', () async {
    final engine = await stockfishAsync();
    processes.single.exit(139);
    await pumpEvents();
    expect(engine.state.value, StockfishState.error);
  });

  test('a stale instance cleanup does not clear a newer instance', () async {
    final first = await stockfishAsync();
    // Factory disposes the existing instance, then installs a new one.
    final second = Stockfish();
    expect(first.state.value, StockfishState.disposed);
    await pumpEvents();
    await pumpEvents();
    expect(second.state.value, StockfishState.ready);

    // Late exit of the first process must not null out `second`.
    first.dispose(); // idempotent
    processes.first.exit(1);
    await pumpEvents();

    expect(second.state.value, StockfishState.ready);
    await expectLater(stockfishAsync(), throwsStateError);

    second.dispose();
    await pumpEvents();
    // Slot is free again.
    final third = await stockfishAsync();
    expect(third.state.value, StockfishState.ready);
    third.dispose();
  });

  test('dispose is idempotent per instance', () async {
    final engine = await stockfishAsync();
    engine.dispose();
    engine.dispose();
    expect(engine.state.value, StockfishState.disposed);
  });

  test('broken pipe on stdin.done does not raise an unhandled error', () async {
    final engine = await stockfishAsync();
    final process = processes.single;
    process.stdinTarget.failOnWrite = true;

    // The error surfaces asynchronously on stdin.done; the test zone would
    // fail the test if it were unhandled.
    engine.stdin = 'uci';
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(process.killed, isFalse);
    engine.dispose();
  });

  test('stdin write failure is caught and cleans up', () async {
    final engine = await stockfishAsync();
    final process = processes.single;
    // Closing the sink makes the next writeln throw a StateError synchronously.
    unawaited(process.stdin.close());
    await pumpEvents();

    engine.stdin = 'uci';
    expect(engine.state.value, StockfishState.error);
    expect(process.killed, isTrue);
  });

  test('launch failure reports error and fails stockfishAsync', () async {
    Stockfish.processLauncherForTesting =
        () async => throw StateError('no binary');
    await expectLater(stockfishAsync(), throwsStateError);
    // The global slot is released, so a new engine can be created.
    Stockfish.processLauncherForTesting = () async {
      final p = _FakeProcess();
      processes.add(p);
      return p;
    };
    final engine = await stockfishAsync();
    expect(engine.state.value, StockfishState.ready);
    engine.dispose();
  });

  test('dispose while launching kills the late process', () async {
    final gate = Completer<void>();
    Stockfish.processLauncherForTesting = () async {
      await gate.future;
      final p = _FakeProcess();
      processes.add(p);
      return p;
    };
    final future = stockfishAsync();
    // Not ready yet; dispose through the factory path.
    final replacement = Stockfish();
    gate.complete();
    await expectLater(future, throwsStateError);
    await pumpEvents();
    expect(processes.first.killed, isTrue);
    replacement.dispose();
  });
}
