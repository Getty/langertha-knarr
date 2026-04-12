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
the terminator. Tool calls and tool choice pass through unchanged via
the request's C<raw> hash.

=cut
our $VERSION = '1.002';
use Moose;
use JSON::MaybeXS;
use Time::HiRes qw( time );
use Langertha::Knarr::Request;

with 'Langertha::Knarr::Protocol';

has steerboard => (
  is => 'ro',
  weak_ref => 1,
);

has _json => (
  is => 'ro',
  default => sub { JSON::MaybeXS->new( utf8 => 1, canonical => 1 ) },
);

sub protocol_name { 'openai' }

sub protocol_routes {
  return [
    { method => 'POST', path => '/v1/chat/completions', action => 'chat'   },
    { method => 'GET',  path => '/v1/models',           action => 'models' },
  ];
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
    protocol    => 'openai',
    raw         => $data,
    model       => $data->{model},
    messages    => $data->{messages} || [],
    stream      => $data->{stream}      ? 1 : 0,
    temperature => $data->{temperature},
    max_tokens  => $data->{max_tokens},
    tools       => $data->{tools},
    session_id  => $data->{user} // scalar( $http_req->header('X-Session-Id') ),
    extra       => { forward_headers => \%fwd },
  );
}

sub format_chat_response {
  my ($self, $response, $request) = @_;
  my $content = ref $response eq 'HASH' ? $response->{content} : "$response";
  my $model   = ( ref $response eq 'HASH' && $response->{model} ) || $request->model || 'steerboard';
  my $payload = {
    id      => 'chatcmpl-' . int( time() * 1000 ),
    object  => 'chat.completion',
    created => int( time() ),
    model   => $model,
    choices => [
      {
        index   => 0,
        message => { role => 'assistant', content => $content },
        finish_reason => 'stop',
      },
    ],
    usage => { prompt_tokens => 0, completion_tokens => 0, total_tokens => 0 },
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
    model   => $request->model // 'steerboard',
    choices => [ { index => 0, delta => { content => $delta_text }, finish_reason => undef } ],
  };
  return "data: " . $self->_json->encode($payload) . "\n\n";
}

__PACKAGE__->meta->make_immutable;
1;
