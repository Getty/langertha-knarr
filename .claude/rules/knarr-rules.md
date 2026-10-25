# Knarr House Rules

The shared house rules come from skilletor — bundle `getty-cpan-dist@getty`: engineering
discipline, the delegation lock, the publish gate, karr coordination, CPAN release. They load
as `.claude/rules/.local.*.md`; if they are missing, run `skilletor sync` and publish nothing
until they load. This file adds what is true only here, and wins where it differs.

## What this repo is

Langertha::Knarr — universal LLM hub: proxy, server and translator across
OpenAI/Anthropic/Ollama/A2A/ACP/AG-UI. Read first: the Handler role, the Protocol module pair,
and `Request`/`Response`/`Stream`. "Looks orthogonal" is dangerous across the
handler-decorator chain (Tracing/RequestLog wrap any handler). The sibling Langertha repos each
have their own board.

## Agent team

| Task | Agent |
|---|---|
| Implement / refactor / debug behavior-relevant code | `knarr-worker` (default) |
| CLI, Config, Router, Tracing, RequestLog (the Moo side) | `knarr-cli-worker` |
| Write/extend tests | `knarr-test-writer` |
| Commits, `Changes`, card → done, pre-release audit | `knarr-release-manager` |
| Read-only research, audit, gap analysis | `knarr-worker` ("read-only, change nothing") |

Behavior-relevant = runtime behavior, public API, request/response handling, the raw
passthrough path, protocol formatting and streaming, routing, tracing, config parsing, error
handling, tests, performance. Pure prose docs and `Changes` notes are not.

## Release

Here the dzil release is bigger than CPAN: the bundle also creates a GitHub release
(`GitHub::CreateRelease`), and `docker_image` (bundle → `Dist::Zilla::Plugin::Docker::API`)
pushes three Docker tags to `raudssus/langertha-knarr` on Docker Hub. The same go-ahead covers
a standalone `docker push` and `gh release`. For anything heading toward release: stop and ask.

## Deviations from the house rules

- **Public tracker (`github.com/Getty/langertha-knarr`) — not even reading on your own
  initiative.** No listing, viewing, commenting, editing, closing or creating unless the user
  explicitly says to handle a specific item, and every write is confirmed first.

## Knarr-specific hazards

Mechanism and background: skill `knarr-core`. These are the locks:

- **The passthrough seam is bytes, not messages.** Unconfigured models pipe all HTTP bytes 1:1
  to the upstream API — that is the feature. Protocol translation belongs only in `Protocol::*`
  on the routed path; parsing and re-serializing on the passthrough path silently strips
  real-provider metadata.
- **Streaming end markers** differ per protocol (table in CLAUDE.md); a wrong marker means a
  hung client, not a test failure. Any streaming change runs
  `prove -lv t/40_streaming_live.t t/41_streaming_protocols_live.t`.
- **`*_live.t` needs no API keys** — those tests start a real server on a local port with
  `Handler::Code` fakes. Keep them key-free; nothing in `t/` may hit an external service — the
  PostgreSQL live tests are the only exception, and they need
  `KNARR_TEST_PG_DSN`/`KNARR_TEST_PG_USER`/`KNARR_TEST_PG_PASS` and make and drop their own
  schema.

## Perl specifics — reference, don't restate

Module loading, Moose vs. Moo house patterns, cpanfile versioning, POD directives, and commit
style live in the briefed skills (`getty-perl-core`, `getty-perl-moose`, `getty-perl-moo`,
`perl-io-async-future`, `getty-perl-release-author-getty`, `getty-git-commit-style`). The
Moose/Moo module split itself is in CLAUDE.md. Do not duplicate that content here.
