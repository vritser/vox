# Fixture provenance

All files here are non-secret protocol research/test data. No real microphone
recording, API credential, or live server capture is included. Tests only read
JSON and binary fixtures; they never run the downloaded Python/Go examples.

## Official static examples and reference sources

Retrieved 2026-10-20 from the
[Qwen server event page](https://help.aliyun.com/zh/model-studio/qwen-asr-realtime-server-events)
and the
[Doubao realtime SeedASR page](https://docs.volcengine.com/docs/DoubaoVoice/bidirectional-streaming-automatic-speech-recognition-websocket?lang=zh).

- [qwen-official-events.jsonl](qwen-official-events.jsonl): three independent
  official examples (partial, item final, session finished), copied semantically
  unchanged; whitespace compacted and Chinese JSON strings escaped as Unicode.
  These are **not one recorded conversation**: the original examples have
  different item IDs. The ERT static-example test does not pretend otherwise.
- [sauc_python.zip](sauc_python.zip): unmodified official Python reference archive
  downloaded using that realtime page's Python attachment button.
- [official-sauc-protocol.py](official-sauc-protocol.py) and
  [official-sauc-demo.py](official-sauc-demo.py): verbatim extracted source from
  that archive, for audit only. Never imported or run, no dependencies installed.
- [sauc_go.zip](sauc_go.zip): unmodified official Go archive from the same page's
  Go attachment button, resolving to the
  [official CDN file](https://portal.volccdn.com/obj/volcfe/cloud-universal-doc/upload_5ff69c9c8092969c2ec0e6298ebe87d7.zip).
- [official-sauc-header.go](official-sauc-header.go),
  [official-sauc-payload.go](official-sauc-payload.go),
  [official-sauc-response.go](official-sauc-response.go), and
  [official-sauc-client.go](official-sauc-client.go): verbatim extracted protocol
  source, for cross-checking only. Never built or run.

Official source archives retain their upstream ownership. These copies are
reference material, not Vox implementation or a Python/Go runtime requirement.
The archives themselves contain editor/assistant metadata; none of that metadata
is loaded, followed as instructions, or needed by Vox.

## Synthetic binary fixtures

**Every `doubao-*.bin` file below was synthesized locally**, not downloaded as an
official golden packet and not recorded from a server. The envelope is based on
the downloaded `bigmodel_async` request/response parsers. Node's standard Buffer
and zlib libraries produced the fixtures independently of the Elisp codec during
authoring. Node is not needed to run ERT or use Vox. No official example was run.

| File | Synthetic contents |
| --- | --- |
| [doubao-ready.bin](doubao-ready.bin) | `11 91 10 00`, sequence 1, uncompressed JSON `{}` |
| [doubao-partial.bin](doubao-partial.bin) | `11 91 10 00`, sequence 2, full `result.text="Check emacs"`, indefinite utterance |
| [doubao-final.bin](doubao-final.bin) | `11 97 11 00`, signed sequence -3, event 100, gzip JSON; full `result.text="Check Emacs Lisp."`, definite two-pass utterance |
| [doubao-error.bin](doubao-error.bin) | `11 f0 10 00`, error code 45000001, uncompressed JSON containing a clearly synthetic message used to assert non-disclosure |

The event value 100 and error number are synthetic test values, **not evidence
of provider event/code meaning**. Flags 7 deliberately exercise all optional
fields; a live server using that exact combination has not been observed.

ERT also synthesizes boundary, truncation, extension-header, false-final-body,
and malformed packets in memory. CRC32 uses the independent known vector
`CRC32("123456789") = cbf43926`; the empty stored-block gzip has an explicit
literal byte vector. Large boundary roundtrips use Emacs native zlib to verify
the independently implemented stored-block gzip encoder.

SHA-256 hashes:

```text
sauc_python.zip             684012ec72c56d509b361ab8d6ecd41c107ecfc593602a75b7da99f41f3f8a22
sauc_go.zip                 e145d72638e942a0913ab7e352baf4ed79a026b38bba0cd31b20b8292b3efa64
qwen-official-events.jsonl  706442784d5b6ec3c8c8d9bf7b5e6124733de2e46530741616e03dec2981e275
doubao-ready.bin            64d2b884e9372ce51fa42c496f136a2724127bf4293ce5b90ee205c1d56f8670
doubao-partial.bin          e45d052616b351cb9e02227110d8b74c3607fdc4dc075ab15c8fe4a07799a809
doubao-final.bin            eb9cc917df992f20812136d9733fc6c2698a72106b148b01e3da97d49d2dfcb8
doubao-error.bin            24f9b421c007327631cdff485a21e75fe19ef8365334ba1f62d9174974166920
```

See the [protocol audit](../../docs/protocol-audit.md) for source line anchors,
protocol disagreements, supported behavior, and explicitly unverified items.
