/*
  stockfish_engine_flutter - Android NNUE network library.
  Copyright (C) 2026 Mihir Joshi and contributors.
  Licensed under the GNU General Public License, version 3 or later.

  Built as libstockfish_nets.so (see android/CMakeLists.txt). It contains only
  the two default NNUE networks, embedded with incbin exactly as upstream
  Stockfish does in nnue/network.cpp. The engine executables
  (libstockfish_bin.so, libstockfish_bin_compat.so) are compiled with
  -DSTOCKFISH_EXTERNAL_NETS, which makes network.cpp reference these symbols
  with INCBIN_EXTERN instead of embedding its own copy, so the ~93 MB of
  network data is shipped once per ABI no matter how many engine builds exist.

  The incbin labels are plain global assembler symbols with default
  visibility, so the dynamic linker exports:
    gEmbeddedNNUEBigData / gEmbeddedNNUEBigEnd / gEmbeddedNNUEBigSize
    gEmbeddedNNUESmallData / gEmbeddedNNUESmallEnd / gEmbeddedNNUESmallSize
*/

#define INCBIN_SILENCE_BITCODE_WARNING
#include "incbin/incbin.h"

// EvalFileDefaultNameBig / EvalFileDefaultNameSmall: the single source of
// truth for the network file names (the files are found via the include path).
#include "evaluate.h"

INCBIN(EmbeddedNNUEBig, EvalFileDefaultNameBig);
INCBIN(EmbeddedNNUESmall, EvalFileDefaultNameSmall);
