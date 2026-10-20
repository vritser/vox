# Provider protocol audit

Audit date: 2026-10-20. Status: offline protocol implementation and ERT only.
Neither provider has been exercised with a real API key, microphone, or live
recognition stream. Doubao is explicitly registered as experimental.

## Sources and retrieval

The required `web_fetch` requests were attempted first for the Qwen client event,
Qwen server event, and Doubao realtime pages. All three returned the tool error
`URL hostname ... resolves to a non-public IP address`. The same official public
pages were then opened and read successfully using the browser. This is not a
claim that `web_fetch` succeeded.

- [Qwen client events](https://help.aliyun.com/zh/model-studio/qwen-asr-realtime-client-events)
  (page updated 2026-10-10): `session.update`, PCM/base64 append, prohibited VAD
  commit, and `session.finish`.
- [Qwen server events](https://help.aliyun.com/zh/model-studio/qwen-asr-realtime-server-events)
  (page updated 2026-10-10): `text` plus `stash`, per-item `transcript`, failures,
  `session.updated`, and authoritative `session.finished`.
- [Qwen interaction flow](https://help.aliyun.com/zh/model-studio/qwen-asr-realtime-interaction-process)
  (page updated 2026-10-10): handshake headers, legacy domains still supported,
  workspace-specific domains, VAD/manual ordering.
- [Qwen user guide](https://help.aliyun.com/zh/model-studio/real-time-speech-recognition-user-guide)
  and [model access](https://help.aliyun.com/zh/model-studio/qwen-asr-realtime-model-access)
  were used to locate the current interaction page, not to borrow protocols from
  the separately documented Qwen-Audio-ASR-Message model.
- [Doubao realtime SeedASR documentation](https://docs.volcengine.com/docs/DoubaoVoice/bidirectional-streaming-automatic-speech-recognition-websocket?lang=zh)
  (page updated 2026-09-28): exact `bigmodel_async` endpoint, SeedASR 2.0 resource
  IDs, current API-key headers, request fields, and response wrapper semantics.
- The `sauc_python.zip` and `sauc_go.zip` download buttons on that exact Doubao
  realtime page were used. Both archives were downloaded; the relevant source
  files were extracted and read, **not run**, imported, built, or installed.
  The Go download request resolved to
  [the official CDN archive](https://portal.volccdn.com/obj/volcfe/cloud-universal-doc/upload_5ff69c9c8092969c2ec0e6298ebe87d7.zip).
  The page's download button generated a browser blob URL for each download;
  the document link plus the content hashes below identify both references.

Archive hashes (SHA-256):

```text
sauc_python.zip  684012ec72c56d509b361ab8d6ecd41c107ecfc593602a75b7da99f41f3f8a22
sauc_go.zip      e145d72638e942a0913ab7e352baf4ed79a026b38bba0cd31b20b8292b3efa64
```

Downloaded references and fixture provenance are listed in
[the fixture manifest](../test/fixtures/README.md). They are not runtime
requirements. No Python bridge, Python dependency, or Node runtime dependency
is introduced.

## Qwen findings

- Default URL uses the documented, still-supported Beijing public host:
  `wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime`.
  Singapore public host `dashscope-intl.aliyuncs.com` is also allowlisted.
  Workspace-specific hosts may be entered as a complete custom endpoint and
  require the shared endpoint confirmation; no unresolved WorkspaceId template
  is sent and arbitrary subdomains are not automatically allowlisted.
- The current interaction page requires `Authorization: Bearer KEY`. Its header
  table does **not** require `OpenAI-Beta: realtime=v1`; this adapter does not
  invent that requirement from an OpenAI or older Qwen example. Live handshake
  validation remains outstanding.
- The outbound `session.update` requests `pcm`, 16000 Hz, `server_vad`, threshold
  0.0, and 400 ms silence by default. The server page has legacy-looking example
  values (`pcm16`, even a GPT model in `session.updated`); these examples are not
  copied into the outbound configuration. The client event field definition is
  authoritative for the outbound `pcm` value.
- Recording starts only after `session.updated`, once. Sending before ready or
  after finish/close is rejected. Event IDs combine the session ID, generation,
  and local event counter.
- `text + stash` is a whole per-item partial replacement, not a delta. The final
  `transcript` replaces that item. After an item final, late partials for that
  item are ignored. Core preserves first-seen segment order.
- Only VAD mode is implemented. Stop sends `session.finish` once, after PCM;
  it never sends `input_audio_buffer.commit`. Manual mode is intentionally not
  exposed, avoiding an unsupported long-session manual buffering policy.
- Only `session.finished`, after client finish, yields `:completed`. Socket
  closure is an error unless cancellation/close or completion was already
  recorded. Item transcription failures and server errors are not completion.
- Provider error strings are static diagnostics; raw server messages, echoed
  parameters, audio, and credentials are never forwarded as errors.

## SeedASR bigmodel_async wire contract

This is grounded in the downloaded realtime examples, not the unrelated TTS
protocol or an assumed older ASR framing example.

### Authentication and request JSON

Headers: `X-Api-Key`, `X-Api-Resource-Id`, `X-Api-Request-Id` (UUID-shaped request
identifier). Default resource: `volc.seedasr.sauc.duration`, the documented 2.0
hourly resource. The examples also support old app-key/access-key credentials;
Vox deliberately supports only the current API key flow.

The JSON uses `user`, `audio`, and `request`. `audio` is raw PCM, 16000 Hz,
16-bit, mono. `request.model_name` is **`bigmodel`**, not `seedasr`.
`result_type` is fixed to **`full`**, `show_utterances` is true, and
`enable_nonstream` defaults to true for second-pass revisions. False is emitted
as an explicit JSON false, not null.

### Outbound binary envelope

Every integer in the ASR envelope is big-endian. Sequence values are signed
32-bit; payload lengths are unsigned 32-bit.

| Message | Header bytes | Optional fields after header | Payload |
| --- | --- | --- | --- |
| Full client request | `11 11 11 00` | `int32 seq=1`, `uint32 size` | gzip UTF-8 JSON |
| Audio, nonfinal | `11 21 11 00` | `int32 seq=2,3,...`, `uint32 size` | gzip raw PCM |
| Audio, final | `11 23 11 00` | `int32 seq=-N`, `uint32 size` | gzip last raw PCM |

The first byte is version 1 and header size 1 four-byte unit. The second byte's
high nibble is message type (1 full / 2 audio), and the low nibble is flags
(1 sequence present / 3 sequence present plus final). The third byte is
serialization 1 and compression 1; reserved byte is zero.

**Surprising but verified:** both the Python and Go audio request builders retain
the default JSON serialization nibble 1 while their payload is raw PCM. Vox
matches the actual examples, rather than silently changing audio to nibble 0.

Source anchors:
[Python request builder](../test/fixtures/official-sauc-protocol.py#L136-L230),
[Go header](../test/fixtures/official-sauc-header.go#L52-L59),
[Go payload builders](../test/fixtures/official-sauc-payload.go#L48-L81).

The examples use gzip for every outbound packet. Their header setters allow a
compression value override, but that is **not** evidence that this endpoint
accepts uncompressed outbound payloads. Vox therefore emits valid RFC 1952 gzip
with deterministic stored DEFLATE blocks (no compression, but a real gzip
container with CRC32/ISIZE). This is pure Elisp and needs no subprocess or
external compressor. The exact deflate bytes differ from Python's compressor;
wire equivalence is by decompressed bytes, CRC, and framing, not a fabricated
byte-for-byte equality to captured official frames.

### Readiness, audio, and end

Both examples send the full request and await one server response before
streaming audio. Vox waits for the first valid successful full response before
calling ready, and does not accept an error or premature last response as ready.

For live capture, Vox retains at most one PCM packet (maximum 6400 bytes) so the
last real audio can carry flags 3 and a negative sequence. This adds at most one
packet of latency. Finish sends that retained packet exactly once; cancel drops
it. No separate event ID or invented end message is added. Empty-audio finish
uses an empty gzip member in a final audio packet, which is logically consistent
with the encoder but is **not verified by the file-oriented official examples
or a live service**.

The Python example uses `send_bytes` for audio. The Go example's
[client writer](../test/fixtures/official-sauc-client.go#L81-L90) instead uses
`websocket.TextMessage` for the binary packet, conflicting with Python and the
binary protocol. Vox sends **binary WebSocket frames** and records this Go
example discrepancy rather than reproducing it.

### Inbound binary envelope

Header size is read from the low nibble of byte 0 and multiplied by four.
Optional header extension bytes are skipped. After that header:

1. Flags bit 0: read a signed `int32` sequence if present.
2. Flags bit 1: mark `is_last_package`; no extra field is consumed for this bit.
3. Flags bit 2: read an `int32` event if present.
4. Type 9 (full server response): read `uint32 payload_size`.
5. Type 15 (server error): read `int32 code`, then `uint32 payload_size`.
6. Read exactly that many payload bytes. Compression 1 means gzip, 0 means
   uncompressed; serialization 1 means UTF-8 JSON.

Vox rejects unsupported types/flags/codecs, bad version/reserved bytes,
truncation, trailing bytes, and oversized frames. One transport message must be
one protocol packet; transport must reassemble WebSocket continuation frames.
Concatenated independent protocol packets are rejected rather than guessed.

Source anchors:
[Python parser](../test/fixtures/official-sauc-protocol.py#L233-L303),
[Go parser](../test/fixtures/official-sauc-response.go#L29-L88).

**Important:** `is_last_package`, `payload_sequence`, `event`, `payload_size`,
and `payload_msg` in the website output example are the SDK's decoded wrapper.
They are not a second JSON envelope on the wire. The raw JSON body contains
`result`/`audio_info`; the authoritative final marker is **binary flags bit 1**.
Neither `utterances[].definite`, `additions.source=two_pass`, a JSON field named
`is_last_package`, nor socket close completes the session.

The page calls `result` a list in a field table, but its example JSON and the
Go typed response both use an object containing `text`. Vox supports that
observed object shape and rejects nonobject result shapes instead of inventing
concatenation semantics.

Full `result.text` is emitted as a replacing snapshot. The examples expose the
signed sequence but do not specify deduplication, monotonic ordering across
second-pass revisions, or absolute-value comparisons. Vox does not discard
revisions based on that undocumented assumption. It numbers snapshots by local
WebSocket receive order; the transport provides ordered message delivery.

## Tests and limitations

Offline tests cover client headers byte-for-byte, signed sequence/end flags,
optional sequence/event fields, extended headers, known CRC32/gzip vectors,
multiple stored-block boundaries, native zlib roundtrips, independently produced
compressed fixtures, all truncation points of a response, malformed/oversized
lengths, unknown fields, error sanitization, readiness, replacing snapshots,
late Qwen partials, and exactly-once stop/cancel/close behavior.

The Qwen JSON examples are copied from the cited official page; the Doubao
binary fixtures are explicitly **synthetic**, built independently using Node's
standard gzip library only during fixture authoring. No official sample was
executed. No fixture is claimed to be a real server capture. Node is not needed
to load Vox or run ERT. See [fixture manifest](../test/fixtures/README.md).

Unverified or intentionally limited:

- Actual account entitlement, region/workspace/key pairing, WSS handshake,
  response timing, and microphone transcription for either provider.
- SeedASR acceptance of stored-block gzip, raw PCM live streaming, empty-audio
  finish, and real server final flags. The examples establish the protocol
  contract, not a completed integration test.
- Both API-error variants, quiet/no-speech streams, real second-pass revisions,
  long sessions, cancellation races, and network failure require live tests.
- Native Emacs zlib is required for gzip responses; absent support fails before
  connecting. Encoded length and advertised gzip ISIZE are capped at 1 MiB and
  decoded size is checked. `zlib-decompress-region` has no hard output-limit
  argument: a malicious gzip member with a forged footer may allocate memory
  before rejection. This is **not** a hardened streaming decompression bound;
  only trusted official endpoints should be used, and custom endpoints require
  explicit confirmation. This limitation remains even with TLS.
- `payload_sequence` ordering is not assumed or live-verified. Unknown valid
  Qwen event types are ignored; unsupported binary envelope variants fail closed.
- Minimum-version Emacs 28/29/30 and live websocket.el behavior are covered by
  the separate project audit/CI work, not claimed by these Emacs 31 local tests.

No credentials or recorded audio were used, and no commits were created.
