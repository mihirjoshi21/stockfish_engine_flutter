/// Selection of the Stockfish executable on Android.
///
/// android/CMakeLists.txt ships, in `nativeLibraryDir`:
/// * `libstockfish_nets.so` – shared library holding the NNUE networks;
/// * [androidDotProdExecutable] – engine built with ARMv8.2 dot-product
///   instructions on arm64-v8a release builds (the only executable on other
///   ABIs and in debug builds, where it contains no dotprod code);
/// * [androidCompatExecutable] – arm64-v8a release only: baseline ARMv8-A
///   NEON build for cores without dot product (Cortex-A53/A72/A73 class),
///   which would die with SIGILL running the dotprod build.
///
/// Not exported from the package's public library.
library;

/// Dot-product engine (or the only engine on non-arm64 ABIs / debug builds).
const androidDotProdExecutable = 'libstockfish_bin.so';

/// Engine without dot-product instructions (arm64-v8a release builds only).
const androidCompatExecutable = 'libstockfish_bin_compat.so';

/// `/proc/cpuinfo` HWCAP token for the ARMv8.2 dot-product extension.
const _dotProdFeature = 'asimddp';

/// Whether `/proc/cpuinfo` [cpuinfo] reports the dot-product extension on
/// every CPU.
///
/// Requires at least one `Features` line, and *every* `Features` line (one
/// per core on arm64 kernels) to contain the `asimddp` token: on big.LITTLE
/// systems the process may be scheduled on any core.
bool cpuinfoHasDotProd(String cpuinfo) {
  var sawFeatures = false;
  for (final line in cpuinfo.split('\n')) {
    final separator = line.indexOf(':');
    if (separator < 0) continue;
    if (line.substring(0, separator).trim() != 'Features') continue;
    sawFeatures = true;
    final tokens = line.substring(separator + 1).trim().split(RegExp(r'\s+'));
    if (!tokens.contains(_dotProdFeature)) return false;
  }
  return sawFeatures;
}

/// Executable names in order of preference for the CPU described by
/// [cpuinfo]: the dot-product build only if [cpuinfoHasDotProd], otherwise
/// the compat build, followed by the other one as a fallback.
List<String> androidExecutablePreference(String cpuinfo) =>
    cpuinfoHasDotProd(cpuinfo)
        ? const [androidDotProdExecutable, androidCompatExecutable]
        : const [androidCompatExecutable, androidDotProdExecutable];

/// The first executable of [androidExecutablePreference] for which [exists]
/// returns true, or `null` if none exists.
String? selectAndroidExecutable(
  String cpuinfo,
  bool Function(String name) exists,
) {
  for (final name in androidExecutablePreference(cpuinfo)) {
    if (exists(name)) return name;
  }
  return null;
}
