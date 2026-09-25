package Langertha::Knarr::Protocol::Ollama;
# ABSTRACT: Ollama-compatible wire protocol (/api/chat, /api/tags) for Knarr

=head1 DESCRIPTION

Implements the Ollama wire format on top of
L<Langertha::Knarr::Protocol>. Loaded by default.

=over

=item * C<POST /api/chat>, C<POST /api/generate> — chat with NDJSON streaming

=item * C<GET /api/tags> — model listing

=item * C<GET /api/version> — version probe, answered with Ollama's shape
C<{"version":"x.y.z"}> and the Ollama version Knarr claims compatibility
with (L<Langertha::Knarr/ollama_compat_version>), not Knarr's own version

=item * C<POST /api/show> — model details for a listed model (see
L</format_show_response>); C<model> or the legacy C<name> in the body,
C<400> without one, Ollama's C<404> C<{"error":"model 'x' not found"}> for
a model Knarr does not list

=back

Streaming uses newline-delimited JSON (NDJSON) rather than SSE — the
C<Content-Type> is C<application/x-ndjson> and each chunk is a single
JSON object per line. The final chunk has C<done: true>.

=cut
our $VERSION = '1.102';
use Moose;
use JSON::MaybeXS;
use Time::HiRes qw( time );
use POSIX qw( strftime );
use Langertha::Knarr::Request;
use Langertha::Knarr::Response;
use Langertha::Knarr::Image;

with 'Langertha::Knarr::Protocol';

# --- Streaming model ---
# Ollama streams via newline-delimited JSON (NDJSON), NOT SSE.
# Each chunk: { model, created_at, message:{role,content}, done:false }
# Final:     { model, created_at, message:{role,content:""}, done:true,
#              total_duration, eval_count, ... }
# Content-Type stays application/x-ndjson (or application/json with chunked).
# ----------------------

has _json => ( is => 'ro', default => sub { JSON::MaybeXS->new( utf8 => 1, canonical => 1 ) } );

sub protocol_name { 'ollama' }

sub protocol_routes {
  return [
    { method => 'POST', path => '/api/chat',     action => 'chat'   },
    { method => 'POST', path => '/api/generate', action => 'chat'   },
    { method => 'GET',  path => '/api/tags',     action => 'models' },
    { method => 'GET',  path => '/api/version',  action => 'version' },
    { method => 'POST', path => '/api/show',     action => 'show'    },
  ];
}

# Provider manifest (k14): parse_chat_request below carries tools, format,
# options.temperature and options.seed. Ollama has no tool_choice; a schema
# in `format` is not mapped onto a json_schema response_format, so only
# the loose JSON mode is claimed; num_predict is not forwarded.
sub manifest_endpoint {
  return {
    dialect      => 'ollama',
    path         => '',
    capabilities => [qw(
      chat streaming system_prompt
      tools_native tools_hermes
      response_format_json_object
      temperature seed
      image_input
    )],
    # A message's images array becomes Langertha::Content::Image objects
    # (k33); an older core gets it as sent, read only by native Ollama.
    image_content_formats => Langertha::Knarr::Image::content_formats(qw( ollama )),
  };
}

sub _ts { strftime( "%Y-%m-%dT%H:%M:%S.000000000Z", gmtime ) }

sub parse_chat_request {
  my ($self, $http_req, $body_ref) = @_;
  my $data = $self->_json->decode( $$body_ref || '{}' );
  my @msgs;
  if ( $data->{messages} ) {
    @msgs = @{ Langertha::Knarr::Image::ollama_messages( $data->{messages} ) };
  }
  elsif ( defined $data->{prompt} ) {
    my %msg = ( role => 'user', content => $data->{prompt} );
    # /api/generate carries images on the request, not a message (k34).
    # Only a translating core gets them; an older one sees the prompt
    # alone, as before.
    $msg{images} = $data->{images}
      if ref $data->{images} eq 'ARRAY' && @{ $data->{images} }
      && Langertha::Knarr::Image::translates();
    @msgs = @{ Langertha::Knarr::Image::ollama_messages( [ \%msg ] ) };
  }
  return Langertha::Knarr::Request->new(
    protocol        => 'ollama',
    raw             => $data,
    model           => $data->{model},
    messages        => \@msgs,
    stream          => exists $data->{stream} ? ( $data->{stream} ? 1 : 0 ) : 1,  # Ollama defaults to stream
    temperature     => $data->{options}{temperature},
    seed            => $data->{options}{seed},
    tools           => $data->{tools},
    response_format => $data->{format},
  );
}

# Ollama's done_reason vocabulary is stop / length (plus load / unload for
# model-management answers, which carry no generation). Tool calls end with
# stop on Ollama's own wire. Every other reason -- tool_calls, end_turn,
# content_filter, Gemini SAFETY, ... -- has no Ollama counterpart and
# becomes stop.
my %DONE_REASON = (
  ( map { $_ => $_ } qw( stop length load unload ) ),
  max_tokens => 'length',
);

