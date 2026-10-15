import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import 'android_executable.dart';
import 'ffi.dart';
import 'stockfish_state.dart';

final _logger = Logger('Stockfish');

/// Channel implemented by the Android plugin (StockfishPlugin.java).
const _channel = MethodChannel('stockfish_engine_flutter');

void _debugLog(String message) {
  debugPrint('[STOCKFISH] $message');
  _logger.info(message);
}

/// Android and macOS run Stockfish as a child process and talk UCI over its
/// stdin/stdout. iOS (no process spawning allowed) uses the FFI path.
bool get _usesProcessBackend =>
    Stockfish.processLauncherForTesting != null ||
    Platform.isAndroid ||
    Platform.isMacOS;

/// A wrapper for the Stockfish engine.
///
/// * Android: separate process (`libstockfish_bin.so` or
///   `libstockfish_bin_compat.so` in `nativeLibraryDir`, chosen from
///   `/proc/cpuinfo`; the NNUE nets live in `libstockfish_nets.so`).
/// * macOS: separate process (bundled or locally built binary).
/// * iOS: in-process through Dart FFI.
class Stockfish {
  final Completer<Stockfish>? completer;

  final _state = _StockfishState();
  final _stdoutController = StreamController<String>.broadcast();
  final _mainPort = ReceivePort();
  final _stdoutPort = ReceivePort();

  StreamSubscription? _mainSubscription;
  StreamSubscription? _stdoutSubscription;
  Process? _process;

  /// Set once [_cleanUp] has run for *this* instance. Cleanup is idempotent
  /// per instance and independent of the global [_instance].
  bool _disposed = false;

  /// Test seam: when set, replaces the platform-specific executable lookup and
  /// `Process.start`, and forces the process backend on any host.
  @visibleForTesting
  static Future<Process> Function()? processLauncherForTesting;

  Stockfish._({this.completer}) {
    if (_usesProcessBackend) {
      _startProcessBackend();
      return;
    }

    _mainSubscription = _mainPort.listen((message) {
      if (message != 0) {
        _cleanUp(message is int ? message : 1);
      }
    });
    _stdoutSubscription = _stdoutPort.listen((message) {
      if (message is String) {
        _logger.finest('The stdout isolate sent $message');
        _stdoutController.sink.add(message);
      } else {
        _logger.fine('The stdout isolate sent $message');
      }
    });
    compute(_spawnIsolates, [_mainPort.sendPort, _stdoutPort.sendPort]).then(
      (success) {
        final state = success ? StockfishState.ready : StockfishState.error;
        _logger.fine('The init isolate reported $state');
        _state._setValue(state);
        if (state == StockfishState.ready) {
          completer?.complete(this);
        }
      },
      onError: (error) {
        _logger.severe('The init isolate encountered an error $error');
        _cleanUp(1);
      },
    );
  }

  static Stockfish? _instance;

  /// Creates a C++ engine.
  ///
  /// This may throws a [StateError] if an active instance is being used.
  /// Owner must [dispose] it before a new instance can be created.
  factory Stockfish() {
    if (_instance != null) {
      _logger.warning(
        'Existing Stockfish instance found. Disposing before creating a new one.',
      );
      _instance!.dispose();
    } else if (!_usesProcessBackend) {
      // If we got here due to a Hot Restart, _instance will be null in Dart,
      // but the native side might still be running. Kill it.
      try {
        nativeDispose();
      } catch (e) {
        _logger.warning('Failed to pre-emptively kill native engine: $e');
      }
    }

    _instance = Stockfish._();
    return _instance!;
  }

  /// The current state of the underlying C++ engine.
  ValueListenable<StockfishState> get state => _state;

  /// The standard output stream.
  Stream<String> get stdout => _stdoutController.stream;

  /// The standard input sink.
  set stdin(String line) {
    final stateValue = _state.value;
    if (stateValue != StockfishState.ready) {
      throw StateError('Stockfish is not ready ($stateValue)');
    }

    if (_usesProcessBackend) {
      final process = _process;
      if (process == null) {
        throw StateError('Stockfish process is not available');
      }
      try {
        process.stdin.writeln(line);
      } catch (error) {
        // e.g. the sink is already closed because the process died.
        _debugLog('Failed to write to Stockfish stdin: $error');
        _cleanUp(1);
      }
      return;
    }

    final pointer = '$line\n'.toNativeUtf8();
    nativeStdinWrite(pointer);
    calloc.free(pointer);
  }

  /// Stops the C++ engine.
  ///
  /// WARNING: Avoid sending 'quit' synchronously on the UI thread as it
  /// can block indefinitely if the native pipe is full.
  void dispose() {
    _cleanUp(0);
  }

