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

Set your API key, start the container, done. Add Langfuse keys and every
request is traced.

Release notes for every version live in the [Changes](Changes) file.

## Getting Started

```bash
docker run -e ANTHROPIC_API_KEY -p 8080:8080 raudssus/langertha-knarr
```

Now point Claude Code at it:

```bash
ANTHROPIC_BASE_URL=http://localhost:8080 claude
```

That's it. Claude Code sends its requests to Knarr, and Knarr sends them
straight to `api.anthropic.com`, byte for byte, with Claude Code's own
credentials (**passthrough**) — `cache_control`, usage and tool_use details
arrive untouched. Knarr found `ANTHROPIC_API_KEY`, set up an Anthropic
engine and asks Anthropic for its model list; that list is what Knarr
shows its clients (`/v1/models`, `/api/tags`, the manifest), and the engine
answers with this key where there is no passthrough: Ollama clients, A2A,
ACP and AG-UI agents, and the configured name `anthropic`. Start the
container without any API key and every request passes through. Add
Langfuse keys and every request gets traced automatically.

### How it works

The Docker image runs in **mixed mode**: requests with a model name that
is configured go through a Langertha engine, with tracing, request logging
and value-object metrics; every other model name tunnels straight through
to the upstream API the client thinks it's talking to, using the client's
own API key. That includes the models auto-discovered from that very
upstream (Anthropic's models on the Anthropic protocol, OpenAI's on the
OpenAI protocol). A model discovered from another provider (a Groq model
asked for over the OpenAI protocol) goes through its engine. No key
duplication, no configuration required for the simple cases.

