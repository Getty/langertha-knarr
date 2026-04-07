package Langertha::Knarr;
# ABSTRACT: Universal LLM hub — proxy, server, and translator across OpenAI/Anthropic/Ollama/A2A/ACP/AG-UI
our $VERSION = '0.008';
use Moose;
use Future::AsyncAwait;
use IO::Async::Loop;
use Net::Async::HTTP::Server;
use HTTP::Response;
use JSON::MaybeXS;
use Data::UUID;
use Module::Runtime qw( use_module );
use Scalar::Util qw( blessed );
use Try::Tiny;
use Langertha::Knarr::Session;

=head1 SYNOPSIS

    use IO::Async::Loop;
    use Langertha::Knarr;
    use Langertha::Knarr::Handler::Raider;

    my $loop = IO::Async::Loop->new;

    my $sb = Langertha::Knarr->new(
        handler => Langertha::Knarr::Handler::Raider->new(
            raider_factory => sub { build_raider_for_session(@_) },
        ),
        loop => $loop,
        host => '0.0.0.0',
        port => 8088,
    );
    $sb->run;  # blocks; OpenWebUI etc. can now connect

=head1 DESCRIPTION

Langertha::Knarr is a generic I/O hub that exposes any Steerboard
B<handler> (a L<Langertha::Raider>, a raw L<Langertha::Engine>, or any
custom backend) over the standard LLM HTTP wire protocols spoken by tools
like OpenWebUI, the OpenAI/Anthropic/Ollama clients, and the agent
ecosystems around A2A, ACP, and AG-UI.

By default the server loads every protocol it ships with, so a single
running Steerboard answers OpenAI C</v1/chat/completions>, Anthropic
C</v1/messages>, Ollama C</api/chat>, A2A's C</.well-known/agent.json>
plus JSON-RPC C</>, ACP's C</runs>, and AG-UI's C</awp> simultaneously.
The same handler implementation drives all of them.

=head1 ARCHITECTURE

Three pluggable layers:

=over

=item B<Protocols>

Wire formats (OpenAI, Anthropic, Ollama, A2A, ACP, AG-UI) live in
C<Langertha::Knarr::Protocol::*>. Each consumes
L<Langertha::Knarr::Protocol> and is loaded by default.

=item B<Handlers>

Backend logic — what answers the request. Ships with
L<Langertha::Knarr::Handler::Code>,
L<Langertha::Knarr::Handler::Engine>,
L<Langertha::Knarr::Handler::Raider>,
L<Langertha::Knarr::Handler::A2AClient>, and
L<Langertha::Knarr::Handler::ACPClient>. Implement
L<Langertha::Knarr::Handler> to write your own.

=item B<Transport>

Default is L<Net::Async::HTTP::Server> with chunked SSE/NDJSON streaming.
For environments that need PSGI, L<Langertha::Knarr::PSGI> wraps
the same Steerboard instance into a PSGI app (buffered, no streaming).

=back

=cut


has handler => (
  is => 'ro',
  required => 1,
);

has host => (
  is => 'ro',
  isa => 'Str',
  default => '127.0.0.1',
);

has port => (
  is => 'ro',
  isa => 'Int',
  default => 8088,
);

# Listen on one or more addresses. Each entry is either "host:port" or
# { host => ..., port => ... }. Defaults to a single entry composed from
# the host/port attributes above.
has listen => (
  is => 'ro',
  isa => 'ArrayRef',
  lazy => 1,
  builder => '_build_listen',
);

sub _build_listen {
  my ($self) = @_;
  return [ { host => $self->host, port => $self->port + 0 } ];
}

has loop => (
  is => 'ro',
  lazy => 1,
  builder => '_build_loop',
);
sub _build_loop { IO::Async::Loop->new }

has protocols => (
  is => 'ro',
  isa => 'ArrayRef[Str]',
  default => sub { [qw( OpenAI Anthropic Ollama A2A ACP AGUI )] },
);

has _protocol_objects => (
  is => 'ro',
  lazy => 1,
  builder => '_build_protocol_objects',
);

has _routes => (
  is => 'ro',
  lazy => 1,
  builder => '_build_routes',
);

has _sessions => (
  is => 'ro',
  default => sub { {} },
);

has _uuid => (
  is => 'ro',
  default => sub { Data::UUID->new },
);

has _json => (
  is => 'ro',
  default => sub { JSON::MaybeXS->new( utf8 => 1, canonical => 1 ) },
);

has _server => (
  is => 'rw',
);

sub _build_protocol_objects {
  my ($self) = @_;
  my @objs;
  for my $name ( @{ $self->protocols } ) {
    my $class = $name =~ /::/ ? $name : "Langertha::Knarr::Protocol::$name";
    use_module($class);
    push @objs, $class->new( steerboard => $self );
  }
  return \@objs;
}

sub _build_routes {
  my ($self) = @_;
  my @routes;
  for my $proto ( @{ $self->_protocol_objects } ) {
    for my $r ( @{ $proto->protocol_routes } ) {
      push @routes, { %$r, protocol => $proto };
    }
  }
  return \@routes;
}

sub session {
  my ($self, $id) = @_;
  $id //= $self->_uuid->create_str;
  $self->_sessions->{$id} //= Langertha::Knarr::Session->new( id => $id );
  $self->_sessions->{$id}->touch;
  return $self->_sessions->{$id};
}

