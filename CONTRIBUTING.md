# Contributing to Murmur

Thanks for considering it. A few ground rules.

## What we want

- Bug reports — especially about accuracy on your accent, your hardware, your apps. Real-world failure modes are gold.
- Apps that don't work with the text injection layer. We need a coverage matrix.
- Latency regressions. If something feels slow, file it with a screen recording.
- Polish — better animations, better copy, better defaults.
- Performance — smaller models, faster inference, lower memory.

## What we don't want

- Cloud anything. Murmur is local-first. PRs that add network calls will be rejected.
- Telemetry of any kind. Not even "anonymous." Not even crash reports.
- Subscription/payment infrastructure.
- Feature creep. Read [`.planning/architecture.plan.md`](./.planning/architecture.plan.md). If your feature isn't on the post-v1 list, open an issue first.

## How to contribute

1. **Open an issue first** for anything bigger than a typo. Saves you time if we say no.
2. **Fork, branch, PR.** Conventional commits (`feat:`, `fix:`, `refactor:`, `chore:`).
3. **Tests required** for anything in the audio capture, transcription, cleanup, or text injection paths. These are the load-bearing surfaces.
4. **Small PRs.** One concern per PR. Easier to review, easier to revert.

## Building

See [README — Build from source](./README.md#build-from-source).

## Running tests

```bash
swift test
```

Tests that touch the system microphone (currently a single smoke test in `AudioCaptureTests`) trigger the macOS TCC permission prompt the first time. To skip them entirely — useful in headless CI or when you don't want the prompt:

```bash
MURMUR_SKIP_AUDIO_HARDWARE=1 swift test
```

`xcode-select` must point at full Xcode (not Command Line Tools alone) for `swift test` to find the `XCTest` and `Testing` modules — see README's "Build from source" for the one-time setup.

## Code style

- Swift 6 strict concurrency. No `@unchecked Sendable` without a comment explaining why.
- No force unwraps in production code paths.
- Use `// MARK:` to section files.
- Avoid Apple-internal SPI.

## Testing your accent

We maintain a held-out accent eval set at `Tests/Fixtures/Accents/`. To contribute your voice: record 30 s of representative speech as 16 kHz mono WAV, drop it in a fork, run `swift test --filter AccentEvalTests` to get a WER number against the expected transcript, and open a PR. The more accents we have ground-truth data for, the better Murmur gets.

## License

By contributing, you agree your contributions are licensed under MIT.
