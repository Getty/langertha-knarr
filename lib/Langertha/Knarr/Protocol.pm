package Langertha::Knarr::Protocol;
# ABSTRACT: Base role for Steerboard wire protocols (OpenAI, Anthropic, Ollama)
our $VERSION = "0.008";
use Moose::Role;

# Identifier (e.g. 'openai', 'anthropic', 'ollama').
requires 'protocol_name';

# Returns arrayref of route specs:
#   [ { method => 'POST', path => '/v1/chat/completions', action => 'chat' }, ... ]
requires 'protocol_routes';

# parse_chat_request($http_req, $body_ref) -> Langertha::Knarr::Request
requires 'parse_chat_request';

# format_chat_response($response, $request) -> ($status, \%headers, $body)
requires 'format_chat_response';

# format_stream_chunk($chunk, $request) -> string (raw bytes for the wire)
# Default: SSE-style "data: {...}\n\n" — protocols may override (Ollama uses NDJSON).
sub format_stream_chunk {
  my ($self, $chunk_json) = @_;
  return "data: $chunk_json\n\n";
}

sub format_stream_done {
  my ($self) = @_;
  return "data: [DONE]\n\n";
}

# Optional lifecycle hooks for protocols that need to frame the stream
# (Anthropic message_start/stop, A2A status events, ACP run.created, AGUI RUN_STARTED).
# Default: empty — protocols like OpenAI / Ollama don't need them.
sub format_stream_open  { '' }
sub format_stream_close { '' }

# Content-Type for streaming responses. Default is SSE; Ollama overrides.
sub stream_content_type { 'text/event-stream' }

# format_models_response(\@models) -> ($status, \%headers, $body)
sub format_models_response {
  my ($self, $models) = @_;
  return ( 200, { 'Content-Type' => 'application/json' }, '{"data":[]}' );
}

1;
