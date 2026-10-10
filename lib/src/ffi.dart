import 'dart:ffi';
import 'package:ffi/ffi.dart';

// iOS only: the engine is statically linked into the app (see
// ios/stockfish.podspec). Android and macOS run Stockfish as a separate
// process instead (see stockfish.dart), so they never touch this file.
DynamicLibrary? _nativeLib;

DynamicLibrary get _lib => _nativeLib ??= DynamicLibrary.process();

int nativeInit() => _lib
    .lookup<NativeFunction<Int32 Function()>>('stockfish_init')
    .asFunction<int Function()>()();

int nativeMain() => _lib
    .lookup<NativeFunction<Int32 Function()>>('stockfish_main')
    .asFunction<int Function()>()();

int nativeStdinWrite(Pointer<Utf8> input) => _lib
    .lookup<NativeFunction<IntPtr Function(Pointer<Utf8>)>>(
      'stockfish_stdin_write',
    )
    .asFunction<int Function(Pointer<Utf8>)>()(input);

Pointer<Utf8> nativeStdoutRead() => _lib
    .lookup<NativeFunction<Pointer<Utf8> Function()>>(
      'stockfish_stdout_read',
    )
    .asFunction<Pointer<Utf8> Function()>()();

void nativeDispose() => _lib
    .lookup<NativeFunction<Void Function()>>('stockfish_dispose')
    .asFunction<void Function()>()();
