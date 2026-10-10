#include <iostream>
#include <stdio.h>
#include <unistd.h>
#include <thread>
#include <poll.h>

#include "../Stockfish/src/bitboard.h"
#include "../Stockfish/src/misc.h"
#include "../Stockfish/src/position.h"
#include "../Stockfish/src/types.h"
#include "../Stockfish/src/uci.h"
#include "../Stockfish/src/tune.h"

#include "ffi.h"

// https://jineshkj.wordpress.com/2006/12/22/how-to-capture-stdin-stdout-and-stderr-of-child-program/
#define NUM_PIPES 2
#define PARENT_WRITE_PIPE 0
#define PARENT_READ_PIPE 1
#define READ_FD 0
#define WRITE_FD 1
#define PARENT_READ_FD (pipes[PARENT_READ_PIPE][READ_FD])
#define PARENT_WRITE_FD (pipes[PARENT_WRITE_PIPE][WRITE_FD])
#define CHILD_READ_FD (pipes[PARENT_WRITE_PIPE][READ_FD])
#define CHILD_WRITE_FD (pipes[PARENT_READ_PIPE][WRITE_FD])

static bool is_running = false;

int main(int, char **);

const char *QUITOK = "quitok\n";
int pipes[NUM_PIPES][2];
char buffer[80];

int stockfish_init()
{
  if (pipes[PARENT_WRITE_PIPE][WRITE_FD] != 0) {
    // A previous Dart instance already initialized the pipes!
    // We keep them open so the new Dart instance connects to the old daemon.
    return 0;
  }

  pipe(pipes[PARENT_READ_PIPE]);
  pipe(pipes[PARENT_WRITE_PIPE]);

  return 0;
}

int stockfish_main()
{
  if (is_running) {
    // Engine daemon is already running from a previous hot restart.
    // Return early to let Dart reconnect seamlessly.
    return 0;
  }
  is_running = true;

  std::thread([]() {
    dup2(CHILD_READ_FD, STDIN_FILENO);
    dup2(CHILD_WRITE_FD, STDOUT_FILENO);

    int argc = 1;
    char *argv[] = {""};
    main(argc, argv);

    std::cout << QUITOK << std::flush;
    is_running = false;
  }).detach();

  return 0;
}

ssize_t stockfish_stdin_write(char *data)
{
  return write(PARENT_WRITE_FD, data, strlen(data));
}

char *stockfish_stdout_read()
{
  struct pollfd fd;
  fd.fd = PARENT_READ_FD;
  fd.events = POLLIN;

  // Poll for max 100ms. If no data, return empty string so Dart can yield.
  int ret = poll(&fd, 1, 100);
  if (ret <= 0) {
    buffer[0] = 0;
    return buffer;
  }

  ssize_t count = read(PARENT_READ_FD, buffer, sizeof(buffer) - 1);
  if (count <= 0)
  {
    return NULL;
  }

  buffer[count] = 0;
  if (strcmp(buffer, QUITOK) == 0)
  {
    return NULL;
  }

  return buffer;
}

extern "C" {
  void stockfish_dispose() {
    // We no longer forcefully close the pipes in Hot Restart mode.
    // The engine persists as a daemon. 
    // If the user actually force closes the app, Android handles process cleanup.
  }
}
