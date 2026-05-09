# Security policy

## Reporting a vulnerability

If you find a security issue in Murmur, please **do not file a public GitHub issue**.

Email **archith.rapaka@gmail.com** with:

- A description of the issue
- Steps to reproduce
- Murmur version, macOS version, Mac model
- Your assessment of impact

I'll acknowledge within 7 days and aim to ship a fix within 30 days for high-severity issues. You'll be credited in the release notes unless you prefer otherwise.

## Scope

In scope:

- Code execution via crafted input (audio, transcribed text, vocabulary list, settings JSON)
- Privilege escalation through accessibility / microphone misuse
- Unintended network calls (Murmur is local-only by design — any outbound network is a security issue)
- Credential / token leakage in logs or files written to disk

Out of scope:

- Issues in WhisperKit / `argmax-oss-swift` upstream — report to https://github.com/argmaxinc/argmax-oss-swift
- Issues in `KeyboardShortcuts` — report to https://github.com/sindresorhus/KeyboardShortcuts
- Social engineering, physical access attacks, or denial-of-service via resource exhaustion

## Local-only by design

Murmur makes only one outbound network call: a one-time download of the WhisperKit ML model from Hugging Face on first launch. After that, **zero network traffic** is expected at runtime. If you observe any other network call from Murmur in normal operation, that is a security issue and we want to know about it.

## Code signing

Murmur ships ad-hoc signed dev builds via GitHub Releases. Production builds (v1.0+) will be Developer ID signed and notarized. Do not run binaries claiming to be Murmur from any source other than:

- This repository's [Releases](https://github.com/humancto/murmur/releases) page
- A build you produced yourself from this repository's source via `./scripts/make-app.sh`