  void _cleanUp(int exitCode) {
    if (_disposed) return;
    _disposed = true;

    _logger.info('Cleaning up Stockfish instance (exitCode: $exitCode)');

    try {
      if (_usesProcessBackend) {
        final process = _process;
        _process = null;
        if (process != null) {
          try {
            process.stdin.writeln('quit');
            unawaited(process.stdin.close().catchError((Object _) {}));
          } catch (error) {
            _logger.fine('Could not send quit to Stockfish: $error');
          }
          process.kill();
        }
      } else {
        nativeDispose();
      }
    } catch (e) {
      _logger.warning('Failed to dispose native engine during cleanup: $e');
    }

    if (!_stdoutController.isClosed) {
      _stdoutController.close();
    }

    _mainSubscription?.cancel();
    _stdoutSubscription?.cancel();

    _state._setValue(
      exitCode == 0 ? StockfishState.disposed : StockfishState.error,
    );

    // Don't let a stale instance clear a newer one.
    if (identical(_instance, this)) {
      _instance = null;
    }

    // Don't leave stockfishAsync() callers hanging if we never became ready.
    final pending = completer;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(
        StateError(
          'Stockfish stopped before it was ready (exitCode: $exitCode)',
        ),
      );
    }
  }
}

extension on Stockfish {
  void _startProcessBackend() {
    Future<void>(() async {
      try {
        _debugLog('Starting Stockfish process backend');
        final Process process;
        final testLauncher = Stockfish.processLauncherForTesting;
        if (testLauncher != null) {
          process = await testLauncher();
        } else if (Platform.isAndroid) {
          final dir = await _androidNativeLibraryDir();
          final path = await _androidExecutablePath(dir);
          // libstockfish_nets.so (DT_NEEDED) is found through the executable's
          // DT_RUNPATH=$ORIGIN; LD_LIBRARY_PATH is a belt-and-braces fallback.
          final inherited = Platform.environment['LD_LIBRARY_PATH'];
          final libraryPath = inherited == null || inherited.isEmpty
              ? dir
              : '$dir:$inherited';
          _debugLog('Launching Stockfish executable at $path');
          process = await Process.start(
            path,
            const [],
            environment: {'LD_LIBRARY_PATH': libraryPath},
          );
        } else {
          final executable = await _ensureMacOSExecutable();
          _debugLog('Launching Stockfish executable at ${executable.path}');
          process = await Process.start(
            executable.path,
            const [],
            workingDirectory: executable.parent.path,
          );
        }
        // Attach immediately: a broken pipe surfaces asynchronously on
        // `stdin.done` and would otherwise be an unhandled error.
        unawaited(
          process.stdin.done.catchError((Object error) {
            _debugLog('Stockfish stdin error: $error');
          }),
        );

        if (_disposed) {
          // dispose() ran while the process was being launched.
          process.kill();
          return;
        }
        _process = process;

        // Any exit we did not initiate (including code 0) means the engine is
        // gone. Exits caused by _cleanUp() are ignored via [_disposed].
        unawaited(
          process.exitCode.then((code) {
            _debugLog(
              _disposed
                  ? 'Stockfish process exited (exitCode: $code)'
                  : 'Stockfish process exited unexpectedly (exitCode: $code)',
            );
            _cleanUp(code);
          }),
        );

        _stdoutSubscription = process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(_stdoutController.add);

        process.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) => _debugLog('stderr: $line'));

        _state._setValue(StockfishState.ready);
        completer?.complete(this);
      } catch (error) {
        _debugLog('Failed to start Stockfish process: $error');
        _cleanUp(1);
      }
    });
  }
}

Future<String> _androidNativeLibraryDir() async {
  final dir = await _channel.invokeMethod<String>('nativeLibraryDir');
  if (dir == null || dir.isEmpty) {
    throw StateError('The plugin did not return nativeLibraryDir');
  }
  return dir;
}

/// Picks the engine build for this CPU (see android_executable.dart): the
/// dot-product build only if every `Features` line of /proc/cpuinfo has
/// `asimddp`, else the compat build; falls back to whichever one exists.
Future<String> _androidExecutablePath(String dir) async {
  String cpuinfo;
  try {
    cpuinfo = await File('/proc/cpuinfo').readAsString();
  } catch (error) {
    _debugLog('Could not read /proc/cpuinfo ($error); assuming no dotprod');
    cpuinfo = '';
  }
  final preference = androidExecutablePreference(cpuinfo);
  final name = selectAndroidExecutable(
    cpuinfo,
    (name) => File('$dir/$name').existsSync(),
  );
  if (name == null) {
    throw StateError(
      '$dir/${preference.first} does not exist. The app must be installed '
      'with android:extractNativeLibs="true" so the Stockfish executable '
      'is extracted to nativeLibraryDir.',
    );
  }
  final fallback = name == preference.first
      ? ''
      : ' (fallback: ${preference.first} is missing)';
  _debugLog(
    'CPU has dotprod (asimddp on every core): ${cpuinfoHasDotProd(cpuinfo)}; '
    'using $name$fallback',
  );
  return '$dir/$name';
}

