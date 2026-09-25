package Langertha::Knarr::Protocol::OpenAI;
# ABSTRACT: OpenAI-compatible wire protocol (chat/completions, models) for Knarr

=head1 DESCRIPTION

Implements the OpenAI Chat Completions wire format on top of
L<Langertha::Knarr::Protocol>. Loaded by default in every
L<Langertha::Knarr> instance.

=over

=item * C<POST /v1/chat/completions> — sync and SSE streaming

=item * C<GET /v1/models> — model listing

=back

Streaming uses the standard SSE chunk format with C<data: [DONE]> as
the terminator. C<tools>, C<tool_choice>, and C<response_format> are
extracted into L<Langertha::Knarr::Request> attributes and forwarded to
the engine via C<chat_f>. Tool-call responses are serialised into
C<message.tool_calls> with C<finish_reason: "tool_calls">.

=cut
our $VERSION = '1.102';
use Moose;
use JSON::MaybeXS;
use Time::HiRes qw( time );
use Langertha::Knarr::Request;
use Langertha::Knarr::Response;

with 'Langertha::Knarr::Protocol';

has _json => (
  is => 'ro',
  default => sub { JSON::MaybeXS->new( utf8 => 1, canonical => 1 ) },
);

# Tool arguments become a JSON string inside a chunk that _json encodes to
# UTF-8, so they are encoded to characters here, not to bytes.
has _args_json => ( is => 'ro', default => sub { JSON::MaybeXS->new( canonical => 1 ) } );

sub protocol_name { 'openai' }

sub protocol_routes {
  return [
    { method => 'POST', path => '/v1/chat/completions', action => 'chat'   },
    { method => 'GET',  path => '/v1/models',           action => 'models' },
  ];
}

# Provider manifest (k14): what parse_chat_request below carries to the
# engine. The whole OpenAI tool / structured-output / control surface is
# forwarded; thinking_budget, prompt_cache (Anthropic cache_control) and
# server_tools are not.
sub manifest_endpoint {
  return {
    dialect      => 'openai-chat',
    path         => '/v1',
    capabilities => [qw(
      chat streaming system_prompt
      tools_native tools_hermes
      tool_choice_auto tool_choice_any tool_choice_none tool_choice_named
      parallel_tool_use
      response_format_json_object response_format_json_schema
      reasoning_effort temperature seed response_size prompt_cache_key
    )],
  };
}

sub parse_chat_request {
  my ($self, $http_req, $body_ref) = @_;
  my $data = $self->_json->decode( $$body_ref || '{}' );
  # Capture auth headers for passthrough
  my %fwd;
  for my $h (qw( authorization )) {
    my $v = scalar $http_req->header($h);
    $fwd{$h} = $v if defined $v && length $v;
  }
  return Langertha::Knarr::Request->new(
    protocol        => 'openai',
    raw             => $data,
    model           => $data->{model},
    messages        => $data->{messages} || [],
    stream          => $data->{stream}      ? 1 : 0,
    temperature     => $data->{temperature},
    max_tokens      => $data->{max_tokens},
    reasoning_effort => $data->{reasoning_effort},
    seed             => $data->{seed},
    parallel_tool_use => $data->{parallel_tool_calls},
    prompt_cache_key => $data->{prompt_cache_key},
    tools           => $data->{tools},
    tool_choice     => $data->{tool_choice},
    response_format => $data->{response_format},
    session_id      => $data->{user} // scalar( $http_req->header('X-Session-Id') ),
    extra           => { forward_headers => \%fwd },
  );
}

# OpenAI's finish_reason is a closed enum; the engine carries the backend's
# own value (Anthropic end_turn/max_tokens/tool_use, Gemini STOP/MAX_TOKENS/
# SAFETY, Ollama stop/length, ...). Values already in OpenAI vocabulary pass
# through; a value with no OpenAI counterpart falls back like an absent one.
my %FINISH_REASON = (
  ( map { $_ => $_ } qw( stop length tool_calls content_filter function_call ) ),
  end_turn           => 'stop',
  stop_sequence      => 'stop',
  max_tokens         => 'length',
  tool_use           => 'tool_calls',
  refusal            => 'content_filter',
  safety             => 'content_filter',
  recitation         => 'content_filter',
  blocklist          => 'content_filter',
  prohibited_content => 'content_filter',
  spii               => 'content_filter',
);

