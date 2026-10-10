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
# Stockfish embeds its networks into the binary with incbin (see
# ios/Stockfish/src/nnue/network.cpp): the assembler `.incbin`s the file whose
# name is EvalFileDefaultNameBig/Small from evaluate.h, searching the include
# path. This is unchanged. The *.nnue files are not committed to git, so they
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
# Stockfish as an EXECUTABLE named libstockfish_bin.so.
#
# Android's package installer only extracts files named lib*.so into
# nativeLibraryDir, and that is the one app-writable-free location the app may
# exec() from on Android 10+. The Dart side spawns this file with
# Process.start() and talks UCI over stdin/stdout (see lib/src/stockfish.dart).
# main() comes from Stockfish's own main.cpp; no JNI/FFI glue is involved.
# Requires android:extractNativeLibs="true" (set in this plugin's manifest).
# ---------------------------------------------------------------------------
add_executable(stockfish_bin ${cppPaths})
set_target_properties(stockfish_bin PROPERTIES
  OUTPUT_NAME "libstockfish_bin.so"
  POSITION_INDEPENDENT_CODE ON)
target_compile_options(stockfish_bin PRIVATE -fPIE)
target_link_options(stockfish_bin PRIVATE -pie)

target_include_directories(stockfish_bin PRIVATE
    ${SF_SRC_DIR}
    ${SF_SRC_DIR}/nnue
    ${SF_NET_DIR}
)

if(ANDROID_ABI STREQUAL arm64-v8a)
  if (CMAKE_BUILD_TYPE STREQUAL "Debug")
    target_compile_options(stockfish_bin PRIVATE -DUSE_PTHREADS -DIS_64BIT -DUSE_POPCNT -DUSE_NEON=8)
  else()
    target_compile_options(stockfish_bin PRIVATE
        -fno-exceptions -DUSE_PTHREADS -DNDEBUG -O3 -DIS_64BIT -DUSE_POPCNT -DUSE_NEON=8
        -march=armv8.2-a+dotprod -DUSE_NEON_DOTPROD
    )
  endif()
else()
  if (CMAKE_BUILD_TYPE STREQUAL "Debug")
    target_compile_options(stockfish_bin PRIVATE -DUSE_PTHREADS)
  else()
    target_compile_options(stockfish_bin PRIVATE -fno-exceptions -DUSE_PTHREADS -DNDEBUG -O3)
  endif()
endif()
