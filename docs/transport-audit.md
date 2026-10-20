# Transport and audio audit

Audit date: 2026-10-20. No cloud credentials, microphone input, or ASR service
were used in these tests. This is an implementation/source audit and local
synthetic-I/O test report, **not** a claim of provider end-to-end success.

## Audited dependency

- Upstream: [ahyatt/emacs-websocket](https://github.com/ahyatt/emacs-websocket).
- [Pinned source](https://github.com/ahyatt/emacs-websocket/blob/3210187c107cdbb075b2e47454068a22f38213fc/websocket.el).
- Commit: `3210187c107cdbb075b2e47454068a22f38213fc`, latest commit touching the
  source according to the GitHub commits API at audit time.
- Downloaded unmodified into `.deps/websocket.el` before implementation.
- SHA-256: `95c653a3013288cad061394ea3ab175a8d6834caf19acf83e384f6c5cbf20ad2`.
- Package header says `1.16`, but its `websocket-version` variable says `1.12`.
  The variable is therefore **not** a reliable implementation fingerprint.
- Local environment: Emacs `31.1.50`, FFmpeg `7.1.1`, macOS; initial
  `locate-library` for websocket returned nil. Dependency loading is deferred
  until connect, so loading Vox does not require an installed websocket package.

At connect, the adapter checks required functions, native GnuTLS support, and
seven-argument handshake compatibility. Missing or incompatible APIs fail with
a fixed user-facing message. This signature check is not proof that an arbitrary
future upstream implementation is compatible; rerun these tests when upgrading.
Emacs 28/29/30 compatibility remains to be exercised on those runtimes.

## Frames and text encoding

The upstream source was read, not inferred from the API names:

- `websocket-read-frame` (lines 377-405) buffers partial **wire frames**; its
  `completep` field is the RFC FIN bit, not proof of a complete application
  message.
- `websocket-process-frame` (512-531) forwards `text`, `binary`, and
  `continuation` frames independently to `on-message`. It does **not** join
  fragments. Ping replies and close handling are done by upstream.
- `websocket-process-input-on-open-ws` (533-546) supports partial TCP reads and
  multiple wire frames in one read, retaining an incomplete tail in
  `websocket-inflight-input`.
- Payloads arrive as unibyte octets. Vox collects fragments in order, checks a
  total byte cap before retaining each fragment, and decodes UTF-8 only after
  the final text continuation. Split UTF-8 code points are therefore safe.
- Binary payloads remain unibyte without text decoding. Orphan continuations,
  overlapping messages, invalid UTF-8, and nonbinary wire input fail closed.
- Both whole messages and fragments are limited to 1 MiB by default. A separate
  1024-fragment cap prevents unbounded lists of zero-length fragments. The
  underlying incomplete-wire accumulator is also guarded: 16 KiB during HTTP
  upgrade and message-cap plus 14 bytes afterward. A single unusually large
  coalesced process read can be rejected conservatively even if it contains
  several individually legal messages; this is an explicit memory-safety bias.
- `websocket-send-text` (548-555) encodes using `raw-text`. Vox explicitly
  UTF-8-encodes text before passing its octets to this API. Binary sends use
  `websocket-send` with a complete binary frame. Tests inspect actual encoded
  frames using the real upstream decoder.

Tests use self-generated frames and synthetic HTTP upgrades, not claimed vendor
fixtures. Transport does not implement or reinterpret Qwen/Doubao wire formats.

## Asynchronous connection compatibility deviation

Upstream `websocket-open :nowait t` calls `websocket-ensure-handshake` immediately.
The latter (758-774) permits `connect` status when `nowait` is true, then calls
`process-send-string`. Emacs documents that writing to a not-yet-connected
nonblocking network process blocks until setup completes. Merely passing
`:nowait t` is therefore insufficient. Furthermore, upstream's later sentinel
calls the same helper at `open` status, which that helper excludes in nowait mode.

Vox installs a narrow around-advice on `websocket-ensure-handshake`:

1. It identifies only the dynamically opening Vox connection or a process marked
   with its Vox context. Unrelated websocket clients pass through unchanged.
2. At `connect` status it defers the handshake; the original sentinel will run
   again when the connection opens.
3. At `open`/`run` status it calls the original helper with `nowait=nil` so its
   existing status test permits the handshake. The socket itself was created
   asynchronously; this does not reopen it synchronously.
4. Upstream still constructs all HTTP headers and RFC frames. No parallel
   WebSocket protocol implementation was introduced.

**Deviation from the ideal public-API-only adapter:** the handshake helper,
`websocket-conn`, and `websocket-inflight-input` are implementation details. The
shim is necessary for the audited release's asynchronous behavior and for an
input-buffer bound. Its presence/signature are checked, its behavior is covered
by actual upstream-backed tests, and the exact source is pinned above. The
advice remains installed but is an identity pass-through for non-Vox sockets.
Replacing or upgrading websocket.el requires re-auditing these details.

Upstream's invalid-upgrade error path calls close, then error, and subsequently
still assigns `open` and attempts its open callback (785-815). Vox latches close
before notifying Core, suppressing that later open. A premature close is an
error at the provider/Core layer, never authoritative ASR completion.

## Input chunking correction - 2026-10-20

The original pre-parse bound compared the entire incoming callback plus retained
bytes against one message's budget. That rejected legal messages when TCP
coalesced them. The corrected guard probes bounded prefixes and delivers at most
one complete frame per upstream-filter call; message acceptance no longer depends
on process-filter chunk boundaries.

- Handshake input is capped at 16 KiB and stops exactly at the header terminator.
  If the same callback contains data, the next iteration applies the open-frame
  budget instead of continuing under the larger handshake allowance.
- Data-frame wire prefixes stay within `vox-transport-max-message-bytes + 14`;
  control frames use the protocol's 125-byte payload budget plus 14 header bytes.
  The existing fragment-message size and count checks remain separate.
- `websocket-get-opcode`, `websocket-read-frame` and `websocket-frame-length` are
  additional upstream implementation dependencies, checked before connecting.
  The guard reuses them to find boundaries; it does not implement frame decoding.
- Probe size grows geometrically from a small prefix, avoiding a message-sized
  copy for every tiny frame in a large callback. The original upstream filter
  parses the admitted prefix again. This adds bounded parsing/copying overhead;
  byte-at-a-time delivery still inherits upstream repeated-concatenation costs.
- Each iteration rechecks liveness. A message callback that closes the session
  prevents later data delivery and automatic ping replies in that same callback.

The transport-only suite now passes 29 tests, including all 65 split positions
for two small frames, 1000 coalesced messages, a handshake followed by 600 frames,
control payload boundaries, byte-split masked extended frames, exact 16 KiB
handshakes, overflow rejection, and reentrant close. These remain offline tests
using the real upstream parser and a mocked native stream, not live TLS proof.

## TLS and privacy

- Only `wss` URLs are accepted. Userinfo, URL fragments, CR/LF/NUL, and header
  injection are rejected without quoting the rejected data.
- Native GnuTLS is mandatory; there is no external TLS-program fallback.
- `gnutls-verify-error=t` is dynamically bound during asynchronous socket
  creation. The local Emacs `open-gnutls-stream` creates `gnutls-x509pki` boot
  parameters immediately, including the hostname and `:verify-error t`, before
  asynchronous connection work proceeds. Both trust-chain and hostname failures
  are fatal even if the user's normal default is permissive. The nowait path
  skips later NSM prompting, making this boot-time verification essential.
- Tests assert the `:verify-error t` boot parameter and `:nowait t`. No live
  certificate rejection/hostname-mismatch integration test has been run.
- Upstream `websocket-debug` logs raw inbound bytes (including upgrade headers)
  and outgoing payloads. Guarding just the application callback is too late.
  Vox disables both websocket debug controls around initial open, its wrapped
  process filter, its wrapped sentinel, and each send. This includes upstream
  ping replies and parsing failures. Settings for unrelated clients are not
  globally changed. Tests run with both global debug settings enabled and
  verify no Vox debug buffer is created.
- All callback bodies have generation/liveness guards and contain errors.
  Raw upstream exception data, payloads, URL contents and headers never reach
  the error callback or `message`. Error strings are fixed constants.
- Closing for resource reclamation deletes the socket directly instead of
  sending a close frame that could block on a congested peer. Provider finish
  and authoritative completion must occur before normal cleanup. Explicit
  cleanup is silent and idempotent; remote close notifies at most once.
- This does not claim secret protection from an attached debugger, process
  inspection, or user-installed instrumentation. Upstream process objects and
  closures necessarily hold connection/handshake data in memory.

## Send queue and responsiveness limits

Upstream documents at lines 71-75 that W3C `bufferedAmount` is not implemented
because no corresponding Elisp process-buffered-output API is available. It has
no application output queue to query: `websocket-send` (570-596) directly calls
`process-send-string`. Emacs `process-contact` reports connection parameters,
not pending transmit bytes; `process-attributes` is not a reliable socket send
queue measurement either. No reliable pending-send byte count was identified.

Consequences:

- Core must impose its bounded PCM FIFO and bounded flush work per tick.
  Delivered-to-socket byte counters are not server acknowledgements and must
  not be described as delivery confirmation.
- Vox does not poll, sleep, or call `accept-process-output` in production code.
  Audio subprocesses and connection setup are asynchronous.
- Each outbound frame is capped and each send is timed. A write taking longer
  than `vox-transport-send-timeout` (default one second) fails the session
  **after the native call returns**.
- A native `process-send-string` can itself block, accept process output, or
  reenter callbacks. Timers cannot preempt such a native write reliably. The
  measured threshold is a post-return detector, **not** strict nonblocking I/O,
  an enforceable in-flight deadline, or strict network backpressure.
- No claim is made of precise socket queue bounds or ten-minute latency/GC
  performance. Those require separate measurements, and perhaps upstream API
  support, beyond a bounded Core queue.

## FFmpeg ownership, stop and stderr

The [audio adapter](../vox-audio.el) accepts an explicit argv list; input defaults
to nil and no microphone is guessed. It uses no shell, writes raw PCM16LE at
16000 Hz mono to stdout, rejects multibyte filter strings, and delegates all
chunking/backlog policy to Core. An independent binary stderr pipe has no buffer;
its filter discards text and retains only a saturated byte counter. Even device
names and input URLs can be sensitive, so truncated raw stderr is not retained.

Stop calls `interrupt-process` without waiting and leaves stdout attached until
the terminal sentinel. Its documented, dynamically scoped interrupt hook sends
SIGINT only to the recorder PID, not an unrelated inherited process group.

A local FFmpeg 7.1.1 infinite lavfi source continued after one SIGINT. This was
reproduced **outside Emacs** in a shell, so it was not just an Elisp filter or
startup-timing artifact. A second SIGINT terminated it with exit status 255.
The adapter therefore schedules at most one guarded retry after 0.5 seconds if
still alive. It records `:audio-interrupt-retries=1` and `:audio-tail-risk=t` in
session statistics. This is explicitly a possible tail-loss path, not a claim of
lossless stop. No further escalation occurs here; Core owns its final timeout.
The sentinel accepts status 0, or requested SIGINT/FFmpeg status 2/255. Other
exits produce a fixed capture-failure message.

Cancel detaches callbacks, cancels the retry timer, and reclaims both processes.
Captured late callbacks check recorder identity as well as session generation.
Natural exit, interrupt exit, start failure, callback errors, duplicate stop,
duplicate cancel, stale generations, stderr cleanup and retained timer callbacks
are tested. No audio or diagnostics are persisted.

## Reproduction and results

```sh
emacs -Q --batch --eval '(setq load-prefer-newer t)' \
  -L . -L .deps -L test \
  -l test/vox-test-audio.el -l test/vox-test-transport.el \
  -f ert-run-tests-batch-and-exit
```

Final local result: **31/31 ERT tests passed** on 2026-10-20. Both production
files strictly compiled with warnings treated as errors without websocket on
load-path; both test files strictly compiled with the audited dependency.
A process-list check found no remaining synthetic FFmpeg capture processes.

The two suites include real local finite lavfi capture (30 ms gives exactly 960
PCM bytes) and infinite lavfi interrupt-to-sentinel capture. All network I/O in
the transport suite is mocked at the native stream boundary while real upstream
upgrade parsing, masking, encoding, decoding and continuation dispatch execute.
The production adapters also strictly byte-compile without websocket installed;
test compilation uses the audited dependency. Compilation was performed in memory
without writing extra artifacts.

Still unverified: actual microphones/OS permission prompts; real provider
handshakes and final events; live bad-certificate rejection; congested-network
behavior and ten-minute performance; Emacs 28/29/30 and Linux audio devices.

## Follow-up: reentrant stream ordering, 2026-10-20

This follow-up records **uncommitted work based on `42bbec9`**, not a revision of
what the earlier 31-test run established. No microphone, real credentials, or
provider connection was used. See [decision 005](../postmortems/005-reentrant-stream-ordering.md)
for rationale and the accepted buffering tradeoff.

Deterministic synthetic reproductions exposed these defects:

- A timer reentering the PCM tail send emitted the tail twice and attempted a
  second transition to finalizing. Reentrant ordinary capture nested sends and
  bypassed the per-pump work budget. A recorder-ended callback could dispatch
  finish while an earlier PCM send was still on the stack.
- A pong write reentering receive processing delivered newer messages before an
  older callback's unread suffix, or rejected an otherwise valid continuation.
  A terminal process sentinel could likewise overtake already-received data.
- Quitting a PCM send left a recording active after dequeuing an uncertain frame;
  quitting input processing could leave a live connection after abandoning its
  unread suffix.
- Doubao's post-write mutations restored PCM/adapter state after cancellation had
  already cleaned the session. The final-packet path also recreated cleared state.

The regressions failed before their respective fixes. Core now has one
session-local send/finish owner. Transport queues reentrant input and terminal
notifications in arrival order, bounded to 2 MiB and 1024 active/queued callbacks
by default. Empty reads create no entries, and disposal drops pending input.
Callbacks keep their full byte charge until consumed, so a large coalesced read
may be rejected even when each contained message is legal. Upstream still owns
WebSocket parsing and framing. Interrupted I/O terminates safely, and Doubao no
longer mutates retained state after a yielding write.

Independent review caught a compatibility edge in the FIFO change: the audited
upstream parser reports protocol CLOSE as one consumed byte. Deferring its native
terminal callback would let the length/status/reason be parsed as more frames.
A protocol-close latch now stops wire parsing and permits its terminal callback
immediately, while queued asynchronous EOF notifications still drain in order.
Regressions cover empty and valid status-1000/reason CLOSE, immediate/delayed
sentinels, trailing input, and already-queued EOF without a second notification.

Verification environment: macOS, Emacs **31.1.50**, FFmpeg **7.1.1**.

| Check | Result |
| --- | --- |
| `scripts/verify.sh` | PASS: syntax, tooling/runner self-tests, strict temporary-output compilation, dependency checks, complete suite, silent load, whitespace, hygiene |
| `emacs -Q --batch -l test/vox-test.el` | 263/263 passed; 0 unexpected, 0 skipped |
| Focused PCM/core regressions | 14/14 passed, including new-session replacement, stale timers, send failure and quit |
| Focused transport regressions | 40/40 passed using real upstream framing and synthetic pipes |
| Focused Doubao regressions | 21/21 passed, including cancellation during ordinary and final writes |
| Consecutive synthetic FFmpeg captures | Positive and negative constant sources each matched all 480 expected PCM16LE samples; stale prior-process callback did not contaminate the next capture |
| `scripts/benchmark.el` | 600 synthetic seconds, 6000 frames, 19200000 bytes, final commit and cleaned resources; accelerated elapsed 0.258990 s, queue peak 3200 bytes; not a wall-clock capture/network benchmark |

There are 20 added product tests relative to the base commit. These checks prove
specific ordering, cleanup, and synthetic PCM properties; they do not establish
that those races caused any particular live recognition result. Actual input
selection/quality, recognition accuracy, provider timing, the FFmpeg interrupt
retry's tail risk, and the supported Emacs-version matrix remain separate live
acceptance work. No VAD threshold, model, language, or sample rate was changed.

## Note: combined diagnostics/CLI tree, 2026-10-20

The 263/263 and 20-test figures in the 005 table above are the 005 baseline; they
are not the count for the combined 005+006 staged tree. On that combined tree,
`scripts/verify.sh` passes and `emacs -Q --batch -l test/vox-test.el` runs
**300/300** product tests with 0 unexpected and 0 skipped. The added coverage
includes reentrant CLI stdout/terminal ordering, multi-round session isolation,
bounded event-log fields and buffer safety, empty-recognition diagnostics, and
the exact 1.2 s silence boundary. These remain offline checks; microphone,
provider accuracy, and network timing are still separate live acceptance work.
