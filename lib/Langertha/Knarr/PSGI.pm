package Langertha::Knarr::PSGI;
# ABSTRACT: PSGI adapter for Langertha::Knarr (buffered, no streaming)
our $VERSION = "0.008";
use Moose;
use JSON::MaybeXS;
use Langertha::Knarr::Request;

# Wraps a Langertha::Knarr instance and returns a PSGI app coderef.
# Streaming requests are coerced into buffered responses: the full body is
# assembled (open + chunks + close + done) before being returned to the
# PSGI server. Use the native Net::Async::HTTP::Server entrypoint
# (Steerboard->run) if you need real streaming.

has steerboard => ( is => 'ro', required => 1 );

has _json => (
  is => 'ro',
  default => sub { JSON::MaybeXS->new( utf8 => 1, canonical => 1 ) },
);

sub to_app {
  my ($self) = @_;
  return sub {
    my ($env) = @_;
    return $self->_handle_psgi($env);
  };
}

sub _read_body {
  my ($self, $env) = @_;
  my $input = $env->{'psgi.input'} or return '';
  my $len = $env->{CONTENT_LENGTH} // 0;
  return '' unless $len;
  my $body = '';
  my $read = 0;
  while ( $read < $len ) {
    my $chunk;
    my $n = $input->read( $chunk, $len - $read );
    last unless $n;
    $body .= $chunk;
    $read += $n;
  }
  return $body;
}

sub _handle_psgi {
  my ($self, $env) = @_;
  my $sb = $self->steerboard;
  my $method = $env->{REQUEST_METHOD};
  my $path   = $env->{PATH_INFO} // '/';

  my $route = $sb->_match_route( $method, $path );
  unless ( $route ) {
    return [ 404, [ 'Content-Type' => 'application/json' ],
      [ $self->_json->encode({ error => { message => "no route for $method $path" } }) ] ];
  }

  my $proto = $route->{protocol};
  my $action = $route->{action};

  if ( $action eq 'models' || $action eq 'acp_agents' ) {
    my $models = $sb->handler->list_models;
    my ($status, $headers, $body) = $proto->format_models_response($models);
    return [ $status, [ %$headers ], [ $body ] ];
  }
  if ( $action eq 'a2a_card' ) {
    my ($status, $headers, $body) = $proto->format_agent_card;
    return [ $status, [ %$headers ], [ $body ] ];
  }
  if ( $action ne 'chat' ) {
    return [ 500, [ 'Content-Type' => 'application/json' ],
      [ $self->_json->encode({ error => { message => "unknown action $action" } }) ] ];
  }

  my $body = $self->_read_body($env);
  my $fake_http = Langertha::Knarr::PSGI::FakeReq->new( $env );
  my $sb_req = $proto->parse_chat_request( $fake_http, \$body );
  my $session = $sb->session( $sb_req->session_id );
  my $handler = $sb->handler->route_model( $sb_req->model );

  if ( $sb_req->stream ) {
    # Buffered streaming: drive the stream to completion, concatenate frames.
    my $stream = $handler->handle_stream_f( $session, $sb_req )->get;
    my $out = $proto->format_stream_open($sb_req);
    while ( defined( my $delta = $stream->next_chunk_f->get ) ) {
      $out .= $proto->format_stream_chunk( $delta, $sb_req );
    }
    $out .= $proto->format_stream_close($sb_req);
    $out .= $proto->format_stream_done($sb_req);
    return [ 200, [ 'Content-Type' => $proto->stream_content_type ], [ $out ] ];
  }

  my $response = $handler->handle_chat_f( $session, $sb_req )->get;
  my ($status, $headers, $obody) = $proto->format_chat_response( $response, $sb_req );
  return [ $status, [ %$headers ], [ $obody ] ];
}

package Langertha::Knarr::PSGI::FakeReq;
sub new {
  my ($class, $env) = @_;
  return bless { env => $env }, $class;
}
sub header {
  my ($self, $name) = @_;
  ( my $key = uc $name ) =~ tr/-/_/;
  return $self->{env}{"HTTP_$key"};
}

package Langertha::Knarr::PSGI;
__PACKAGE__->meta->make_immutable;
1;
