# Knarr — Universal Langertha LLM Hub

```
         .  *  .
        . _/|_ .          KNARR
     .  /|    |\ .        Universal LLM Hub
   ~~~~~|______|~~~~~
   ~~ ~~~~~~~~~~~~~ ~~    Cargo transport for any LLM protocol
   ~~~~~~~~~~~~~~~~~~~~
```

A universal hub that exposes any backend — a `Langertha::Raider`, a raw
`Langertha::Engine`, a remote A2A or ACP agent, or your own custom logic —
over the standard LLM HTTP wire protocols spoken by OpenWebUI, the OpenAI /
Anthropic / Ollama clients, and the agent ecosystems around A2A, ACP, and
AG-UI. One server, six protocols, any backend.

An LLM proxy that routes requests from any client to any backend — with
automatic [Langfuse](https://langfuse.com) tracing for every call.

Set your API key, start the container, done. All requests are traced.

Release notes for every version live in the [Changes](Changes) file.

## Getting Started

```bash
docker run -e ANTHROPIC_API_KEY -p 8080:8080 raudssus/langertha-knarr
```

Now point Claude Code at it:

```bash
ANTHROPIC_BASE_URL=http://localhost:8080 claude
```

That's it. Claude Code sends requests to Knarr, Knarr forwards them to
Anthropic using your API key (**passthrough mode**). Add Langfuse keys and
every request gets traced automatically.

### How it works

Knarr starts in **mixed mode** by default: requests with a model name
that's explicitly configured in `knarr.yaml` go through a Langertha
engine (with full tracing, request logging, and value-object metrics);
unknown model names tunnel straight through to the upstream API the
client thinks it's talking to, using the client's own API key. No key
duplication, no configuration required for the simple cases.

```
Claude Code                                    Anthropic API
    │                                               ▲
    │  ANTHROPIC_BASE_URL=http://localhost:8080     │
    ▼                                               │
  Knarr ──── Handler::Router ─┐                     │
    │           │             └── Handler::Passthrough ──►
    │           └── matches gpt-4o → Langertha::Engine::OpenAI
    │
    └── Tracing decorator → Langfuse
    └── RequestLog decorator → JSONL
```

For explicit routing (send "gpt-4o" requests to OpenAI, "cheap" to
Groq), configure models in a YAML file or let `knarr init` scan your
environment variables and generate one.

### More examples

```bash
# OpenAI Python SDK
OPENAI_BASE_URL=http://localhost:8080/v1 python my_app.py

# curl
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d '{"model":"gpt-5.6-terra","messages":[{"role":"user","content":"Hello"}]}'

# Ollama clients (Open WebUI, etc.) — point at port 11434 in container mode
OLLAMA_HOST=http://localhost:11434 open-webui

# A2A discovery
curl http://localhost:8080/.well-known/agent.json
```

In **container mode** (the default for the Docker image), Knarr binds
two listening sockets simultaneously, both serving every protocol:

- **Port 8080** — primary, OpenAI / Anthropic / A2A / ACP / AG-UI clients
- **Port 11434** — alias for Ollama clients that hardcode that port

Both ports run the same handler chain — the second port is a
convenience alias so existing Ollama clients work without
reconfiguration.

## Windows

Use [WSL2](https://learn.microsoft.com/en-us/windows/wsl/install) — all
commands work as-is inside a WSL terminal:

```bash
wsl
docker run --env-file .env -p 8080:8080 -p 11434:11434 raudssus/langertha-knarr
```

Or with [Docker Desktop](https://www.docker.com/products/docker-desktop/)
from PowerShell:

```powershell
docker run --env-file .env -p 8080:8080 -p 11434:11434 raudssus/langertha-knarr
```

The `--env-file .env` approach works identically on Linux, macOS, and
Windows. Create your `.env` file once, run the same command everywhere.

## Using a .env File

Create a `.env` file with your API keys (see `.env.example`):

```bash
# .env
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
LANGFUSE_PUBLIC_KEY=pk-lf-...
LANGFUSE_SECRET_KEY=sk-lf-...
```

Then run with `--env-file`:

```bash
docker run --env-file .env -p 8080:8080 -p 11434:11434 raudssus/langertha-knarr
```

Knarr reads the file, detects which providers have keys, configures them
with sensible default models, and starts serving.

## Docker Build

```bash
docker build -t raudssus/langertha-knarr .
```

Dependencies are installed via `cpm` from the `cpanfile` using MetaCPAN.

## Docker Compose

The included `docker-compose.yml` starts Knarr with Langfuse tracing
out of the box:

```bash
cp .env.example .env
# Edit .env — add your API keys and Langfuse keys
docker compose up
```

This starts:

| Service | Port | Description |
|---------|------|-------------|
| Knarr | 8080, 11434 | LLM Proxy |
| Langfuse | 3000 | Tracing Dashboard |
| PostgreSQL | — | Langfuse storage |

The `docker-compose.yml` automatically loads `.env` and connects Knarr to
the Langfuse instance. Open http://localhost:3000 for the dashboard — every
LLM call through Knarr is traced with model, input, output, latency, and
token usage.

### Minimal Docker Compose (without Langfuse)

If you don't need tracing:

```yaml
services:
  knarr:
    image: raudssus/langertha-knarr
    ports:
      - "8080:8080"
      - "11434:11434"
    env_file: .env
```

## Multiple Providers

Set multiple API keys — Knarr configures all of them automatically:

```bash
docker run --env-file .env -p 8080:8080 -p 11434:11434 raudssus/langertha-knarr
```

```
[knarr] Knarr LLM Proxy starting...
[knarr]
[knarr] Config: auto-detecting from environment variables
[knarr] Engines: 3 provider(s) configured
[knarr]
[knarr]   anthropic => Anthropic / claude-sonnet-5 (key from $ANTHROPIC_API_KEY)
[knarr]   groq => Groq / llama-3.3-70b-versatile (key from $GROQ_API_KEY)
[knarr]   openai => OpenAI / gpt-5.6-terra (key from $OPENAI_API_KEY)
[knarr]
[knarr] Auto-discover: enabled (will query provider model lists)
[knarr] Default engine: OpenAI
[knarr] Langfuse: disabled (set LANGFUSE_PUBLIC_KEY + LANGFUSE_SECRET_KEY to enable)
[knarr] Proxy auth: open (set KNARR_API_KEY to require authentication)
```

Each provider gets a default model, read from the Langertha engine class
itself — so the list below tracks the framework and cannot drift. The
`LANGERTHA_*`-prefixed variable wins over the bare vendor name, which wins
over the `TEST_*` variant:

| Provider | Default Model | ENV Variable |
|----------|---------------|--------------|
| OpenAI | gpt-5.6-terra | `OPENAI_API_KEY` |
| Anthropic | claude-sonnet-5 | `ANTHROPIC_API_KEY` |
| Groq | llama-3.3-70b-versatile | `GROQ_API_KEY` |
| Mistral | mistral-small-latest | `MISTRAL_API_KEY` |
| DeepSeek | deepseek-v4-flash | `DEEPSEEK_API_KEY` |
| MiniMax | MiniMax-M3 | `MINIMAX_API_KEY` |
| Cerebras | gpt-oss-120b | `CEREBRAS_API_KEY` |
| OpenRouter | openai/gpt-4o-mini | `OPENROUTER_API_KEY` |
| Perplexity | sonar | `PERPLEXITY_API_KEY` |
| Gemini | gemini-3-flash-preview | `GEMINI_API_KEY` |
| XAI | grok-4.3 | `XAI_API_KEY` |
| Moonshot | kimi-k3 | `MOONSHOT_API_KEY` |
| NousResearch | Hermes-4-70B | `NOUSRESEARCH_API_KEY` |
| AKI | llama3_8b_chat | `AKI_API_KEY` |
| Scaleway | llama-3.1-8b-instruct | `SCALEWAY_API_KEY` |
| TSystems | gpt-oss-120b | `TSYSTEMS_API_KEY` |
| Hetzner | Qwen/Qwen3.6-35B-A3B-FP8 | `LANGERTHA_HETZNER_API_KEY` |
| Replicate | — (set `model:` explicitly) | `REPLICATE_API_TOKEN` |
| HuggingFace | — (set `model:` explicitly) | `HUGGINGFACE_API_KEY` |

Groq and OpenRouter are the only engines whose classes deliberately refuse
to name a default; Knarr supplies the fallbacks above. Replicate and
HuggingFace have no sensible default either — configure a `model:` for
them. Hetzner is detected only via `LANGERTHA_HETZNER_API_KEY`: the bare
`HETZNER_API_KEY` name is in wide use for the Hetzner Cloud infrastructure
API and would false-positive into an unusable model entry.

With auto-discover enabled (default), Knarr queries each provider's model
list — so you can use any model they offer, not just the defaults.

## Langfuse Tracing

Knarr traces every request automatically when Langfuse credentials are set.
Add these to your `.env`:

```bash
LANGFUSE_PUBLIC_KEY=pk-lf-...
LANGFUSE_SECRET_KEY=sk-lf-...
```

That's it. Every proxy request creates:

- **Trace** with model name, engine type, API format, and full input/output
- **Generation** with start/end time, token usage, and model information
- **Error tracking** when backend calls fail
- Tag `knarr` on all traces

### Trace name

All traces share one name, resolved in this priority order:

1. `langfuse.trace_name` in the YAML config
2. `LANGFUSE_TRACE_NAME` environment variable
3. `KNARR_TRACE_NAME` environment variable (or `knarr start -n <name>`)
4. default `knarr-proxy`

### Latency in traces

Routed non-streaming requests carry the engine's own measurement: the
generation's `endTime` is anchored to the real call window and
`completionStartTime` (Langfuse's time-to-first-token field) is set from
the engine's `ttft_seconds`. Streaming and raw passthrough have no
response object to measure, so those traces use the proxy's wall clock.

### Langfuse Cloud

Just set the keys — Langfuse Cloud (`https://cloud.langfuse.com`) is the
default:

```bash
# .env
OPENAI_API_KEY=sk-...
LANGFUSE_PUBLIC_KEY=pk-lf-...
LANGFUSE_SECRET_KEY=sk-lf-...
```

### Self-Hosted Langfuse

Use `docker compose up` for a local Langfuse stack, or point at your own:

```bash
# .env
LANGFUSE_PUBLIC_KEY=pk-lf-...
LANGFUSE_SECRET_KEY=sk-lf-...
LANGFUSE_URL=http://my-langfuse-server:3000
```

## Proxy Authentication

Protect your proxy with an API key:

```bash
# .env
KNARR_API_KEY=my-secret-proxy-key
```

Clients must send `Authorization: Bearer my-secret-proxy-key` or
`x-api-key: my-secret-proxy-key`. The A2A discovery endpoint
(`/.well-known/agent.json`) stays anonymous so agent clients can
introspect.

## API Formats

Knarr speaks **six** wire protocols on every listening port. The
protocol is selected by URL path, so a single Knarr listening on
`http://localhost:8080` answers all of them simultaneously:

### OpenAI

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-5.6-terra","messages":[{"role":"user","content":"Hello"}]}'

curl http://localhost:8080/v1/models
```

### Anthropic

```bash
curl http://localhost:8080/v1/messages \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-5","messages":[{"role":"user","content":"Hello"}],"max_tokens":1024}'
```

### Ollama

```bash
curl http://localhost:8080/api/chat \
  -d '{"model":"gpt-5.6-terra","messages":[{"role":"user","content":"Hello"}]}'

curl http://localhost:8080/api/tags
```

In container mode Knarr binds an extra `:11434` socket as well, so
existing Ollama clients work without reconfiguration.

### A2A (Google Agent2Agent)

Knarr exposes the agent card at `/.well-known/agent.json` and accepts
A2A JSON-RPC at `POST /` with methods `tasks/send` (sync) and
`tasks/sendSubscribe` (streaming):

```bash
# Agent card (stays anonymous even with proxy_api_key set)
curl http://localhost:8080/.well-known/agent.json

# Sync task
curl http://localhost:8080/ \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tasks/send","params":{"id":"t1","message":{"role":"user","parts":[{"text":"Hello"}]}}}'
```

A2A is also a *backend*: `Handler::A2AClient` consumes a remote A2A agent,
so an OpenAI-fronted Knarr can expose a remote agent to OpenAI clients.

### ACP (BeeAI / Linux Foundation)

`POST /runs` with `mode: "sync"` or `mode: "stream"`; agent listing at
`GET /agents`:

```bash
curl http://localhost:8080/agents

curl http://localhost:8080/runs \
  -H "Content-Type: application/json" \
  -d '{"mode":"sync","input":"Hello"}'
```

Like A2A, ACP works as a backend too: `Handler::ACPClient` wraps a remote
ACP agent.

### AG-UI (CopilotKit)

`POST /awp` returning the AG-UI typed event stream:

```bash
curl http://localhost:8080/awp \
  -H "Content-Type: application/json" \
  -d '{"conversation_id":"c1","message":{"role":"user","content":[{"type":"text","text":"Hello"}]}}'
```

All six formats support streaming — SSE for OpenAI / Anthropic / A2A /
ACP / AG-UI, NDJSON for Ollama.

### Tool Calling

For **configured (non-passthrough) models**, Knarr forwards `tools` and
`tool_choice` to the Langertha engine via `chat_f`. Langertha normalises them
to the engine's native wire format — so an OpenAI-format `tools` array reaches
an Anthropic engine as `tools` + Anthropic `tool_choice`, and vice versa.
Tool-call responses (`Langertha::ToolCall` objects) come back and are
serialised to the client's protocol format:

| Client protocol | Tool call format in response |
|----------------|------------------------------|
| OpenAI         | `message.tool_calls[]`, `finish_reason: "tool_calls"` |
| Anthropic      | `content[]` with `type: "tool_use"` blocks, `stop_reason: "tool_use"` |
| Ollama         | `message.tool_calls[]` |

For **passthrough models** (unknown model names), the raw request bytes are
forwarded 1:1 to the upstream API, so whatever tool-call format the client
sent arrives at the provider unchanged.

## Use Cases

### Claude Code through any backend

```bash
docker run --env-file .env -p 8080:8080 raudssus/langertha-knarr

# In another terminal:
ANTHROPIC_BASE_URL=http://localhost:8080 claude
```

Every Claude Code request gets traced in Langfuse.

### Ollama clients with cloud models

Use cloud LLMs from any Ollama-compatible client like
[Open WebUI](https://github.com/open-webui/open-webui):

```bash
docker run --env-file .env -p 11434:11434 raudssus/langertha-knarr

# Open WebUI connects to port 11434, thinks it's Ollama,
# but requests go to cloud providers through Knarr
```

### Local + Cloud hybrid

Mount a config file for custom routing:

```yaml
# knarr.yaml
models:
  local:
    engine: OllamaOpenAI
    url: http://host.docker.internal:11434/v1
    model: llama3.3
  gpt-4o:
    engine: OpenAI
default:
  engine: OllamaOpenAI
  url: http://host.docker.internal:11434/v1
```

```bash
docker run --env-file .env \
  -v ./knarr.yaml:/etc/knarr/config.yaml \
  -p 8080:8080 -p 11434:11434 \
  raudssus/langertha-knarr start -c /etc/knarr/config.yaml
```

## Using a Config File

For more control than auto-detection, create a `knarr.yaml`:

```yaml
listen:
  - "127.0.0.1:8080"
  - "127.0.0.1:11434"

models:
  # No `model:` key → the engine's default model is used
  # (OpenAI defaults to gpt-5.6-terra, see the table above)
  gpt-4o:
    engine: OpenAI

  # Explicit `model:` overrides the engine default
  gpt-4o-mini:
    engine: OpenAI
    model: gpt-4o-mini

  claude-sonnet:
    engine: Anthropic
    model: claude-sonnet-5
    api_key: ${ANTHROPIC_API_KEY}   # explicit ENV reference

  # Per-model generation defaults, applied to every request
  groq-fast:
    engine: Groq
    model: llama-3.3-70b-versatile
    temperature: 0.2
    response_size: 4096
    system_prompt: "You are a terse assistant. Answer in one sentence."

  # Local engines are reached by URL, no API key needed
  local-llama:
    engine: OllamaOpenAI
    url: http://localhost:11434/v1
    model: llama3.3

  deepseek:
    engine: DeepSeek
    model: deepseek-v4-flash

  # api_key_env: read the key from a named environment variable
  # (instead of the engine's default LANGERTHA_* / bare-name lookup)
  mistral:
    engine: Mistral
    model: mistral-small-latest
    api_key_env: MY_MISTRAL_KEY

default:
  engine: OpenAI

auto_discover: true

# Passthrough: requests go directly to upstream APIs
# The client's own API key is used — no duplication needed
# Models with explicit config above are routed via Langertha,
# everything else passes through transparently
passthrough:
  anthropic: https://api.anthropic.com
  openai: https://api.openai.com
  # Or point at a custom upstream:
  # anthropic: https://my-anthropic-cache.internal

# proxy_api_key: your-secret

# langfuse:
#   url: http://localhost:3000
#   public_key: pk-lf-...
#   secret_key: sk-lf-...
#   trace_name: my-proxy   # optional, default knarr-proxy

# Request logging: JSONL file and/or per-request JSON directory
# logging:
#   file: /var/log/knarr/requests.jsonl
#   dir: /var/log/knarr/requests
```

Config values support `${ENV_VAR}` interpolation — variables are resolved
at startup.

`models.<name>.engine` resolves in this order:

- `Langertha::Engine::<EngineName>`
- `LangerthaX::Engine::<EngineName>`
- Fully-qualified class name if you set one directly

Every `models.<name>` entry accepts these keys:

| Key | Meaning |
|-----|---------|
| `engine` | Langertha engine class name (required) |
| `model` | Backend model id; defaults to the engine's default model |
| `api_key` | API key, often via `${ENV_VAR}` interpolation |
| `api_key_env` | Name of an env var holding the key (alternative to `api_key`) |
| `url` | Base URL override (required for local engines like Ollama) |
| `system_prompt` | System prompt prepended to every request |
| `temperature` | Sampling temperature applied to every request |
| `response_size` | Max tokens applied to every request |

### Passthrough Mode

Passthrough is the default behavior: requests for unconfigured models go
directly to the upstream API using the client's own API key and headers.
All HTTP bytes — including SSE chunks, tool_use blocks, usage data, and
cache_control — are piped 1:1 to the client. No key duplication, no model
configuration needed. Knarr just sits in the middle and traces.

If you also configure explicit model routing (the `models:` section), those
specific models are handled by Langertha engines. Everything else still
passes through as raw bytes.

**Enabled by default** with `--from-env`. In a config file:

```yaml
# Enable with default upstream URLs
passthrough: true

# Or per format with custom upstreams
passthrough:
  anthropic: https://api.anthropic.com
  openai: https://my-openai-mirror.internal
```

Claude Code example — no Knarr API key needed, your existing key works:

```bash
docker run -p 8080:8080 raudssus/langertha-knarr
ANTHROPIC_BASE_URL=http://localhost:8080 claude
```

### Generating a Config

Knarr can generate a config from your environment:

```bash
# Via Docker — pass your env vars through
docker run --rm --env-file .env raudssus/langertha-knarr init > knarr.yaml

# Or pass all API keys from your current shell
docker run --rm \
  $(env | grep -E '_(API_KEY|API_TOKEN)=|^LANGFUSE_' | sed 's/^/-e /') \
  raudssus/langertha-knarr init > knarr.yaml
```

Then mount it:

```bash
docker run --env-file .env \
  -v ./knarr.yaml:/etc/knarr/config.yaml \
  -p 8080:8080 -p 11434:11434 \
  raudssus/langertha-knarr start -c /etc/knarr/config.yaml
```

## All Environment Variables

### API Keys

Every provider is detected from its bare vendor variable; the
`LANGERTHA_`-prefixed variant (e.g. `LANGERTHA_OPENAI_API_KEY`) takes
priority, and the `TEST_LANGERTHA_*` variant is the last resort:

| Variable | Provider |
|----------|----------|
| `OPENAI_API_KEY` | OpenAI |
| `ANTHROPIC_API_KEY` | Anthropic |
| `GROQ_API_KEY` | Groq |
| `MISTRAL_API_KEY` | Mistral |
| `DEEPSEEK_API_KEY` | DeepSeek |
| `MINIMAX_API_KEY` | MiniMax |
| `CEREBRAS_API_KEY` | Cerebras |
| `OPENROUTER_API_KEY` | OpenRouter |
| `PERPLEXITY_API_KEY` | Perplexity |
| `REPLICATE_API_TOKEN` | Replicate |
| `HUGGINGFACE_API_KEY` | HuggingFace |
| `GEMINI_API_KEY` | Gemini |
| `XAI_API_KEY` | XAI |
| `MOONSHOT_API_KEY` | Moonshot |
| `NOUSRESEARCH_API_KEY` | NousResearch |
| `AKI_API_KEY` | AKI |
| `SCALEWAY_API_KEY` | Scaleway |
| `TSYSTEMS_API_KEY` | TSystems |
| `LANGERTHA_HETZNER_API_KEY` | Hetzner (no bare `HETZNER_API_KEY` — see above) |

### Langfuse

| Variable | Description | Default |
|----------|-------------|---------|
| `LANGFUSE_PUBLIC_KEY` | Public key (`pk-lf-...`) | — |
| `LANGFUSE_SECRET_KEY` | Secret key (`sk-lf-...`) | — |
| `LANGFUSE_URL` | Server URL | `https://cloud.langfuse.com` |
| `LANGFUSE_BASE_URL` | Alias for `LANGFUSE_URL` | — |
| `LANGFUSE_TRACE_NAME` | Trace name (beats `KNARR_TRACE_NAME`) | — |
| `KNARR_TRACE_NAME` | Trace name | `knarr-proxy` |

### Request Logging

| Variable | Description |
|----------|-------------|
| `KNARR_LOG_FILE` | JSONL log file (one JSON object per request) |
| `KNARR_LOG_DIR` | Directory for per-request JSON files |

### Proxy

| Variable | Description | Default |
|----------|-------------|---------|
| `KNARR_API_KEY` | Require client authentication | — (open) |
| `KNARR_DEBUG` | Enable verbose logging (`1` = on) | — (off) |

## CLI Reference

```
knarr                                      Show help
knarr start                                Start with config file (./knarr.yaml)
knarr start --from-env                     Auto-detect config from ENV (Docker default)
knarr start --from-env -p 8080 -p 11434   ENV config, explicit ports
knarr start -p 9090                        Custom port
knarr start -c prod.yaml                   Custom config
knarr start -v                             Verbose logging
knarr start -n my-proxy                    Custom Langfuse trace name
knarr start --log_file /var/log/knarr.jsonl   JSONL request log
knarr start --log_dir /var/log/knarr/reqs     Per-request JSON logs
knarr init                                 Generate config from environment
knarr init -e .env                         Include .env file in scan
knarr models                               List configured models
knarr models --format json
knarr check                                Validate config file
```

The `-p` / `--port` flag is repeatable — each occurrence adds a listen port.
Default host is `0.0.0.0`. Set `KNARR_DEBUG=1` or use `-v` for verbose logging.

## Installing as a Perl Module

Knarr is also a standard CPAN distribution:

```bash
cpanm Langertha::Knarr
```

Then use the `knarr` CLI directly:

```bash
export OPENAI_API_KEY=sk-...
knarr init > knarr.yaml
knarr start
```

### Using Knarr Programmatically

Knarr is built around a `handler` and one or more wire protocols.
You construct a handler (typically `Handler::Router` driven by your
existing `knarr.yaml`), optionally wrap it in tracing/logging decorators,
and pass it to a `Langertha::Knarr` instance:

```perl
use IO::Async::Loop;
use Langertha::Knarr;
use Langertha::Knarr::Config;
use Langertha::Knarr::Router;
use Langertha::Knarr::Handler::Router;

my $loop   = IO::Async::Loop->new;
my $config = Langertha::Knarr::Config->new(file => 'knarr.yaml');
my $router = Langertha::Knarr::Router->new(config => $config);

my $handler = Langertha::Knarr::Handler::Router->new(router => $router);

my $knarr = Langertha::Knarr->new(
  handler => $handler,
  loop    => $loop,
  listen  => $config->listen,   # arrayref of "host:port" strings
);
$knarr->run;   # blocks
```

#### Wrapping with tracing and logging

Both `Tracing` and `RequestLog` are decorator handlers — they wrap any
inner handler and forward chat/stream calls through, recording before
and after:

```perl
use Langertha::Knarr::Tracing;
use Langertha::Knarr::Handler::Tracing;
use Langertha::Knarr::Handler::RequestLog;

my $tracing = Langertha::Knarr::Tracing->new(config => $config);
$handler = Langertha::Knarr::Handler::Tracing->new(
  wrapped => $handler,
  tracing => $tracing,
) if $tracing->_enabled;

my $rlog = Langertha::Knarr::RequestLog->new(config => $config);
$handler = Langertha::Knarr::Handler::RequestLog->new(
  wrapped     => $handler,
  request_log => $rlog,
) if $rlog->_enabled;
```

`knarr start` applies both wrappers automatically when their respective
config sections are present.

#### Adding passthrough fallback

To preserve the "configured models go through Langertha, everything else
tunnels straight to the upstream API" behaviour, give the router a
`Handler::Passthrough` fallback:

```perl
use Langertha::Knarr::Handler::Passthrough;

my $passthrough = Langertha::Knarr::Handler::Passthrough->new(
  upstreams => $config->passthrough,   # { openai => 'https://api.openai.com', ... }
  loop      => $loop,
);
my $handler = Langertha::Knarr::Handler::Router->new(
  router      => $router,
  passthrough => $passthrough,
);
```

#### A fake handler for tests (`Handler::Code`)

`Handler::Code` wraps a coderef, so you can stand up a Knarr server
without any real backend — the `*_live.t` tests do exactly this:

```perl
use Langertha::Knarr::Handler::Code;

my $handler = Langertha::Knarr::Handler::Code->new(
  chat => sub {
    my ($session, $request) = @_;
    return "Echo: " . $request->messages->[-1]{content};
  },
  stream => sub {
    my ($session, $request) = @_;
    return Langertha::Knarr::Stream->from_list(
      ["Hello", " ", "world", "!"],
    );
  },
);
```

### Using the Config and Router Independently

```perl
use Langertha::Knarr::Config;
use Langertha::Knarr::Router;

my $config = Langertha::Knarr::Config->new(file => 'knarr.yaml');
my $router = Langertha::Knarr::Router->new(config => $config);

# Resolve a model name to a Langertha engine
my ($engine, $model) = $router->resolve('gpt-4o-mini');
# $engine is a Langertha::Engine::OpenAI (or whatever the config maps to)
# $model is the resolved model name

my $response = $engine->simple_chat(
  { role => 'user', content => 'Hello!' },
);
```

## Built With

- [Langertha](https://metacpan.org/pod/Langertha) — Perl LLM framework with 37 engine backends
- [IO::Async](https://metacpan.org/pod/IO::Async) + [Net::Async::HTTP::Server](https://metacpan.org/pod/Net::Async::HTTP::Server) — Async event loop and HTTP server
- [Future::AsyncAwait](https://metacpan.org/pod/Future::AsyncAwait) — Native async/await for Perl
- [Moose](https://metacpan.org/pod/Moose) — Postmodern object system
- [Langfuse](https://langfuse.com) — Open source LLM observability

## License

This software is copyright (c) 2026 by Torsten Raudssus.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.