Passthrough exists for the OpenAI and Anthropic protocols (and for Ollama
when you configure an upstream for it). An unknown model in any other
protocol goes to the **default engine**, and a request nothing can serve
gets a `404` in the client protocol's own error shape. With a config file,
passthrough is off until you add a `passthrough:` section (see
[Passthrough Mode](#passthrough-mode)).

```
Claude Code / OpenAI SDK / Open WebUI / A2A, ACP, AG-UI agents
    │
    ▼
  Knarr ─┬─ unknown model, or one discovered from that upstream,
         │  passthrough upstream for the protocol
         │     └── raw bytes 1:1 ──► api.anthropic.com / api.openai.com
         │                           (Langfuse trace)
         │
         └─ everything else ──► RequestLog ──► Tracing ──► Handler::Router
                                (JSONL)        (Langfuse)       │
                        configured / discovered model ──► Langertha engine
                        unknown model ──► default engine (else 404)
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
OLLAMA_BASE_URL=http://localhost:11434 open-webui serve

# A2A discovery
curl http://localhost:8080/.well-known/agent.json
```

In **container mode** (the default for the Docker image, which runs
`knarr start --from-env -p 8080 -p 11434`), Knarr binds two listening
sockets on `0.0.0.0`, both serving every protocol:

- **Port 8080** — primary, OpenAI / Anthropic / A2A / ACP / AG-UI clients
- **Port 11434** — alias for Ollama clients that hardcode that port

Both ports run the same handler chain — the second port is a
convenience alias so existing Ollama clients work without
reconfiguration.

Whenever `knarr start` runs without `-p` — a local `knarr start`, or a
Docker command that replaces the image's default command — Knarr listens
on the config's `listen:` addresses, which default to `127.0.0.1:8080` and
`127.0.0.1:11434`: loopback only. Give `-p` (binds `0.0.0.0`, or the host
from `-H`) or `listen:` entries with `0.0.0.0` to be reachable from
elsewhere, see [Local + Cloud hybrid](#local--cloud-hybrid).

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
the Langfuse instance. It runs Langfuse v2 (`langfuse/langfuse:2`), which
needs only PostgreSQL; Langfuse v3 would also need ClickHouse, Redis and
S3-compatible storage.

The local Langfuse starts empty: open http://localhost:3000, sign up,
create a project, put its `LANGFUSE_PUBLIC_KEY` and `LANGFUSE_SECRET_KEY`
into `.env`, and restart Knarr (`docker compose up -d knarr`). From then
on every LLM call through Knarr is traced with model, input, output,
latency, and token usage.

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
[knarr] Passthrough: anthropic -> https://api.anthropic.com, openai -> https://api.openai.com
[knarr] Langfuse: disabled (set LANGFUSE_PUBLIC_KEY + LANGFUSE_SECRET_KEY to enable)
[knarr] Proxy auth: open (set KNARR_API_KEY to require authentication)
[knarr] Logging: disabled (set KNARR_LOG_FILE or KNARR_LOG_DIR to enable)
[knarr]
[knarr] Starting server:
[knarr]   http://0.0.0.0:8080
[knarr]   http://0.0.0.0:11434
```

The default engine is OpenAI when an OpenAI key is set, with its key read
from the variable it was found in (`api_key_env`, like every detected
provider); without one there is none, and a request only a default engine could answer (an A2A task, an
Ollama request for an unknown model) gets a `404`.

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

With auto-discover enabled (always under `--from-env` and in `knarr init`
output; off by default in a hand-written config), Knarr queries each
provider's model list the first time a model is looked up — so you can use
any model they offer, not just the defaults. The discovered models show
up in the model lists. A discovered model whose provider is also the
passthrough upstream of the client's protocol still passes through, with
the client's own key; the others (another provider's, or any over a
protocol without a passthrough upstream) are routed through their engine
with the key from the environment. To route a model through Knarr's key
even where it could pass through, configure it under `models:`.

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

1. `knarr start -n <name>` (it sets `langfuse.trace_name`)
2. `langfuse.trace_name` in the YAML config
3. `LANGFUSE_TRACE_NAME` environment variable
4. `KNARR_TRACE_NAME` environment variable
5. default `knarr-proxy`

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
`x-api-key: my-secret-proxy-key` on every route — model listings,
`/api/show`, `/api/version` and the provider manifest included. Only the
A2A discovery endpoint (`/.well-known/agent.json`) stays anonymous so agent
clients can introspect. In a config file the key is `proxy_api_key:`.

The proxy key never leaves Knarr: a passthrough request reaches the
upstream without the header that carried it. Every other header goes
through unchanged, so a passthrough client sends its own provider key in
the other one — with the proxy key in `x-api-key`, the OpenAI key (or
Claude Code's login) as `Authorization: Bearer`; with the proxy key as
`Authorization: Bearer`, the Anthropic key in `x-api-key`.

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

curl http://localhost:8080/api/generate \
  -d '{"model":"gpt-5.6-terra","prompt":"Hello"}'

curl http://localhost:8080/api/tags

curl http://localhost:8080/api/show -d '{"model":"gpt-5.6-terra"}'

curl http://localhost:8080/api/version
```

`GET /api/version` answers Ollama's `{"version":"0.34.4"}`: the Ollama
version Knarr's endpoints are compatible with, not Knarr's own. Change it
with `ollama_compat_version` (or `KNARR_OLLAMA_COMPAT_VERSION`); it must be
three dot-separated numbers, and at least `0.6.4` for VS Code Copilot.

`POST /api/show` (VS Code Copilot needs it) answers for every model
`/api/tags` lists: `capabilities` holds `completion`, plus `tools` when the
routed engine takes tools, plus `vision` when the routed engine claims
`image_input` for that model (needs a Langertha core with that flag); never
`thinking`. For gateway and self-hosted models (OpenRouter, Mistral,
LM Studio, T-Systems, Ollama, llama.cpp) Knarr asks the provider's own model
metadata once after startup whether the model sees images (needs a Langertha
core with `probe_model_capabilities_f`; `probe_capabilities: 0` turns it off,
`probe_timeout` limits each probe, default 10 seconds). A gateway whose
metadata is one catalogue (OpenRouter, Mistral, LM Studio, T-Systems) is asked
once per endpoint, however many models were discovered on it. A context length
appears in `model_info` only when the engine knows one (a model's
`context_size` config key sets it for Ollama and LM Studio native).

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
  -d '{"jsonrpc":"2.0","id":1,"method":"tasks/send","params":{"id":"t1","message":{"role":"user","parts":[{"type":"text","text":"Hello"}]}}}'
```

Only `type: "text"` parts are read. An A2A task names no model, so it is
answered by the default engine with the model configured under `default:`
(or the provider's default); without a default engine it gets a `404`.

A2A is also a *backend*: `Handler::A2AClient` consumes a remote A2A agent,
so an OpenAI-fronted Knarr can expose a remote agent to OpenAI clients.

### ACP (BeeAI / Linux Foundation)

`POST /runs` with `mode: "sync"` or `mode: "stream"`; agent listing at
`GET /agents` (the model list, one agent per model). `agent_name` picks the
model; without it the default engine answers:

```bash
curl http://localhost:8080/agents

curl http://localhost:8080/runs \
  -H "Content-Type: application/json" \
  -d '{"agent_name":"gpt-5.6-terra","mode":"sync","input":[{"parts":[{"content_type":"text/plain","content":"Hello"}]}]}'
```

Like A2A, ACP works as a backend too: `Handler::ACPClient` wraps a remote
ACP agent.

### AG-UI (CopilotKit)

`POST /awp` returning the AG-UI typed event stream:

```bash
curl http://localhost:8080/awp \
  -H "Content-Type: application/json" \
  -d '{"threadId":"t1","runId":"r1","model":"gpt-5.6-terra","messages":[{"role":"user","content":"Hello"}]}'
```

The answer is always the AG-UI event stream. Without `model` the default
engine answers.

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

For **passthrough models** (unknown model names in a protocol with a
passthrough upstream), the raw request bytes are forwarded 1:1 to the
upstream API, so whatever tool-call format the client sent arrives at the
provider unchanged.

Routed streams deliver tool calls too: whole, when the stream closes,
before the protocol's end marker.

### Reasoning, images and other request fields

On the routed path Knarr carries more than messages and tools from the
client's body to the engine. Each generation control is forwarded only
when the target engine advertises it (images always are), and Langertha
writes it in that engine's own wire format:

| Field | OpenAI | Anthropic | Ollama |
|-------|--------|-----------|--------|
| Reasoning effort | `reasoning_effort` | `thinking` (`disabled`: none; `adaptive` or `enabled` without budget: medium; `budget_tokens`: nearest level for the model), `output_config.effort` | `think` (`false`: none, `true`: medium, a level string as sent), `reasoning_effort` |
| Structured output | `response_format` | — | `format` |
| Temperature | `temperature` | `temperature` | `options.temperature` |
| Answer length | `max_tokens` | `max_tokens` | — |
| Seed | `seed` | — | `options.seed` |
| Parallel tool calls | `parallel_tool_calls` | — | — |
| Prompt cache key | `prompt_cache_key` | — | — |
| Images | `image_url` parts (data: URLs or links) | `image` blocks (base64 or url) | a message's `images`, `images` on `/api/generate` |

Reasoning levels are `none minimal low medium high xhigh max`; an explicit
effort field wins over one derived from `thinking` / `think`. Mapping
`budget_tokens` needs a Langertha with `Langertha::Reasoning::BudgetPolicy`.
Images become Langertha image objects that the routed engine receives in
its own format; Knarr does not fetch image links. On raw passthrough every
field reaches the upstream exactly as sent.

### Provider manifest

`GET /.well-known/langertha.json` serves a Langertha provider manifest, so
`raider --provider HOST` can configure itself: the OpenAI, Anthropic and
Ollama endpoints under Knarr's public URL, every configured and
auto-discovered model with its capabilities, and `api_key` auth when a
proxy key is set (the route then needs the key). Upstream URLs, keys and
passthrough targets are never published. The public URL is `public_url:`
(or `KNARR_PUBLIC_URL`), else taken from the request's `Host` header. It
needs a Langertha with `Langertha::Manifest`; with an older one the route
answers `404`.

## Use Cases

### Claude Code through any backend

```bash
docker run --env-file .env -p 8080:8080 raudssus/langertha-knarr

# In another terminal:
ANTHROPIC_BASE_URL=http://localhost:8080 claude
```

With Langfuse keys in `.env`, every Claude Code request gets traced in
Langfuse.

### Ollama clients with cloud models

Use cloud LLMs from any Ollama-compatible client like
[Open WebUI](https://github.com/open-webui/open-webui):

```bash
docker run --env-file .env -p 11434:11434 raudssus/langertha-knarr

# Open WebUI connects to port 11434, thinks it's Ollama,
# but requests go to cloud providers through Knarr
```

### Local + Cloud hybrid

Mount a config file for custom routing, with Ollama running on the
Docker host:

```yaml
# knarr.yaml
listen:
  - "0.0.0.0:8080"
models:
  local:
    engine: OllamaOpenAI
    url: http://host.docker.internal:11434/v1
    model: llama3.3
  gpt-4o:
    engine: OpenAI
    api_key_env: OPENAI_API_KEY
default:
  engine: OllamaOpenAI
  url: http://host.docker.internal:11434/v1
  model: llama3.3
```

```bash
docker run --env-file .env \
  --add-host=host.docker.internal:host-gateway \
  -v ./knarr.yaml:/etc/knarr/config.yaml \
  -p 8080:8080 \
  raudssus/langertha-knarr start -c /etc/knarr/config.yaml
```

Arguments after the image name replace its default command, so the
container listens on the config's `listen:` addresses. Without a
`listen:` with `0.0.0.0` (or `-p 8080` on the `start` command) it would
listen on its own loopback only and the port mapping would never reach it.
Port 11434 stays unmapped here because the host's Ollama already holds it;
`--add-host` makes `host.docker.internal` resolve on Linux (Docker Desktop
has it built in).

## Using a Config File

For more control than auto-detection, create a `knarr.yaml` (a commented
version ships as `share/example-config.yaml`; `knarr check` validates it):

```yaml
listen:
  - "127.0.0.1:8080"
  - "127.0.0.1:11434"

models:
  # No `model:` key → the engine's default model is used
  # (OpenAI defaults to gpt-5.6-terra, see the table above).
  # No api_key / api_key_env → the engine reads its own
  # LANGERTHA_OPENAI_API_KEY (not the bare OPENAI_API_KEY)
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

  # Local engines are reached by URL, no API key needed. Knarr listens
  # on 11434 itself here, so this Ollama runs on another port
  # (OLLAMA_HOST=127.0.0.1:11435 ollama serve) or another host
  local-llama:
    engine: OllamaOpenAI
    url: http://localhost:11435/v1
    model: llama3.3
    user_agent_timeout: 600   # slow local model: 10 minutes

  deepseek:
    engine: DeepSeek
    model: deepseek-v4-flash

  # api_key_env: read the key from a named environment variable
  # (instead of the engine's own LANGERTHA_* variable)
  mistral:
    engine: Mistral
    model: mistral-small-latest
    api_key_env: MY_MISTRAL_KEY

default:
  engine: OpenAI
  api_key_env: OPENAI_API_KEY

auto_discover: true

# Passthrough: requests go directly to upstream APIs
# The client's own API key is used — no duplication needed
# Models with explicit config above (and auto-discovered ones from
# another provider) are routed via Langertha, everything else passes
# through transparently
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

The top-level keys (each with its environment variable fallback where
there is one; the config value wins):

| Key | Meaning | Default |
|-----|---------|---------|
| `listen` | `host:port` list | `127.0.0.1:8080`, `127.0.0.1:11434` |
| `models` | model name → engine config, see below | — |
| `default` | engine for unknown models in a protocol without passthrough upstream and for requests without a model; same keys as a model entry | none (→ `404`) |
| `auto_discover` | list every model the configured endpoints list; routed unless the client protocol's passthrough upstream is the endpoint that listed it | `false` |
| `passthrough` | `true` or per-protocol upstream URLs (`openai`, `anthropic`, `ollama`) | off |
| `proxy_api_key` | key clients must send (`KNARR_API_KEY`) | open |
| `public_url` | base URL in the provider manifest (`KNARR_PUBLIC_URL`) | from the request |
| `langfuse` | `url`, `public_key`, `secret_key`, `trace_name` (`LANGFUSE_*`) | off |
| `logging` | `file` (JSONL) and/or `dir` (`KNARR_LOG_FILE`, `KNARR_LOG_DIR`) | off |
| `upstream_timeout` | seconds for a non-streaming upstream request; routed engines' `user_agent_timeout` (`KNARR_UPSTREAM_TIMEOUT`) | `300` |
| `upstream_stall_timeout` | seconds a passthrough stream may go without data (`KNARR_UPSTREAM_STALL_TIMEOUT`) | `120` |
| `probe_capabilities` | ask gateway / self-hosted engines which models see images (`KNARR_PROBE_CAPABILITIES`) | `1` |
| `probe_timeout` | seconds per capability probe (`KNARR_PROBE_TIMEOUT`) | `10` |
| `ollama_compat_version` | version at `GET /api/version`, `x.y.z` (`KNARR_OLLAMA_COMPAT_VERSION`) | `0.34.4` |

The full reference is the POD of `Langertha::Knarr::Config`
(`perldoc Langertha::Knarr::Config`).

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
| `context_size` | Context window in tokens; only engines that take one (`Ollama`, `LMStudio` native) — sent upstream (Ollama `num_ctx`) and reported by `/api/show`; other engines ignore it with a warning at startup; not inherited by auto-discovered models |
| `user_agent_timeout` | Seconds the engine waits for its upstream; defaults to `upstream_timeout`, `0` disables it |

### Passthrough Mode

With passthrough on, requests for unconfigured models go directly to the
upstream API using the client's own API key and headers. All HTTP bytes —
including SSE chunks, tool_use blocks, usage data, and cache_control — are
piped 1:1 to the client. No key duplication, no model configuration
needed. Knarr just sits in the middle and traces (passthrough requests get
a Langfuse trace, but no request-log entry).

If you also configure explicit model routing (the `models:` section),
those models are handled by Langertha engines, and so are
`auto_discover`ed models from a provider other than the protocol's
upstream. Everything else still passes through as raw bytes — for the
protocols that have an upstream — including discovered models of that
upstream itself. An unknown model in a protocol without one (Ollama without an
`ollama:` entry, and A2A, ACP and AG-UI always) goes to the default engine,
or gets a `404` in the protocol's error shape when there is none.

**On by default** with `--from-env` (the Docker image). In a config file it
is off until you add it:

```yaml
# Enable OpenAI and Anthropic with their default upstream URLs
passthrough: true

# Or per format with custom upstreams (ollama has no default URL)
passthrough:
  anthropic: https://api.anthropic.com
  openai: https://my-openai-mirror.internal
  ollama: http://gpu-box:11434
```

Claude Code example — no Knarr API key needed, your existing key works.
Without any provider key in the container nothing is routed, so every
request passes through:

```bash
docker run -p 8080:8080 raudssus/langertha-knarr
ANTHROPIC_BASE_URL=http://localhost:8080 claude
```

### Upstream Timeouts

An upstream that never answers does not hold a client forever. A
non-streaming request may take `upstream_timeout` seconds in total (default
`300`); a stream may go `upstream_stall_timeout` seconds without data
(default `120`), however long it runs overall. `0` disables either.

```yaml
upstream_timeout: 300
upstream_stall_timeout: 120
```

A passthrough request that runs out is answered with `504` in the client's
own error shape (OpenAI `{"error":{"message":...}}`, Anthropic
`timeout_error`, Ollama `{"error":"..."}`). A stream that stalls after its
headers went out ends with the protocol's error frame. Routed engines get
`upstream_timeout` as their `user_agent_timeout` unless the model config
sets its own (for a stream it is their time without data). A routed engine
or the Passthrough handler that runs out is answered the same way, 504 or
the error frame; this needs a Langertha whose async requests report their
timeouts. Any other failure there stays a `500`. Langfuse posts give up after 5 seconds and are only logged.

### Generating a Config

Knarr can generate a config from your environment:

```bash
# Via Docker — pass your env vars through; -l makes the config listen
# on all interfaces, as a container needs
docker run --rm --env-file .env raudssus/langertha-knarr \
  init -l 0.0.0.0:8080 -l 0.0.0.0:11434 > knarr.yaml

# Or pass all API keys from your current shell
docker run --rm \
  $(env | grep -E '_(API_KEY|API_TOKEN)=|^LANGFUSE_' | sed 's/^/-e /') \
  raudssus/langertha-knarr init -l 0.0.0.0:8080 -l 0.0.0.0:11434 > knarr.yaml
```

The generated config enables `auto_discover`, sets OpenAI as default
engine when an OpenAI key was found, names the variable each key was found
in as `api_key_env` (the default engine included), and has no
`passthrough:` section —
add one if you want it. Then mount it:

```bash
docker run --env-file .env \
  -v ./knarr.yaml:/etc/knarr/config.yaml \
  -p 8080:8080 -p 11434:11434 \
  raudssus/langertha-knarr start -c /etc/knarr/config.yaml -p 8080 -p 11434
```

The `-p` flags after `start` bind `0.0.0.0` whatever `listen:` says; they
are needed whenever the config listens on `127.0.0.1` (the `knarr init`
default without `-l`).

## All Environment Variables

### API Keys

`--from-env` and `knarr init` detect every provider from its bare vendor
variable; the `LANGERTHA_`-prefixed variant (e.g.
`LANGERTHA_OPENAI_API_KEY`) takes priority, and the `TEST_LANGERTHA_*`
variant is the last resort (`knarr init` only; `--from-env` ignores
`TEST_*`):

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
| `KNARR_PUBLIC_URL` | Public base URL published in `/.well-known/langertha.json` | from the request |
| `KNARR_DEBUG` | Enable verbose logging (`1` = on) | — (off) |
| `KNARR_UPSTREAM_TIMEOUT` | Seconds an upstream may take for a non-streaming request; also the routed engines' `user_agent_timeout` (`0` disables) | `300` |
| `KNARR_UPSTREAM_STALL_TIMEOUT` | Seconds a passthrough stream may go without data (`0` disables) | `120` |
| `KNARR_PROBE_CAPABILITIES` | Ask gateway / self-hosted engines' model metadata once at startup which models see images (`0` disables) | `1` |
| `KNARR_PROBE_TIMEOUT` | Seconds one such capability probe may take before it is logged and given up (`0`: only the engine's own timeout) | `10` |
| `KNARR_OLLAMA_COMPAT_VERSION` | Ollama version reported at `GET /api/version` (a compatibility claim, not Knarr's version); digits and dots only (`x.y.z`), at least `0.6.4` for VS Code Copilot | `0.34.4` |

## CLI Reference

```
knarr                                      Show help
knarr start                                Start with config file (./knarr.yaml)
knarr start --from-env                     Use ./knarr.yaml if present, else auto-detect config from ENV
knarr start --from-env -p 8080 -p 11434   ENV config, explicit ports (Docker default)
knarr start -p 9090                        Listen on 0.0.0.0:9090 only
knarr start -H 127.0.0.1 -p 9090           Listen on 127.0.0.1:9090 only
knarr start -c prod.yaml                   Custom config
knarr start -v                             Verbose logging
knarr start -n my-proxy                    Custom Langfuse trace name
knarr start --log-file /var/log/knarr.jsonl   JSONL request log
knarr start --log-dir /var/log/knarr/reqs     Per-request JSON logs
knarr init                                 Generate config from environment
knarr init -e .env                         Include .env file in scan
knarr init -l 0.0.0.0:8080 -o knarr.yaml   Listen address(es), write to a file
knarr models                               List configured and discovered models
knarr models -f json                       Same as JSON
knarr check                                Validate config file
```

- `-c` / `--config` and `-v` / `--verbose` work before the subcommand
  (`knarr -c prod.yaml start`) and after `start`, `check` and `models`
  (`knarr start -c prod.yaml -v`). Set `KNARR_DEBUG=1` for verbose logging
  too.
- Long options work with dashes or underscores (`--log-file`,
  `--log_file`, `--from-env`, `--trace-name`), in any position.
- `-p` / `--port` is repeatable; each occurrence adds a listen port on the
  host from `-H` / `--host` (default `0.0.0.0`). Given at least once, the
  ports replace the config's `listen:`. Without `-p` Knarr listens on
  `listen:`, which defaults to `127.0.0.1:8080` and `127.0.0.1:11434` —
  also under `--from-env`. `-H` without `-p` has no effect.
- `init` always scans `.env` and `.env.local` in the current directory and
  `~/.env`, plus every `-e` file; its config listens on `127.0.0.1:8080`
  and `127.0.0.1:11434` unless `-l` says otherwise.
- `-w` / `--workers` is accepted but currently has no effect: Knarr runs
  as a single process.
- `knarr container` is a deprecated alias of the Docker image's own
  command, `knarr start --from-env -p 8080 -p 11434`: it always listens on
  `0.0.0.0:8080` and `0.0.0.0:11434` and takes no options of its own (the
  global `-c`/`-v` before it still apply). For other ports use
  `knarr start --from-env -p ...`.

## Binary (no Perl needed)

Prebuilt Linux binaries are attached to each
[GitHub release](https://github.com/Getty/langertha-knarr/releases):
`knarr-<version>-linux-x86_64` and `knarr-<version>-linux-aarch64`, each as
a raw executable and as a `.tar.gz` (binary, LICENSE and an example config);
a single `knarr-<version>-checksums.txt` covers them all. Download, verify
with `sha256sum -c --ignore-missing knarr-<version>-checksums.txt` (the flag
skips the assets you did not download), `chmod +x`, and run — no Perl, CPAN
or Docker needed:

```bash
chmod +x knarr-<version>-linux-x86_64
./knarr-<version>-linux-x86_64 init > knarr.yaml
./knarr-<version>-linux-x86_64 start
```

The target needs the system libraries `libssl` and `libcrypto` (OpenSSL 3,
package `libssl3` on Debian/Ubuntu — present on any normal Linux), plus a CA
bundle (`ca-certificates`) for HTTPS upstreams. The binary is ~14 MB and
bundles its own Perl with every Langertha engine; third-party
`LangerthaX::*` engines and plugins are not included. On first run it
unpacks itself into a cache (`$TMPDIR/par-<user>/`, or `PAR_GLOBAL_TEMP` if
set), which takes a few seconds once; after that it starts a little slower
than the CPAN install (~0.5 s vs ~0.25 s) — it is for distribution
convenience, not speed.

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
and pass it to a `Langertha::Knarr` instance. `knarr start` does exactly
this from a config file:

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
  router  => $router,           # for /api/show and the capability probe
  loop    => $loop,
  listen  => $config->listen,   # arrayref of "host:port" strings
  # optional, as knarr start passes them from the config:
  # auth_token            => $config->proxy_api_key,
  # public_url            => $config->public_url,
  # ollama_compat_version => $config->ollama_compat_version,
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

`knarr start` applies each wrapper whenever it has something to do:
tracing when Langfuse keys are set (config or environment), request
logging when a log file or directory is set (config, environment or
command line).

#### Adding passthrough

To preserve the "configured models go through Langertha, everything else
tunnels straight to the upstream API" behaviour, hand one
`Handler::Passthrough` to both the router handler and the server:

```perl
use Langertha::Knarr::Handler::Passthrough;

my $passthrough = Langertha::Knarr::Handler::Passthrough->new(
  upstreams     => $config->passthrough,   # { openai => 'https://api.openai.com', ... }
  loop          => $loop,
  timeout       => $config->upstream_timeout,
  stall_timeout => $config->upstream_stall_timeout,
);
my $handler = Langertha::Knarr::Handler::Router->new(
  router      => $router,
  passthrough => $passthrough,
);
my $knarr = Langertha::Knarr->new(
  handler         => $handler,
  router          => $router,
  raw_passthrough => $passthrough,   # byte-for-byte tunnel
  tracing         => $tracing,       # optional: traces the raw tunnel
  loop            => $loop,
  listen          => $config->listen,
);
```

`raw_passthrough` together with `router` is what pipes the bytes 1:1:
Knarr sends an unknown model straight to the upstream, before the handler
chain. As the router handler's `passthrough` alone, the handler forwards
the request but the answer is re-framed through the protocol formatter
(text, tool calls and finish reason survive; usage, cache fields and
other provider metadata do not).

#### A fake handler for tests (`Handler::Code`)

`Handler::Code` wraps a coderef, so you can stand up a Knarr server
without any real backend — the `*_live.t` tests do exactly this:

```perl
use Langertha::Knarr::Handler::Code;

my $handler = Langertha::Knarr::Handler::Code->new(
  code => sub {
    my ($session, $request) = @_;
    return "Echo: " . $request->messages->[-1]{content};
  },
  # optional: returns a generator that yields one chunk per call, undef at the end
  stream_code => sub {
    my ($session, $request) = @_;
    my @chunks = ("Hello", " ", "world", "!");
    return sub { @chunks ? shift @chunks : undef };
  },
);
```

Without `stream_code`, a streaming request gets the `code` answer as one
chunk.

#### PSGI

`Langertha::Knarr::PSGI` runs the same Knarr under any Plack server, with
the same routes, authentication and (with `raw_passthrough` set) raw
passthrough. Streams are buffered:
the client gets the whole answer at once.

```perl
# app.psgi
use Langertha::Knarr;
use Langertha::Knarr::PSGI;
my $knarr = Langertha::Knarr->new( handler => $handler, router => $router );
Langertha::Knarr::PSGI->new( knarr => $knarr )->to_app;
```

Under PSGI the startup capability probe does not run by itself; call
`$router->probe_capabilities_f` if you want it.

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
# Order: configured models, auto-discovered models, the default engine

my $response = $engine->simple_chat(
  { role => 'user', content => 'Hello!' },
);
```

## Built With

- [Langertha](https://metacpan.org/pod/Langertha) — Perl LLM framework with engines for all major providers and self-hosted servers
- [IO::Async](https://metacpan.org/pod/IO::Async) + [Net::Async::HTTP::Server](https://metacpan.org/pod/Net::Async::HTTP::Server) — Async event loop and HTTP server
- [Future::AsyncAwait](https://metacpan.org/pod/Future::AsyncAwait) — Native async/await for Perl
- [Moose](https://metacpan.org/pod/Moose) — Postmodern object system
- [Langfuse](https://langfuse.com) — Open source LLM observability

## License

This software is copyright (c) 2026 by Torsten Raudssus.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.