sub _listen_addrs {
  my ($self) = @_;
  my @out;
  for my $entry ( @{ $self->listen } ) {
    if ( ref $entry eq 'HASH' ) {
      push @out, { host => $entry->{host} // '127.0.0.1', port => $entry->{port} + 0 };
    } else {
      my ($h, $p) = split /:/, $entry, 2;
      $h ||= '127.0.0.1';
      push @out, { host => $h, port => ($p // 8088) + 0 };
    }
  }
  return @out;
}

sub start {
  my ($self) = @_;
  my $server = Net::Async::HTTP::Server->new(
    on_request => sub {
      my ($srv, $req) = @_;
      $self->_dispatch($req);
    },
  );
  $self->loop->add($server);
  for my $a ( $self->_listen_addrs ) {
    $server->listen(
      addr => {
        family   => 'inet',
        socktype => 'stream',
        port     => $a->{port},
        ip       => $a->{host},
      },
    )->get;
  }
  $self->_server($server);
  return $self;
}

sub run {
  my ($self) = @_;
  $self->start unless $self->_server;
  $self->loop->run;
}

sub _match_route {
  my ($self, $method, $path) = @_;
  for my $r ( @{ $self->_routes } ) {
    next unless $r->{method} eq $method;
    return $r if $r->{path} eq $path;
  }
  return undef;
}

sub _dispatch {
  my ($self, $req) = @_;
  my $method = $req->method;
  my $path   = $req->path;
  my $route  = $self->_match_route( $method, $path );
  unless ( $route ) {
    return $self->_send_simple( $req, 404, 'application/json',
      $self->_json->encode({ error => { message => "no route for $method $path" } }) );
  }
  my $action = $route->{action};
  my $proto  = $route->{protocol};
  my $code = $self->can("_action_$action");
  unless ( $code ) {
    return $self->_send_simple( $req, 500, 'application/json',
      $self->_json->encode({ error => { message => "unknown action $action" } }) );
  }
  try {
    $self->$code( $proto, $req );
  } catch {
    my $err = $_;
    $self->_send_simple( $req, 500, 'application/json',
      $self->_json->encode({ error => { message => "$err" } }) );
  };
}

sub _action_chat {
  my ($self, $proto, $req) = @_;
  my $body = $req->body;
  my $sb_req = $proto->parse_chat_request( $req, \$body );
  my $session = $self->session( $sb_req->session_id );
  my $handler = $self->handler->route_model( $sb_req->model );

  if ( $sb_req->stream ) {
    return $self->_handle_stream( $proto, $req, $sb_req, $session, $handler );
  }

  my $f = $handler->handle_chat_f( $session, $sb_req );
  $f->on_done( sub {
    my ($response) = @_;
    try {
      my ($status, $headers, $body) = $proto->format_chat_response( $response, $sb_req );
      $self->_send_simple( $req, $status, $headers->{'Content-Type'} // 'application/json', $body );
    } catch {
      my $err = $_;
      $self->_send_simple( $req, 500, 'application/json',
        $self->_json->encode({ error => { message => "$err" } }) );
    };
  });
  $f->on_fail( sub {
    my ($err) = @_;
    $self->_send_simple( $req, 500, 'application/json',
      $self->_json->encode({ error => { message => "$err" } }) );
  });
  $f->retain;
}

sub _handle_stream {
  my ($self, $proto, $req, $sb_req, $session, $handler) = @_;

  my $header = HTTP::Response->new( 200 );
  $header->protocol('HTTP/1.1');
  $header->header( 'Content-Type'  => $proto->stream_content_type );
  $header->header( 'Cache-Control' => 'no-cache' );
  $req->respond_chunk_header( $header );

  my $write = sub {
    my ($bytes) = @_;
    return unless defined $bytes && length $bytes;
    return if $req->is_closed;
    $req->write_chunk( $bytes );
  };

  my $f = $handler->handle_stream_f( $session, $sb_req );
  $f->on_done( sub {
    my ($stream) = @_;
    $write->( $proto->format_stream_open($sb_req) );
    my $pump; $pump = sub {
      if ( $req->is_closed ) { undef $pump; return }
      $stream->next_chunk_f->on_done( sub {
        my ($delta) = @_;
        if ( $req->is_closed ) { undef $pump; return }
        if ( defined $delta ) {
          $write->( $proto->format_stream_chunk( $delta, $sb_req ) );
          $pump->();
        }
        else {
          $write->( $proto->format_stream_close($sb_req) );
          $write->( $proto->format_stream_done($sb_req) );
          $req->write_chunk_eof;
          undef $pump;
        }
      })->on_fail( sub {
        my ($err) = @_;
        $write->( $proto->format_stream_chunk( "[error: $err]", $sb_req ) );
        $write->( $proto->format_stream_close($sb_req) );
        $req->write_chunk_eof;
        undef $pump;
      });
    };
    $pump->();
  });
  $f->on_fail( sub {
    my ($err) = @_;
    $write->( $proto->format_stream_chunk( "[error: $err]", $sb_req ) );
    $req->write_chunk_eof;
  });
  $f->retain;
}

sub _action_acp_agents { goto &_action_models }
sub _action_a2a_card {
  my ($self, $proto, $req) = @_;
  my ($status, $headers, $body) = $proto->format_agent_card;
  $self->_send_simple( $req, $status, $headers->{'Content-Type'} // 'application/json', $body );
}

sub _action_models {
  my ($self, $proto, $req) = @_;
  my $models = $self->handler->list_models;
  my ($status, $headers, $body) = $proto->format_models_response( $models );
  $self->_send_simple( $req, $status, $headers->{'Content-Type'} // 'application/json', $body );
}

sub _send_simple {
  my ($self, $req, $status, $ctype, $body) = @_;
  my $resp = HTTP::Response->new( $status );
  $resp->protocol('HTTP/1.1');
  $resp->header( 'Content-Type'   => $ctype );
  $resp->header( 'Content-Length' => length($body) );
  $resp->content($body);
  $req->respond($resp);
}

__PACKAGE__->meta->make_immutable;
1;
