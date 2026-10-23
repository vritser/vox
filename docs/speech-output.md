# Speech output

Vox accepts incremental text through Qwen Realtime, Doubao bidirectional
WebSocket, or a trusted streaming CLI. All TTS adapters support text input and
audio output streaming in the same session.
`M-x vox-speak` reads the active region, or prompts for text
without adding the text to minibuffer or command history. Lisp callers use
`(vox-speak "Hello")`.
Audio is sent to one persistent player as it arrives. `M-x vox-speak-stop`
cancels synthesis and playback and discards queued audio. Speaking again or
starting recording also interrupts output. These voices are AI-generated.

Install `ffplay`, the player distributed with FFmpeg, or configure
`vox-tts-player-command` with an executable argv list that reads encoded audio
from stdin and exits after EOF. Some FFmpeg installations omit ffplay; recording
can work even when this optional player is missing. No Python/Node bridge or
additional network executable is needed for the API backends.

## Incremental text input

Select Qwen (`tts-qwen-realtime`), Doubao (`tts-doubao-ws`) or a CLI, then retain
the session returned by `vox-speak-open`:

```elisp
(setq speech (vox-speak-open))
(vox-speak-send speech "Hello, ")  ; call whenever the producer has more text
(vox-speak-send speech "world.")
(vox-speak-finish speech)         ; producer EOF; keep receiving/playing audio
;; Or interrupt instead:
;; (vox-speak-stop speech)
```

In a real integration, call `vox-speak-send` from the text producer's incremental
callback. Text need not form a sentence, and no newline is added. Readiness is
asynchronous: bounded text can be queued before the server acknowledges the
session. Each transport write contains at most 256 characters without splitting
Unicode characters. `vox-speak-finish` closes text input only after queued writes;
completion still waits for the provider and player. Empty/whitespace-only input
cannot be finished. Sending after finish, cancellation or replacement is rejected.
The captured handle also lets a producer cancel its own session without stopping
a successor. The producer should stop forwarding text when its session is ended;
Vox does not cancel an external LLM request.

`vox-speak` remains the convenience entry for already-complete text. With a
streaming-input protocol it queues that text through the same bounded writer and
finishes input. It does not pace generation to speaker playback or prevent an
already-available paragraph from reaching the server quickly. For genuinely
incremental input, use open/send/finish as text becomes available.

Single-request HTTP TTS protocols are not supported. The preliminary OpenAI,
Qwen HTTP and Doubao SSE adapters have been removed; there is no fallback that
buffers a producer's entire output before submitting it.

## Interruption and billing

