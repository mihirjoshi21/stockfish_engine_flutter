cmake_minimum_required(VERSION 3.13)
project(stockfish_engine_flutter LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Enable 16KB page size support for Android (required for Google Play).
add_link_options(-Wl,-z,max-page-size=16384)
add_link_options(-Wl,-z,common-page-size=16384)

set(SF_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../ios/Stockfish/src")
file(GLOB_RECURSE cppPaths "${SF_SRC_DIR}/*.cpp")

# ---------------------------------------------------------------------------
# NNUE networks.
#
# The networks are embedded with incbin, as upstream Stockfish does, but here in
# libstockfish_nets.so (stockfish_nets.cpp, see below): the assembler
# `.incbin`s the file named EvalFileDefaultNameBig/Small in evaluate.h,
# searching the include path. The *.nnue files are not committed to git, so they
# are fetched here if they are not already present next to the sources. The
# names are read from evaluate.h (never hard-coded) and each download is
# verified: a Stockfish net name is nn-<first 12 hex digits of its SHA-256>.
# ---------------------------------------------------------------------------
file(STRINGS "${SF_SRC_DIR}/evaluate.h" _eval_names
     REGEX "#define EvalFileDefaultName(Big|Small) ")
set(SF_NETS "")
foreach(_line IN LISTS _eval_names)
  string(REGEX MATCH "\"(nn-[0-9a-f]+\\.nnue)\"" _m "${_line}")
  list(APPEND SF_NETS "${CMAKE_MATCH_1}")
endforeach()
list(LENGTH SF_NETS _net_count)
if(NOT _net_count EQUAL 2)
  message(FATAL_ERROR "Could not read the default NNUE names from evaluate.h")
endif()

set(SF_NET_DIR "${CMAKE_BINARY_DIR}/nets")
file(MAKE_DIRECTORY "${SF_NET_DIR}")
foreach(_net IN LISTS SF_NETS)
  if(NOT EXISTS "${SF_SRC_DIR}/${_net}" AND NOT EXISTS "${SF_NET_DIR}/${_net}")
    string(REGEX REPLACE "^nn-([0-9a-f]+)\\.nnue$" "\\1" _hash "${_net}")
    message(STATUS "Downloading ${_net}")
    file(DOWNLOAD "https://tests.stockfishchess.org/api/nn/${_net}"
         "${SF_NET_DIR}/${_net}" SHOW_PROGRESS STATUS _status)
    list(GET _status 0 _code)
    if(NOT _code EQUAL 0)
      file(REMOVE "${SF_NET_DIR}/${_net}")
      message(FATAL_ERROR "Failed to download ${_net}: ${_status}. "
              "Download it manually into ${SF_SRC_DIR}.")
    endif()
    file(SHA256 "${SF_NET_DIR}/${_net}" _sha)
    string(FIND "${_sha}" "${_hash}" _pos)
    if(NOT _pos EQUAL 0)
      file(REMOVE "${SF_NET_DIR}/${_net}")
      message(FATAL_ERROR "Checksum mismatch for ${_net} (got ${_sha})")
    endif()
  endif()
endforeach()

# ---------------------------------------------------------------------------
# Layout (identical for every ABI, plus one extra executable on arm64-v8a):
#
#   libstockfish_nets.so        real shared library, ONLY the two NNUE nets
#                               (~93 MB, incbin, see stockfish_nets.cpp)
#   libstockfish_bin.so         engine EXECUTABLE (arm64-v8a release: dotprod)
#   libstockfish_bin_compat.so  engine EXECUTABLE, arm64-v8a release only:
#                               plain ARMv8-A NEON, no dot-product instructions
#
# The executables are compiled with -DSTOCKFISH_EXTERNAL_NETS so network.cpp
# only references the net symbols (INCBIN_EXTERN) and they are DT_NEEDED on
# libstockfish_nets.so. Shipping the nets once keeps the second arm64 engine
# build to about 1 MB (stripped). The Dart side picks the executable at runtime from
# /proc/cpuinfo (`asimddp`), see lib/src/stockfish.dart.
#
# The executables only have lib*.so names because Android's package installer
# only extracts such files into nativeLibraryDir, which is where the app may
# exec() from on Android 10+. They are spawned with Process.start() and talk
# UCI over stdin/stdout; main() comes from Stockfish's own main.cpp, no JNI/FFI
# glue is involved. Requires extractNativeLibs / useLegacyPackaging (README).
# ---------------------------------------------------------------------------
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
  set(SF_RELEASE OFF)
else()
  set(SF_RELEASE ON)
endif()

add_library(stockfish_nets SHARED "${CMAKE_CURRENT_SOURCE_DIR}/stockfish_nets.cpp")
# .incbin searches the include path, so both directories that may hold the
# downloaded *.nnue files are listed.
target_include_directories(stockfish_nets PRIVATE ${SF_SRC_DIR} ${SF_NET_DIR})

# Flags shared by every engine executable.
set(SF_COMMON_DEFS -DUSE_PTHREADS -DSTOCKFISH_EXTERNAL_NETS)
if(ANDROID_ABI STREQUAL arm64-v8a)
  list(APPEND SF_COMMON_DEFS -DIS_64BIT -DUSE_POPCNT -DUSE_NEON=8)
endif()
if(SF_RELEASE)
  set(SF_OPT_FLAGS -fno-exceptions -DNDEBUG -O3)
else()
  set(SF_OPT_FLAGS "")
endif()

set(SF_RPATH_RSP "${CMAKE_BINARY_DIR}/stockfish_rpath.rsp")
file(WRITE "${SF_RPATH_RSP}" "-rpath=$ORIGIN\n")

function(stockfish_executable target output_name)
  add_executable(${target} ${cppPaths})
  set_target_properties(${target} PROPERTIES
    OUTPUT_NAME "${output_name}"
    POSITION_INDEPENDENT_CODE ON)
  target_include_directories(${target} PRIVATE ${SF_SRC_DIR} ${SF_SRC_DIR}/nnue)
  # Bionic has no copy relocations: the net symbols live in a shared library,
  # so the executable must reach them through the GOT, never by direct
  # PC-relative access that the static linker would turn into R_*_COPY.
  target_compile_options(${target} PRIVATE
      -fPIE -fno-direct-access-external-data ${SF_COMMON_DEFS} ${SF_OPT_FLAGS} ${ARGN})
  target_link_libraries(${target} PRIVATE stockfish_nets)
  # DT_RUNPATH=$ORIGIN (honoured by bionic since API 24) so the dynamic linker
  # finds libstockfish_nets.so next to the executable; the Dart side also sets
  # LD_LIBRARY_PATH=nativeLibraryDir. CMake's RPATH properties are ignored on
  # Android, and how `$` in a link flag survives Ninja + shell differs between
  # CMake versions (3.22 yields RUNPATH "$", 4.x "$ORIGIN"), so the option is
  # passed to the linker in a response file, where `$` is not special.
  target_link_options(${target} PRIVATE -pie "-Wl,--enable-new-dtags" "-Wl,@${SF_RPATH_RSP}")
  set_property(TARGET ${target} APPEND PROPERTY LINK_DEPENDS "${SF_RPATH_RSP}")
endfunction()

if(ANDROID_ABI STREQUAL arm64-v8a AND SF_RELEASE)
  # ARMv8.2-A dot product (Cortex-A55/A75 and newer).
  stockfish_executable(stockfish_bin "libstockfish_bin.so"
      -march=armv8.2-a+dotprod -DUSE_NEON_DOTPROD)
  # Baseline ARMv8-A + NEON for cores without `asimddp` (Cortex-A53/A72/A73…).
  stockfish_executable(stockfish_bin_compat "libstockfish_bin_compat.so")
else()
  # armeabi-v7a / x86_64, and Debug builds on every ABI (Debug never used
  # dotprod, so libstockfish_bin.so is safe on all arm64 cores there; the Dart
  # side falls back to it when libstockfish_bin_compat.so is absent).
  stockfish_executable(stockfish_bin "libstockfish_bin.so")
endif()
