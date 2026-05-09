## What

<!-- One sentence describing what changes. -->

## Why

<!-- One paragraph: motivation, the user-visible problem, the architectural reason. -->

## ROADMAP item

<!-- The ROADMAP.md item this PR addresses, e.g. `- [ ] llama-cpp-cleaner`. If this is a new item, add it to ROADMAP first. -->

## Test plan

- [ ] `swift build` — clean, no new warnings under strict concurrency
- [ ] `swift test` (with `MURMUR_SKIP_AUDIO_HARDWARE=1` if no mic) — all tests passing
- [ ] `./scripts/make-app.sh` — produces a working `Murmur.app` bundle
- [ ] Manual end-to-end check on at least one target app (TextEdit / VS Code / Slack)

## Apple-expert review

- [ ] Plan reviewed by `apple-expert` agent (see `.planning/<slug>.plan.md` for revisions)
- [ ] Final diff reviewed by `apple-expert` agent on the actual merged-PR diff
- [ ] All Showstoppers and Bugs resolved; Nits acceptable

## Privacy

- [ ] No new network calls
- [ ] No new telemetry
- [ ] No new credential / API-key requirements
