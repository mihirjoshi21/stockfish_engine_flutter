# stockfish_engine_flutter

The [Stockfish](https://stockfishchess.org) chess engine for Flutter, with a
simple UCI `stdin` / `stdout` API.

| Platform | How the engine runs |
| -------- | ------------------- |
| Android  | **Separate process.** Stockfish is built as an executable (`libstockfish_bin.so`, plus `libstockfish_bin_compat.so` on arm64), extracted by the installer into `nativeLibraryDir`, and started with `Process.start`. The NNUE networks live once in the shared library `libstockfish_nets.so`. |
| iOS      | In-process through Dart FFI (statically linked into the app). |
| macOS    | Development convenience: a separate process built from the bundled sources on first use. |

**License: GPL-3.0.** Stockfish is GPLv3, so any app that distributes this
package must be GPLv3-compatible and offer its source. See [LICENSE](LICENSE)
and [NOTICE](NOTICE).

## Credits

* This package is a fork of the Flutter plugin
  [`stockfish`](https://github.com/ArjanAswal/stockfish) by
  [Arjan Aswal](https://github.com/ArjanAswal) (the FFI bridge, iOS podspec
  and original packaging come from it).
* The chess engine is [Stockfish](https://github.com/official-stockfish/Stockfish),
  © The Stockfish developers (see the upstream
  [AUTHORS](https://github.com/official-stockfish/Stockfish/blob/master/AUTHORS)
  file). Evaluation networks (NNUE) are trained and published by the Stockfish
  project and community.
* `ios/Stockfish/src/incbin` is [incbin](https://github.com/graphitemaster/incbin)
  by Dale Weiler (public domain, see `incbin/UNLICENCE`).

## Usage

```yaml
dependencies:
  stockfish_engine_flutter:
    git:
      url: https://github.com/mihirjoshi21/stockfish_engine_flutter.git
```

```dart
import 'package:stockfish_engine_flutter/stockfish_engine_flutter.dart';

final stockfish = Stockfish();                 // only one instance at a time
stockfish.state.addListener(() {               // ValueListenable<StockfishState>
  if (stockfish.state.value == StockfishState.ready) {
    stockfish.stdin = 'uci';                   // send UCI commands
    stockfish.stdin = 'go movetime 1000';
  }
});
stockfish.stdout.listen(print);                // Stream<String>, one line each
// ...
stockfish.dispose();                           // quits and kills the engine
```

`Stockfish()` is synchronous; `await stockfishAsync()` returns once the engine
is ready. Commands can only be sent in the `ready` state.

### Android notes

* **Required app setting.** The installer must extract native libraries,
  otherwise `libstockfish_bin.so` stays inside the APK and cannot be executed.
  Add to your app's `android/app/build.gradle(.kts)`:
  ```kotlin
  android {
      packaging { jniLibs { useLegacyPackaging = true } }
  }
  ```
  The plugin manifest also declares `android:extractNativeLibs="true"`, which is
  enough for AGP 7 and older, but AGP 8+ overrides that attribute with
  `useLegacyPackaging`, so the Gradle setting is what actually counts. If the
  executable is missing at runtime the engine reports `StockfishState.error`
  with an explanatory log line.
* Executing a file from `nativeLibraryDir` is permitted on all Android versions
  (the W^X restriction from Android 10 only affects the app's data directories).
* **Native files per ABI** (all in `nativeLibraryDir`, all 16 KB page aligned,
  a Google Play requirement):

  | File | What it is |
  | ---- | ---------- |
  | `libstockfish_nets.so` | Shared library holding only the two NNUE networks (~93 MB, embedded with incbin). |
  | `libstockfish_bin.so` | Engine executable. On arm64-v8a release builds it uses ARMv8.2 dot-product instructions (`-march=armv8.2-a+dotprod`). |
  | `libstockfish_bin_compat.so` | arm64-v8a release builds only: same engine without dot product, for Cortex-A53/A72/A73-class CPUs (e.g. Snapdragon 625/660/835) that would crash with `SIGILL` on the dotprod build. |

  The executables are linked against `libstockfish_nets.so` (found through
  `DT_RUNPATH=$ORIGIN`, and `LD_LIBRARY_PATH` is also set when spawning), so the
  networks are shipped once; the compat build adds well under 1 MB to the
  download. armeabi-v7a, x86_64 and debug builds ship only `libstockfish_bin.so`
  (no dotprod code there).
* **Executable selection.** `libstockfish_bin.so` is used only if *every*
  `Features` line in `/proc/cpuinfo` contains `asimddp`; otherwise
  `libstockfish_bin_compat.so`. If the chosen file does not exist, the other
  one is used. The choice is logged (`[STOCKFISH] ... using ...`).
* The engine runs in its own process, so a crash in Stockfish cannot take the
  app down; the `state` becomes `StockfishState.error`.

### iOS notes

`IPHONEOS_DEPLOYMENT_TARGET` must be 12.0 or newer. The engine is linked into
the app, so there is no runtime CPU dispatch: the Release build targets baseline
ARMv8-A NEON (no dot product, which A11-and-older iPhones lack) and does not use
LTO (with `-flto` the `.incbin` of the networks fails to find the files).

## Building from source

The NNUE networks are **not** stored in git (`*.nnue` is ignored). The
default network names are defined in `ios/Stockfish/src/evaluate.h`
(`EvalFileDefaultNameBig` / `EvalFileDefaultNameSmall`) and are embedded into
the engine at compile time with incbin.

* **Android** – nothing to do. `android/CMakeLists.txt` downloads the two
  networks from `tests.stockfishchess.org` at configure time if they are not in
  `ios/Stockfish/src`, verifies each against the SHA-256 prefix in its file
  name, and builds `libstockfish_nets.so` and the engine executable(s) listed
  under *Android notes* for every ABI. Requirements: Android SDK,
  NDK, and CMake 3.13+ (SDK-managed CMake 3.22.1 works). For offline builds,
  copy the two `.nnue` files into `ios/Stockfish/src/` first.
  ```sh
  cd example && flutter build apk --debug
  unzip -l build/app/outputs/flutter-apk/app-debug.apk | grep libstockfish_
  ```
* **iOS** – `pod install` runs a script phase that downloads the same two
  networks into `ios/Stockfish/src` if missing.
  ```sh
  cd example && flutter build ios --no-codesign --debug
  ```
* **macOS (dev only)** – the first launch copies the sources to a temporary
  directory, downloads the networks with `curl` and compiles with
  `/usr/bin/clang++`; the result is cached in the system temp directory.

Run the example app with `cd example && flutter run`; the integration test is in
`example/integration_test`.

## Contributing / releasing

Changes to the engine sources are GPLv3 as well. Please record modifications in
[NOTICE](NOTICE) and [CHANGELOG.md](CHANGELOG.md).