Future<File> _ensureMacOSExecutable() async {
  final bundledSourceDir = await _findBundledMacOSSourceDir();
  if (!await bundledSourceDir.exists()) {
    throw StateError(
      'Bundled Stockfish source directory not found at ${bundledSourceDir.path}',
    );
  }

  final buildRoot = Directory(
    '${Directory.systemTemp.path}/stockfish_engine_flutter_macos',
  );
  final sourceDir = Directory('${buildRoot.path}/src');
  final executable = File('${sourceDir.path}/stockfish');

  if (!await executable.exists()) {
    _debugLog('Preparing Stockfish sources in ${sourceDir.path}');
    if (await buildRoot.exists()) {
      await buildRoot.delete(recursive: true);
    }
    await _copyDirectoryRecursively(bundledSourceDir, sourceDir);
    await _ensureNetworks(sourceDir);

    _debugLog('Building Stockfish for macOS at ${sourceDir.path}');
    final archArgs = Platform.version.contains('arm64')
        ? <String>[
            '-DARCH=apple-silicon',
            '-DUSE_POPCNT',
            '-DUSE_NEON=8',
            '-DUSE_NEON_DOTPROD',
            '-arch',
            'arm64',
            '-march=armv8.2-a+dotprod',
          ]
        : <String>[
            '-DARCH=x86-64',
            '-DUSE_POPCNT',
            '-DUSE_SSE2',
            '-DUSE_SSSE3',
            '-msse2',
            '-mssse3',
            '-mpopcnt',
            '-arch',
            'x86_64',
          ];

    final result = await Process.run(
        '/usr/bin/clang++',
        <String>[
          '-std=c++20',
          '-O3',
          '-DNDEBUG',
          '-DIS_64BIT',
          '-DUSE_PTHREADS',
          '-DUSE_PREFETCH',
          '-mmacosx-version-min=10.15',
          '-mdynamic-no-pic',
          '-pthread',
          ...archArgs,
          'benchmark.cpp',
          'bitboard.cpp',
          'engine.cpp',
          'evaluate.cpp',
          'main.cpp',
          'memory.cpp',
          'misc.cpp',
          'movegen.cpp',
          'movepick.cpp',
          'position.cpp',
          'score.cpp',
          'search.cpp',
          'syzygy/tbprobe.cpp',
          'thread.cpp',
          'timeman.cpp',
          'tt.cpp',
          'tune.cpp',
          'uci.cpp',
          'ucioption.cpp',
          'nnue/features/full_threats.cpp',
          'nnue/features/half_ka_v2_hm.cpp',
          'nnue/network.cpp',
          'nnue/nnue_accumulator.cpp',
          'nnue/nnue_misc.cpp',
          '-o',
          executable.path,
        ],
        workingDirectory: sourceDir.path);
    if (result.exitCode != 0) {
      throw StateError(
        'Failed to build Stockfish for macOS:\n${result.stdout}\n${result.stderr}',
      );
    }
    _debugLog('Finished building Stockfish for macOS');
  }

  final chmod = await Process.run('/bin/chmod', ['+x', executable.path]);
  if (chmod.exitCode != 0) {
    throw StateError('Failed to mark Stockfish executable as runnable');
  }

  return executable;
}

/// Locates `ios/Stockfish/src` of this package. In debug/JIT runs the package
/// URI resolves to the package directory; otherwise fall back to searching
/// upwards from the working directory / executable for a checkout.
Future<Directory> _findBundledMacOSSourceDir() async {
  final libUri = await Isolate.resolvePackageUri(
    Uri.parse('package:stockfish_engine_flutter/stockfish_engine_flutter.dart'),
  );
  if (libUri != null && libUri.scheme == 'file') {
    final dir = Directory.fromUri(libUri.resolve('../ios/Stockfish/src'));
    if (dir.existsSync()) {
      _debugLog('Resolved Stockfish source directory: ${dir.path}');
      return dir;
    }
  }

  final cwd = Directory.current.absolute;
  final executableDir = File(Platform.resolvedExecutable).parent.absolute;
  final candidates = <String>{
    ..._candidateSourceDirsFrom(cwd),
    ..._candidateSourceDirsFrom(executableDir),
  };

  for (final candidate in candidates) {
    final dir = Directory(candidate);
    if (dir.existsSync()) {
      _debugLog('Resolved Stockfish source directory: ${dir.path}');
      return dir;
    }
  }

  throw StateError(
    'Unable to locate the Stockfish source directory from '
    'cwd=${cwd.path} executable=${Platform.resolvedExecutable}',
  );
}