sub _done_reason {
  my ($finish_reason) = @_;
  return 'stop' unless defined $finish_reason;
  return $DONE_REASON{ lc $finish_reason } // 'stop';
}

sub format_chat_response {
  my ($self, $response, $request) = @_;
  my $r = Langertha::Knarr::Response->coerce($response);
  my $message = { role => 'assistant', content => $r->content };
  $message->{tool_calls} = [ map { $_->to_ollama } @{ $r->tool_calls } ]
    if $r->has_tool_calls;
  my $payload = {
    model      => $r->model // $request->model // 'unknown',
    created_at => _ts(),
    message    => $message,
    done       => JSON::MaybeXS::true(),
    done_reason => _done_reason( $r->finish_reason ),
  };
  if ( $r->usage && $r->usage->can('to_ollama_format') ) {
    my $u = $r->usage->to_ollama_format;
    $payload->{$_} = $u->{$_} for keys %$u;
  }
  return ( 200, { 'Content-Type' => 'application/json' }, $self->_json->encode($payload) );
}

sub format_models_response {
  my ($self, $models) = @_;
  my @data = map {
    my $id = ref $_ eq 'HASH' ? $_->{id} : "$_";
    { name => $id, model => $id, modified_at => _ts(), size => 0 }
  } @$models;
  return ( 200, { 'Content-Type' => 'application/json' },
    $self->_json->encode({ models => \@data }) );
}

# GET /api/version (k27). Ollama clients read this as the server's Ollama
# version and may gate features on it, so it carries the Ollama version
# Knarr's endpoints are compatible with, never Knarr's own version.
sub format_version_response {
  my ($self, $version) = @_;
  return ( 200, { 'Content-Type' => 'application/json' },
    $self->_json->encode({ version => "$version" }) );
}

=method format_error_response

    my ($status, $headers, $body) = $proto->format_error_response( 404, "model 'x' not found" );

Ollama's error answer: C<{"error":"..."}> with a plain string, not the
C<{"error":{"message":...}}> object of the OpenAI wire.

=cut

sub format_error_response {
  my ($self, $status, $message) = @_;
  return ( $status, { 'Content-Type' => 'application/json' },
    $self->_json->encode({ error => "$message" }) );
}

=method format_show_response

    my ($status, $headers, $body) = $proto->format_show_response( $model, {
        capabilities   => [ 'completion', 'tools' ],
        context_length => 131072,   # optional
    } );

The C<POST /api/show> answer for a model Knarr serves (k29). Only what
Knarr knows is claimed: C<capabilities> as given, C<model_info> with
C<general.architecture> (C<knarr>) and C<knarr.context_length> when a
context length is known -- the pair VS Code Copilot reads, C<{}> otherwise
-- and empty C<details>, C<template> and C<parameters>, since there are no
local weights, template or Modelfile behind a routed model.

=cut

sub format_show_response {
  my ($self, $model, $info) = @_;
  my %model_info;
  if ( defined $info->{context_length} ) {
    %model_info = (
      'general.architecture' => 'knarr',
      'knarr.context_length' => $info->{context_length} + 0,
    );
  }
  my $payload = {
    modified_at  => _ts(),
    capabilities => [ @{ $info->{capabilities} || [] } ],
    details      => {
      parent_model       => '',
      format             => '',
      family             => '',
      families           => [],
      parameter_size     => '',
      quantization_level => '',
    },
    model_info => \%model_info,
    template   => '',
    parameters => '',
    license    => '',
  };
  return ( 200, { 'Content-Type' => 'application/json' }, $self->_json->encode($payload) );
}

sub format_stream_chunk {
  my ($self, $delta_text, $request) = @_;
  my $payload = {
    model      => $request->model // 'unknown',
    created_at => _ts(),
    message    => { role => 'assistant', content => $delta_text },
    done       => JSON::MaybeXS::false(),
  };
  return $self->_json->encode($payload) . "\n";
}

sub stream_content_type { 'application/x-ndjson' }

# The routed stream carries the backend's tool calls complete; Ollama's own
# wire sends message.tool_calls whole, so they ride on the done line (k19).
sub format_stream_done {
  my ($self, $request, $finish_reason, $tool_calls) = @_;
  my $message = { role => 'assistant', content => '' };
  $message->{tool_calls} = [ map { $_->to_ollama } @$tool_calls ]
    if $tool_calls && @$tool_calls;
  my $payload = {
    model      => $request->model // 'unknown',
    created_at => _ts(),
    message    => $message,
    done       => JSON::MaybeXS::true(),
    done_reason => _done_reason($finish_reason),
  };
  return $self->_json->encode($payload) . "\n";
}

__PACKAGE__->meta->make_immutable;
1;