sub _finish_reason {
  my ( $finish_reason, $has_tool_calls ) = @_;
  return 'tool_calls' if $has_tool_calls;
  return 'stop' unless defined $finish_reason;
  return $FINISH_REASON{ lc $finish_reason } // 'stop';
}

sub format_chat_response {
  my ($self, $response, $request) = @_;
  my $r = Langertha::Knarr::Response->coerce($response);
  my $message = { role => 'assistant', content => $r->content };
  my $finish = _finish_reason( $r->finish_reason, $r->has_tool_calls );
  if ( $r->has_tool_calls ) {
    $message->{tool_calls} = [ map { $_->to_openai } @{ $r->tool_calls } ];
  }
  my $usage = $r->usage && $r->usage->can('to_openai_format')
    ? $r->usage->to_openai_format
    : { prompt_tokens => 0, completion_tokens => 0, total_tokens => 0 };
  my $payload = {
    id      => 'chatcmpl-' . int( time() * 1000 ),
    object  => 'chat.completion',
    created => int( time() ),
    model   => $r->model // $request->model // 'unknown',
    choices => [
      {
        index   => 0,
        message => $message,
        finish_reason => $finish,
      },
    ],
    usage => $usage,
  };
  return ( 200, { 'Content-Type' => 'application/json' }, $self->_json->encode($payload) );
}

sub format_models_response {
  my ($self, $models) = @_;
  my @data = map {
    ref $_ eq 'HASH' ? { object => 'model', %$_ } : { id => "$_", object => 'model' }
  } @$models;
  my $payload = { object => 'list', data => \@data };
  return ( 200, { 'Content-Type' => 'application/json' }, $self->_json->encode($payload) );
}

sub format_stream_chunk {
  my ($self, $delta_text, $request) = @_;
  my $payload = {
    id => 'chatcmpl-stream',
    object  => 'chat.completion.chunk',
    created => int( time() ),
    model   => $request->model // 'unknown',
    choices => [ { index => 0, delta => { content => $delta_text }, finish_reason => undef } ],
  };
  return "data: " . $self->_json->encode($payload) . "\n\n";
}

# OpenAI streams end with a chunk whose delta is empty and whose
# finish_reason is set, before data: [DONE]. The routed stream carries the
# backend's tool calls complete, so they go out ahead of it in one chunk:
# delta.tool_calls with every call whole, keyed by index (k19).
sub format_stream_close {
  my ($self, $request, $finish_reason, $tool_calls) = @_;
  my @calls = @{ $tool_calls // [] };
  my $out = '';
  if (@calls) {
    my @delta_calls;
    for my $index ( 0 .. $#calls ) {
      my $wire = $calls[$index]->to_openai( fallback_id => 'call_knarr_' . ( $index + 1 ) );
      push @delta_calls, {
        index    => $index,
        id       => $wire->{id},
        type     => 'function',
        function => {
          name      => $wire->{function}{name},
          arguments => $self->_args_json->encode( $calls[$index]->arguments // {} ),
        },
      };
    }
    $out .= $self->_stream_chunk( $request,
      { index => 0, delta => { tool_calls => \@delta_calls }, finish_reason => undef } );
  }
  $out .= $self->_stream_chunk( $request,
    { index => 0, delta => {}, finish_reason => _finish_reason( $finish_reason, scalar @calls ) } );
  return $out;
}

sub _stream_chunk {
  my ($self, $request, $choice) = @_;
  my $payload = {
    id => 'chatcmpl-stream',
    object  => 'chat.completion.chunk',
    created => int( time() ),
    model   => $request->model // 'unknown',
    choices => [ $choice ],
  };
  return "data: " . $self->_json->encode($payload) . "\n\n";
}

__PACKAGE__->meta->make_immutable;
1;
