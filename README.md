# zicwatch

zicwatch lets coding agents check the results of a long-running `zig build --watch`.

With incremental compilation (`-fincremental`), a watching build gives feedback in milliseconds,
but its output is a terminal stream that agents can't easily follow. zicwatch reads that stream,
keeps the latest result and diagnostics of every step, and answers queries on a Unix socket. An
agent edits a file, waits for the next build and gets back JSON with the failing steps and their
compiler errors.

Requires Zig 0.17.0. Tested on Linux.

## Build

```sh
zig build -Doptimize=ReleaseSafe
# binary: zig-out/bin/zicwatch
```

## Serving

`zicwatch serve` follows one build and answers on the socket given with `--socket`. It takes its
input in one of three ways:

```sh
# 1. Read the output of a build you start yourself.
zig build install --watch -fincremental --color off --summary new 2>&1 \
    | zicwatch serve --socket zig-out/watch.sock

# 2. Start the build itself and parse its output. Arguments after -- go to zig build.
zicwatch serve --socket zig-out/watch.sock --steps install,test -- -Doptimize=Debug
#    runs: zig build install test -Doptimize=Debug --watch -fincremental --color off --summary new

# 3. Start the build itself and use the build system protocol (experimental).
zicwatch serve --socket zig-out/watch.sock --steps install,test --bsp
#    runs: zig build -fincremental --listen=-
```

In modes 2 and 3, zicwatch echoes build output to stderr, and Ctrl-C or SIGTERM stops the build
too. When the build exits, zicwatch keeps answering with the last results until it is stopped.

Mode 3 depends on parts of Zig's build system protocol that are still unfinished: Zig panics when
zicwatch disconnects, and output of failing run steps is not reported yet. Compile and install
steps work.

## Querying

```sh
zicwatch mark   --socket PATH                    # cursor for the latest build
zicwatch wait   --socket PATH --after CURSOR [--step NAME] [--timeout 60s]
zicwatch status --socket PATH [--step NAME]      # latest build, immediately
```

Take a cursor with `mark` before editing, then `wait --after` that cursor. `wait` returns as soon
as a build newer than the cursor completes, so it doesn't report results from before the edit.
Timeouts accept `ms`, `s` and `m`; plain numbers are seconds.

Step names must be given in full, as printed in the build summary, such as `install app` or
`compile exe app debug native`. Without `--step`, results cover the whole build. An unknown name
returns the steps whose names contain it, or all steps.

Exit codes: 0 success, 1 build failure, 2 anything else (timeout, no build yet, unknown step,
no server). Every result is a single JSON object on stdout:

```json
{
  "cursor": "7689df7c:5",
  "build": 5,
  "summary": "Build Summary: 54/67 steps succeeded (1 failed)",
  "outcome": "failure",
  "step": {"name": "install editor", "status": "transitive_failure", "updated_in_build": 5},
  "failures": [
    {
      "step": "compile lib physics fast native",
      "updated_in_build": 5,
      "diagnostics": "src/physics/collision.zig:10:46: error: expected ',' after parameter\n...",
      "truncated": false
    }
  ],
  "stream_ended": true,
  "stream_end_reason": "stdin ended"
}
```

`failures` lists the steps that actually failed, not the ones that only failed because a
dependency did. Errors have the form `{"error": "timeout", "message": "..."}`.

## Agent instructions

Paste something like this into your agent's instructions and adjust paths and step names:

```
A zig build is watching this project. After editing, check the build:
  c=$(../zicwatch mark --socket zig-out/watch.sock | jq -r .cursor)
  # edit files
  ../zicwatch wait --socket zig-out/watch.sock --after "$c" --step "install app"
Exit code 0 means the step built, 1 means it failed (see "failures"). Step names must be full,
e.g. "install app" or "compile exe app debug native".
```

## License

MIT