Interrupting immediately discards unsent text and pending audio. Doubao receives a
best-effort `CancelSession`; Qwen receives `input_text_buffer.clear` before the
connection is reclaimed. Clearing Qwen’s text buffer does not promise to cancel
a response already being generated. Cancellation never sends `session.finish`,
which would ask the service to synthesize the remaining buffered text. If a socket write
is in progress or its delivery became uncertain after interruption/failure, Vox
closes it without appending a cancel frame. No cancellation
acknowledgement or billing adjustment is inferred from a successful local stop.
Already submitted text or generated audio may still be billed under the provider's
rules. Incremental input prevents later, unsent text from reaching the service;
it does not make an accepted request free. See [Doubao billing](https://docs.volcengine.com/docs/DoubaoVoice/Billinginstructions-21?lang=zh).

## API configuration

Use the same `vox-backends` directory as recognition. A service's `:tts`
capability inherits its top-level host and key, with optional overrides:

```elisp
(setq vox-backends
      (list
       (vox-make-qwen "Qwen"
         :key nil
         :asr '(:models (qwen3-asr-flash-realtime))
         :tts '(:models (qwen3-tts-flash-realtime) :voice "Cherry"))
       (vox-make-doubao "Doubao"
         :asr nil
         :tts '(:resource-id "seed-tts-2.0"
                :voice "zh_female_vv_uranus_bigtts"))))
(setq vox-asr-selection '("Qwen" qwen3-asr-flash-realtime)
      vox-tts-selection '("Qwen" qwen3-tts-flash-realtime))
```

`M-x vox-tts-select` offers only TTS-capable services. Nil selection uses the
first TTS-capable service and its first model. Doubao selects its resource ID;
named CLI capabilities use `(NAME nil)`. ASR selection remains independent, so
recognition and speech can use different providers. To use another voice,
configure another named service or edit its `:tts` plist for future sessions.

`:key nil` reads auth-source for the effective host and login `apikey`. Literal
strings and zero-argument key functions follow the same convention as ASR.
A capability inherits an omitted key but can explicitly override it with nil.
Constructors and pickers never read keys or connect. Starting API speech sends
the supplied text to that service and may incur charges. See
[shared configuration and migration](customization.md#backends-and-models).

Default TTS endpoints are:

| Constructor | Host | TTS endpoint |
| --- | --- | --- |
| `vox-make-qwen` | `dashscope.aliyuncs.com` | `/api-ws/v1/realtime?model=qwen3-tts-flash-realtime` (WSS) |
| `vox-make-doubao` | `openspeech.bytedance.com` | `/api/v3/tts/bidirection` (WSS) |

Put a custom endpoint inside `:tts`; host and key can be shared or overridden.
Qwen/Doubao require `:tts t` or a TTS plist to enable speech output.

Qwen uses `qwen3-tts-flash-realtime` and voice `Cherry` by default. It waits for
`session.created`, sends `session.update` with `server_commit`, then waits for
`session.updated` before sending `input_text_buffer.append`. The service chooses
synthesis boundaries; Vox does not artificially split sentences or send repeated
HTTP requests. `response.audio.delta` supplies Base64 PCM (16-bit little-endian
mono, 24 kHz), wrapped in one streaming WAV header for the player. Each response's
`response.done` must succeed; only `session.finished` after input finish completes
synthesis. Beijing and Singapore public endpoints are supported; use credentials
from the selected region. Qwen Audio/CosyVoice task-based TTS uses a different
protocol and is not implemented here.

Doubao uses V3 bidirectional WebSocket with `X-Api-Key` authentication. It waits
for `ConnectionStarted` and `SessionStarted`, sends text as `TaskRequest`, and
uses `FinishSession` only when input ends. The resource and voice must match the
service enabled on your account. Legacy app-ID/access-token authentication is not
implemented.

For migration from the preliminary HTTP adapters, remove `:protocol tts-qwen`,
`:protocol tts-doubao`, and their explicit HTTP endpoints. Use the constructors'
new defaults; change Qwen's model to `qwen3-tts-flash-realtime` in both `:models`
and `vox-tts-selection`. Doubao's resource/voice settings need no change.
`vox-make-openai` has been removed. Restart Emacs after updating: removed
definitions and changed session structures are not migrated by `vox-reload`.

API synthesis requires websocket.el, native GnuTLS and WSS. Non-default hosts or
ports prompt before key lookup; headless callers refuse unapproved custom hosts.

## CLI contract

```elisp
(setq vox-backends
      (list (vox-make-cli "Local"
              :tts '(:command ("/absolute/path/to/your-tts" "--stdout")))))
(setq vox-tts-selection '("Local" nil))
```

This is a command-shape example, not an installed executable. Configure a program
or wrapper with the following contract:

1. Read UTF-8 text incrementally from stdin. Vox keeps stdin open across
   `vox-speak-send` calls and sends EOF only after `vox-speak-finish` drains the
   text queue. It adds no newline or JSON envelope. The CLI must synthesize and
   flush audio while stdin remains open; an EOF-buffering tool does not satisfy
   this streaming contract.
2. Write and flush chunks of one encoded audio stream, such as WAV or MP3, to
   stdout. Playback starts before the CLI exits. Send diagnostics to stderr; Vox
   discards them. Progressive output is required for low-latency interruption.
3. Exit zero only after producing successful nonempty output. Nonzero exit,
   overflow, timeout or cancellation stops playback and discards pending audio.
   Audio already played before a late failure cannot be withdrawn.

The command receives no interpolated shell text and no text arguments. It must
not play audio itself, detach children or leave subprocesses running after it
is terminated. Arbitrary installed TTS tools may need a wrapper to meet this
contract. The trusted executable owns its dependencies, networking, credentials
and any files it creates. The ASR CLI's NDJSON contract is unrelated.

## Ownership, limits and diagnostics

Starting another utterance cancels the previous one. Starting recording stops
speech output; speech cannot start while recording or recognition startup owns
Vox. Stop output before `vox-reload`. Playback does not change buffer contents.

Vox keeps text and audio in memory. Qwen PCM, Doubao MP3 and CLI stdout feed a
bounded FIFO. A timer sends at most 4096 bytes per turn to one player's stdin;
EOF follows successful synthesis and queue drain. Authoritative WebSocket
completion after input finish, or zero CLI exit after stdin EOF, is required.
The player must then exit zero for the session to complete. A truncated stream,
provider error or early player exit stops both sides, even after partial playback.

Cancellation reclaims the owned WebSocket/CLI and player processes, cancels
phase, handshake and input/output pump timers, and clears pending text and audio. Late callbacks cannot affect the
next utterance. Starting recording interrupts output; this is not automatic
voice-detected barge-in or simultaneous recording and playback.

The default ffplay command limits probing (`-probesize 32768 -analyzeduration 0`)
to reduce startup buffering. A custom player must decode stdin progressively;
players requiring a complete seekable file cannot provide streaming playback.
Decoder/device buffering still affects audible latency. Native process writes
can block; timeouts and interruption depend on the Emacs event loop returning.
Already submitted device samples cannot be recalled. This version does not
automatically connect to an LLM, split documents into separate synthesis sessions,
clone voices, or manage a playlist.

| Option | Default |
| --- | --- |
| `vox-tts-max-text-chars` | 4096 total characters per session, captured at open |
| `vox-tts-max-audio-bytes` | 16 MiB |
| `vox-tts-max-response-bytes` | 24 MiB per WebSocket synthesis session, including application framing |
| `vox-tts-max-pending-bytes` | 2 MiB queued for the player, including an in-flight write |
| `vox-tts-timeout` | 60 seconds from open until synthesis completes, including producer input time |
| `vox-tts-playback-timeout` | 600 seconds from player startup through player exit |

The text FIFO holds at most 4096 fragments, including the in-flight fragment.
The playback FIFO holds at most 4096 nonempty chunks. WebSocket messages and
retained input additionally obey the shared `vox-transport-*` bounds. Qwen allows
at most 4096 active response IDs. Overload fails the session instead of dropping
audio. Large coalesced reads can exceed the pending-byte limit even when the whole
utterance fits the total-audio limit. Qwen's 44-byte WAV header counts toward the
audio and player-queue limits. Service limits may be lower.
Playback success means the player exited zero, not proof that a physical speaker
was audible. Errors show a fixed message without provider bodies, private text,
audio or credentials. Check executable availability, configuration, voice/resource
pairing and account service access. `M-x vox-doctor` checks TTS selection, player
and CLI executables, endpoint trust, credential source, limits and active state.
It does not resolve keys, contact the provider or play audio. Its player result
confirms executable availability only, not audible output or stdin compatibility.
TTS-only API configurations also require the websocket dependency check; endpoint
diagnostics identify WSS.
Unconfigured TTS is skipped; see [self-check](customization.md#self-check).

## Protocol references and evidence

Implementation references checked on 2026-10-23 (Qwen) and 2026-10-22 (Doubao):

- [Qwen Realtime connection guide](https://help.aliyun.com/en/model-studio/interactive-process-of-qwen-tts-realtime-synthesis).
- [Qwen client events](https://help.aliyun.com/zh/model-studio/qwen-tts-realtime-client-events)
  and [server events](https://help.aliyun.com/zh/model-studio/qwen-tts-realtime-server-events).
- [Doubao bidirectional WebSocket V3](https://docs.volcengine.com/docs/DoubaoVoice/WebSocketBidirectionalStreaming-V3?lang=zh).

[Qwen tests](../test/vox-test-tts-qwen.el),
[Doubao/incremental-input tests](../test/vox-test-tts-input.el) and
[player/CLI tests](../test/vox-test-tts.el) use synthetic events and local processes.
These are offline regressions, not live-provider acceptance. Authentication,
current model/voice availability, physical playback, regional endpoints and
supported Emacs-version CI remain separately unverified.
