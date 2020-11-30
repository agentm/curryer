# Curryer - Fast Haskell-to-Haskell RPC

Curryer (pun intended) is a fast, Haskell-exclusive RPC (remote procedure call) library. By using the latest Haskell serialization and streaming libraries, curryer aims to be the fastest and easiest means of communicating between Haskell-based processes.

Curryer is inspired by the now unmaintained [distributed-process](https://hackage.haskell.org/package/distributed-process) library.

## Features

* blocking and non-blocking remote function calls
* asynchronous server-to-client callbacks (for server-initiated notifications)
* timeouts
* utilizes versionable shared ADT for communication instead of shared function `StaticPtr`s