Iterable<String> _candidateSourceDirsFrom(Directory start) sync* {
  final visited = <String>{};
  var current = start.absolute;

  while (true) {
    for (final candidate in [
      '${current.path}/ios/Stockfish/src',
      '${current.path}/stockfish_engine_flutter/ios/Stockfish/src',
    ]) {
      if (visited.add(candidate)) yield candidate;
    }

    final parent = current.parent.absolute;
    if (parent.path == current.path) {
      break;
    }
    current = parent;
  }
}

/// The *.nnue networks are not committed to git. The default net names are
/// read from `evaluate.h` and downloaded with curl when missing; the engine
/// embeds them at compile time (incbin).
Future<void> _ensureNetworks(Directory sourceDir) async {
  final header = await File('${sourceDir.path}/evaluate.h').readAsString();
  final names = RegExp(
    r'#define EvalFileDefaultName\w+ "(nn-[0-9a-f]+\.nnue)"',
  ).allMatches(header).map((m) => m.group(1)!).toList();
  for (final name in names) {
    final file = File('${sourceDir.path}/$name');
    if (await file.exists()) continue;
    _debugLog('Downloading $name');
    final result = await Process.run('/usr/bin/curl', <String>[
      '--fail',
      '--location',
      '--silent',
      '--show-error',
      '--output',
      file.path,
      'https://tests.stockfishchess.org/api/nn/$name',
    ]);
    if (result.exitCode != 0) {
      if (await file.exists()) await file.delete();
      throw StateError('Failed to download $name: ${result.stderr}');
    }
  }
}

Future<void> _copyDirectoryRecursively(
  Directory source,
  Directory destination,
) async {
  await destination.create(recursive: true);

  await for (final entity in source.list(recursive: false)) {
    final targetPath = '${destination.path}/${entity.uri.pathSegments.last}';
    if (entity is Directory) {
      await _copyDirectoryRecursively(entity, Directory(targetPath));
    } else if (entity is File) {
      await entity.copy(targetPath);
    }
  }
}

/// Creates a C++ engine asynchronously.
///
/// This method is different from the factory method [Stockfish.new] that
/// it will wait for the engine to be ready before returning the instance.
Future<Stockfish> stockfishAsync() {
  if (Stockfish._instance != null) {
    return Future.error(StateError('Only one instance can be used at a time'));
  }

  final completer = Completer<Stockfish>();
  Stockfish._instance = Stockfish._(completer: completer);
  return completer.future;
}

class _StockfishState extends ChangeNotifier
    implements ValueListenable<StockfishState> {
  StockfishState _value = StockfishState.starting;

  @override
  StockfishState get value => _value;

  void _setValue(StockfishState v) {
    if (v == _value) return;
    _value = v;
    notifyListeners();
  }
}

void _isolateMain(SendPort mainPort) {
  final exitCode = nativeMain();
  mainPort.send(exitCode);

  _logger.fine('nativeMain returns $exitCode');
}

void _isolateStdout(SendPort stdoutPort) {
  String previous = '';

  while (true) {
    final pointer = nativeStdoutRead();

    if (pointer.address == 0) {
      _logger.fine('nativeStdoutRead returns NULL');
      return;
    }

    final str = pointer.toDartString();
    if (str.isEmpty) continue;

    final data = previous + str;
    final lines = data.split('\n');
    previous = lines.removeLast();
    for (final line in lines) {
      stdoutPort.send(line);
    }
  }
}

Future<bool> _spawnIsolates(List<SendPort> mainAndStdout) async {
  final initResult = nativeInit();
  if (initResult != 0) {
    _logger.severe('initResult=$initResult');
    return false;
  }

  try {
    await Isolate.spawn(_isolateStdout, mainAndStdout[1]);
  } catch (error) {
    _logger.severe('Failed to spawn stdout isolate: $error');
    return false;
  }

  try {
    await Isolate.spawn(_isolateMain, mainAndStdout[0]);
  } catch (error) {
    _logger.severe('Failed to spawn main isolate: $error');
    return false;
  }

  return true;
}
