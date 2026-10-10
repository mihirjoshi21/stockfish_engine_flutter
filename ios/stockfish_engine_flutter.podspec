#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint stockfish.podspec' to validate before publishing.
#
#
require 'yaml'

pubspec = YAML.load(File.read(File.join(__dir__, '../pubspec.yaml')))

Pod::Spec.new do |s|
  s.name             = pubspec['name']
  s.version          = pubspec['version']
  s.summary          = pubspec['description']
  s.homepage         = pubspec['repository']
  s.license          = { :type => 'GPL-3.0', :file => '../LICENSE' }
  s.authors          = { 'Mihir Joshi' => 'https://github.com/mihirjoshi21', 'Arjan Aswal (original stockfish plugin)' => 'https://github.com/ArjanAswal', 'The Stockfish developers' => 'https://github.com/official-stockfish/Stockfish' }
  s.source = { :git => pubspec['repository'], :tag => s.version.to_s }
  s.source_files = 'Classes/**/*', 'FlutterStockfish/*', 'Stockfish/src/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.exclude_files = 'Stockfish/src/incbin/UNLICENCE'
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'
  s.ios.deployment_target  = '12.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }

  # Additional compiler configuration required for Stockfish
  s.library = 'c++'
  #
  # The *.nnue networks are not committed to git. Download them before compile
  # (the engine embeds them with incbin). A Stockfish net is named
  # nn-<first 12 hex digits of its SHA-256>.nnue, so, as android/CMakeLists.txt
  # does, the download is verified by checking that prefix and the file is
  # deleted on any failure.
  fetch_net = lambda do |net|
    <<~SH
      set -e
      cd "${PODS_TARGET_SRCROOT}/Stockfish/src"
      net='#{net}'
      [ -e "$net" ] && exit 0
      want="${net#nn-}"; want="${want%.nnue}"
      tmp="$net.part"
      rm -f "$tmp"
      if ! curl --fail --location --silent --show-error --output "$tmp" "https://tests.stockfishchess.org/api/nn/$net"; then
        rm -f "$tmp"
        echo "error: failed to download $net" >&2
        exit 1
      fi
      got="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"
      case "$got" in
        "$want"*) mv "$tmp" "$net" ;;
        *) rm -f "$tmp" "$net"; echo "error: checksum mismatch for $net (got $got)" >&2; exit 1 ;;
      esac
    SH
  end

  s.script_phase = [
    {
      :execution_position => :before_compile,
      :name => 'Download nnue',
      :script => fetch_net.call('nn-7bf13f9655c8.nnue')
    },
    {
      :execution_position => :before_compile,
      :name => 'Download small nnue',
      :script => fetch_net.call('nn-47fc8b7fff06.nnue')
    },
  ]
  s.xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'OTHER_CPLUSPLUSFLAGS[config=Debug]' => '$(inherited) -std=c++17 -DUSE_PTHREADS -DIS_64BIT -DUSE_POPCNT -I"${PODS_TARGET_SRCROOT}/Stockfish/src"',
    'OTHER_LDFLAGS[config=Debug]' => '$(inherited) -std=c++17 -DUSE_PTHREADS -DIS_64BIT -DUSE_POPCNT',
    'OTHER_CPLUSPLUSFLAGS[config=Release]' => '$(inherited) -fno-exceptions -std=c++17 -DUSE_PTHREADS -DNDEBUG -O3 -DIS_64BIT -DUSE_POPCNT -DUSE_NEON=8 -DUSE_NEON_DOTPROD -march=armv8.2-a+dotprod -flto=full -I"${PODS_TARGET_SRCROOT}/Stockfish/src"',
    'OTHER_LDFLAGS[config=Release]' => '$(inherited) -fno-exceptions -std=c++17 -DUSE_PTHREADS -DNDEBUG -O3 -DIS_64BIT -DUSE_POPCNT -DUSE_NEON=8 -DUSE_NEON_DOTPROD -march=armv8.2-a+dotprod -flto=full'
  }
end
