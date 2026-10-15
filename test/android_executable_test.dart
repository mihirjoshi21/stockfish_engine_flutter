import 'package:flutter_test/flutter_test.dart';
import 'package:stockfish_engine_flutter/src/android_executable.dart';

/// /proc/cpuinfo of an arm64 kernel: one block per core.
String _cpuinfo(List<String> featuresPerCore) {
  final buffer = StringBuffer();
  for (var i = 0; i < featuresPerCore.length; i++) {
    buffer
      ..writeln('processor\t: $i')
      ..writeln('BogoMIPS\t: 38.40')
      ..writeln('Features\t: ${featuresPerCore[i]}')
      ..writeln('CPU implementer\t: 0x41')
      ..writeln('CPU architecture: 8')
      ..writeln('CPU part\t: 0xd05')
      ..writeln();
  }
  return buffer.toString();
}

const _a55 = 'fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp '
    'cpuid asimdrdm lrcpc dcpop asimddp';
const _a53 = 'fp asimd evtstrm aes pmull sha1 sha2 crc32 cpuid';

void main() {
  group('cpuinfoHasDotProd', () {
    test('true when every core reports asimddp', () {
      expect(cpuinfoHasDotProd(_cpuinfo([_a55, _a55, _a55, _a55])), isTrue);
    });

    test('false on a core without dot product (Cortex-A53)', () {
      expect(cpuinfoHasDotProd(_cpuinfo([_a53, _a53])), isFalse);
    });

    test('false if any one Features line lacks asimddp', () {
      expect(cpuinfoHasDotProd(_cpuinfo([_a55, _a55, _a53, _a55])), isFalse);
    });

    test('false without any Features line (empty or unreadable cpuinfo)', () {
      expect(cpuinfoHasDotProd(''), isFalse);
      expect(cpuinfoHasDotProd('processor\t: 0\nBogoMIPS\t: 38.40\n'), isFalse);
    });

    test('matches whole tokens only', () {
      expect(cpuinfoHasDotProd('Features\t: fp asimd asimddpx\n'), isFalse);
      expect(cpuinfoHasDotProd('Features\t: fp xasimddp\n'), isFalse);
    });

    test('ignores other lines that mention asimddp', () {
      expect(
        cpuinfoHasDotProd('Hardware\t: asimddp\nFeatures\t: $_a53\n'),
        isFalse,
      );
    });

    test('accepts a single Features line and CRLF / extra whitespace', () {
      expect(cpuinfoHasDotProd('Features : fp  asimd\tasimddp \r\n'), isTrue);
    });
  });

  group('selectAndroidExecutable', () {
    const both = {androidDotProdExecutable, androidCompatExecutable};

    test('dotprod CPU uses libstockfish_bin.so', () {
      expect(
        selectAndroidExecutable(_cpuinfo([_a55, _a55]), both.contains),
        'libstockfish_bin.so',
      );
    });

    test('non-dotprod CPU uses libstockfish_bin_compat.so', () {
      expect(
        selectAndroidExecutable(_cpuinfo([_a53, _a55]), both.contains),
        'libstockfish_bin_compat.so',
      );
    });

    test('falls back to libstockfish_bin.so when compat is missing', () {
      // armeabi-v7a, x86_64 and debug builds only ship libstockfish_bin.so.
      expect(
        selectAndroidExecutable(
          _cpuinfo([_a53]),
          {androidDotProdExecutable}.contains,
        ),
        androidDotProdExecutable,
      );
    });

    test('falls back to compat when the dotprod build is missing', () {
      expect(
        selectAndroidExecutable(
          _cpuinfo([_a55]),
          {androidCompatExecutable}.contains,
        ),
        androidCompatExecutable,
      );
    });

    test('returns null when neither exists', () {
      expect(selectAndroidExecutable(_cpuinfo([_a55]), (_) => false), isNull);
      expect(selectAndroidExecutable('', (_) => false), isNull);
    });

    test('preference order', () {
      expect(androidExecutablePreference(_cpuinfo([_a55])), [
        androidDotProdExecutable,
        androidCompatExecutable,
      ]);
      expect(androidExecutablePreference(_cpuinfo([_a53])), [
        androidCompatExecutable,
        androidDotProdExecutable,
      ]);
    });
  });
}
