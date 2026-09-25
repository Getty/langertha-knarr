package Langertha::Knarr;
# ABSTRACT: Universal LLM hub — proxy, server, and translator across OpenAI/Anthropic/Ollama/A2A/ACP/AG-UI
our $VERSION = '1.102';
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
use Carp ();
use Log::Any qw( $log );
use Langertha::Knarr::Session;
use Langertha::Knarr::Manifest;

=head1 SYNOPSIS

The fastest way to use Knarr is the Docker image:

    docker run -e ANTHROPIC_API_KEY -p 8080:8080 raudssus/langertha-knarr
    ANTHROPIC_BASE_URL=http://localhost:8080 claude

The Perl API behind it:

    use IO::Async::Loop;
    use Langertha::Knarr;
    use Langertha::Knarr::Config;
    use Langertha::Knarr::Router;
    use Langertha::Knarr::Handler::Router;

    my $loop   = IO::Async::Loop->new;
    my $config = Langertha::Knarr::Config->new(file => 'knarr.yaml');
    my $router = Langertha::Knarr::Router->new(config => $config);

    my $knarr = Langertha::Knarr->new(
        handler => Langertha::Knarr::Handler::Router->new(router => $router),
        loop    => $loop,
        listen  => $config->listen,
    );
    $knarr->run;   # blocks; OpenWebUI etc. can now connect

=head1 DESCRIPTION

Langertha::Knarr is a universal LLM hub that exposes any backend — a
L<Langertha::Raider>, a raw L<Langertha::Engine>, a remote A2A or ACP
agent, or any custom L<Langertha::Knarr::Handler> — over the standard
LLM HTTP wire protocols spoken by OpenWebUI, the OpenAI / Anthropic /
Ollama SDKs, and the agent ecosystems around A2A, ACP, and AG-UI.

By default a single running Knarr answers OpenAI
C</v1/chat/completions>, Anthropic C</v1/messages>, Ollama
C</api/chat>, A2A's C</.well-known/agent.json> plus JSON-RPC C</>,
ACP's C</runs>, and AG-UI's C</awp> simultaneously on every listening
port. The same handler implementation drives all of them.

Knarr is built on L<IO::Async> and L<Net::Async::HTTP::Server>
with native L<Future::AsyncAwait> integration into Langertha engines,
so streaming works end-to-end token-by-token without any thread or
event-loop bridges.

=head1 MANIFEST

C<GET /.well-known/langertha.json> serves a Langertha provider manifest
(schema v1, see L<Langertha::Manifest>) so a client such as
C<raider --provider HOST> can configure itself. It is built by
L<Langertha::Knarr::Manifest> from what this Knarr exposes: one endpoint
per protocol with a manifest dialect (OpenAI C</v1> as C<openai-chat>,
Anthropic as C<anthropic-compat>, Ollama as C<ollama>), every listed model
(configured aliases and auto-discovered ids) on each of them, with the
serving engine's model-scoped capabilities narrowed to what that protocol
forwards, and an C<api_key> auth entry when L</auth_token> is set. The
route is protected by L</auth_token> like C<GET /v1/models>. It never
carries configuration: no upstream URL, key, key variable name, engine
class or passthrough target.

The manifest needs a Langertha that ships L<Langertha::Manifest::Builder>;
with an older one the route answers C<404> with a JSON error.

=head1 ARCHITECTURE

Three pluggable layers:

=over

=item B<Protocols>

Wire formats live in C<Langertha::Knarr::Protocol::*>. Each consumes
L<Langertha::Knarr::Protocol> and is loaded by default. See
L<Langertha::Knarr::Protocol::OpenAI>,
L<Langertha::Knarr::Protocol::Anthropic>,
L<Langertha::Knarr::Protocol::Ollama>,
L<Langertha::Knarr::Protocol::A2A>,
L<Langertha::Knarr::Protocol::ACP>,
L<Langertha::Knarr::Protocol::AGUI>.

=item B<Handlers>

Backend logic — what answers the request. Knarr ships with
L<Langertha::Knarr::Handler::Router> (the default, model→engine via
L<Langertha::Knarr::Router>), L<Langertha::Knarr::Handler::Engine>
(single engine), L<Langertha::Knarr::Handler::Raider> (per-session
agent), L<Langertha::Knarr::Handler::Passthrough> (raw HTTP forward),
L<Langertha::Knarr::Handler::A2AClient> /
L<Langertha::Knarr::Handler::ACPClient> (consume remote agents), and
L<Langertha::Knarr::Handler::Code> (coderef-backed for tests). Implement
L<Langertha::Knarr::Handler> to write your own. Decorators
(L<Langertha::Knarr::Handler::Tracing>,
L<Langertha::Knarr::Handler::RequestLog>) wrap any inner handler and
add behavior on top — they themselves consume the Handler role and
compose freely.

=item B<Transport>

Default is L<Net::Async::HTTP::Server> with chunked SSE / NDJSON
streaming on one or more listen sockets. For Plack deployments,
L<Langertha::Knarr::PSGI> wraps the same Knarr instance into a PSGI
app (buffered — see its docs for the streaming caveat).

=back

=attr handler

Required. An object consuming L<Langertha::Knarr::Handler>.

=attr listen

ArrayRef of C<host:port> strings or C<< { host => ..., port => ... } >>
hashes. Defaults to a single entry composed from L</host> and L</port>.

=attr host

Default C<127.0.0.1>. Used when L</listen> is not given.

=attr port

Default C<8088>. Used when L</listen> is not given.

=attr loop

Optional L<IO::Async::Loop> instance. Defaults to a fresh one.

=attr protocols

ArrayRef of protocol class basenames to load. Defaults to all six
shipped protocols.

=attr auth_token

Optional shared secret. When set, every incoming request must present
it as C<Authorization: Bearer> or C<x-api-key>. Discovery routes
(C</.well-known/agent.json>) stay anonymous.

=attr ollama_compat_version

The Ollama version reported at C<GET /api/version> as
C<{"version":"..."}>. Default C<0.34.4>, the current Ollama release when
it was chosen (2026-09-23). It is a compatibility claim, not Knarr's own
version: Ollama clients read it as the server's Ollama version. Two
clients set its limits:

=over

=item * VS Code Copilot (BYOK Ollama) refuses a server below C<0.6.4>.

=item * Open WebUI parses every dotted part with C<int()>, so anything but
digits and dots (C<0.34.4-knarr>, C<v0.34>) breaks its connection check.

=back

The value must therefore be three dot-separated numbers
(C</^\d+\.\d+\.\d+$/>); anything else croaks at construction. No
surveyed client gates C<think>, tools or C<format> on the version -- they
read C</api/show> capabilities per model -- so raising it enables nothing
Knarr lacks. Configured as C<ollama_compat_version> in the config file or
C<KNARR_OLLAMA_COMPAT_VERSION>.

=attr public_url

Optional public base URL (e.g. C<https://knarr.example>) used in the
provider manifest. When unset, the base URL is taken from the request
(C<Host>, and C<X-Forwarded-Proto> when it is C<http> or C<https>).

=method start

    $knarr->start;

Binds all listen sockets and registers the dispatcher. Returns
C<$self>. Does not enter the event loop.

=method run

    $knarr->run;   # blocks

Calls L</start> if needed, then enters the L</loop> and blocks.

=method session

    my $session = $knarr->session($id);

Returns the L<Langertha::Knarr::Session> for the given id, creating
one on demand. Used internally by the dispatcher.

=method manifest_response

    my ($status, $json_body) = $knarr->manifest_response(
        scheme => 'https', host => 'knarr.example', prefix => '' );

Builds the provider manifest (see L</MANIFEST>) and returns the HTTP
status and JSON body. The base URL is L</public_url>, else
C<scheme://host> plus C<prefix> from the request. C<404> when core has no
manifest builder, C<400> when no base URL can be derived, C<500> when the
manifest cannot be built. Used by the native server and
L<Langertha::Knarr::PSGI>.

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

# Optional shared secret. When set, every incoming request must present it
# either as 'Authorization: Bearer <key>' or 'x-api-key: <key>'. The agent
# card and well-known discovery routes are exempt because they need to be
# anonymously fetchable.
has router => (
  is => 'ro',
  isa => 'Maybe[Object]',
  default => sub { undef },
);

has raw_passthrough => (
  is => 'ro',
  isa => 'Maybe[Object]',
  default => sub { undef },
);

has tracing => (
  is => 'ro',
  isa => 'Maybe[Object]',
  default => sub { undef },
);

has auth_token => (
  is => 'ro',
  isa => 'Maybe[Str]',
  default => sub { undef },
);

has public_url => (
  is => 'ro',
  isa => 'Maybe[Str]',
  default => sub { undef },
);

# What GET /api/version answers (k27): the Ollama version the Ollama
# endpoints are compatible with, not Knarr's own. Current Ollama release
# (k28); it must stay >= 0.6.4 (Copilot BYOK floor) and digits-and-dots only
# (Open WebUI int()s each part).
has ollama_compat_version => (
  is => 'ro',
  isa => 'Str',
  default => '0.34.4',
  trigger => sub { _check_ollama_compat_version( $_[1] ) },
);

sub _check_ollama_compat_version {
  my ($version) = @_;
  Carp::croak( "ollama_compat_version '$version' must be three dot-separated"
    . " numbers like 0.34.4 (Ollama clients parse each part as an integer)" )
    unless $version =~ /\A\d+\.\d+\.\d+\z/;
  return $version;
}

has _manifest => (
  is => 'ro',
  lazy => 1,
  default => sub { Langertha::Knarr::Manifest->new( knarr => $_[0] ) },
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

has _servers => (
  is => 'rw',
  default => sub { [] },
);

sub _build_protocol_objects {
  my ($self) = @_;
  my @objs;
  for my $name ( @{ $self->protocols } ) {
    my $class = $name =~ /::/ ? $name : "Langertha::Knarr::Protocol::$name";
    use_module($class);
    push @objs, $class->new;
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
  # Knarr's own route, not a protocol's (k14).
  push @routes, { method => 'GET', path => '/.well-known/langertha.json',
    action => 'manifest', protocol => undef };
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
  my @servers;
  for my $a ( $self->_listen_addrs ) {
    my $server = Net::Async::HTTP::Server->new(
      on_request => sub {
        my ($srv, $req) = @_;
        $self->_dispatch($req);
      },
    );
    $self->loop->add($server);
    $server->listen(
      addr => {
        family   => 'inet',
        socktype => 'stream',
        port     => $a->{port},
        ip       => $a->{host},
      },
    )->get;
    push @servers, $server;
  }
  $self->_servers(\@servers);
  $self->_server( $servers[0] );
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

sub _check_auth {
  my ($self, $req, $action) = @_;
  return 1 unless defined $self->auth_token && length $self->auth_token;
  # Discovery endpoints stay anonymous so clients can introspect.
  return 1 if $action eq 'a2a_card';
  my $expected = $self->auth_token;
  my $auth = scalar( $req->header('Authorization') ) // '';
  if ( $auth =~ /^Bearer\s+(.+)$/i && $1 eq $expected ) {
    return 1;
  }
  my $api_key = scalar( $req->header('x-api-key') ) // '';
  return 1 if $api_key eq $expected && length $api_key;
  return 0;
}

# The one 401 answer, shared by the native server and the PSGI adapter (k25).
sub _unauthorized {
  my ($self) = @_;
  return ( 401, 'application/json',
    $self->_json->encode({ error => { message => 'unauthorized' } }) );
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
  unless ( $self->_check_auth( $req, $action ) ) {
    return $self->_send_simple( $req, $self->_unauthorized );
  }
  my $proto  = $route->{protocol};
  my $simple = $self->_simple_action($action);
  my $code = $simple ? undef : $self->can("_action_$action");
  unless ( $simple || $code ) {
    return $self->_send_simple( $req, 500, 'application/json',
      $self->_json->encode({ error => { message => "unknown action $action" } }) );
  }
  try {
    if ( $simple ) {
      my ($status, $headers, $body) = $self->$simple( $proto, $req->body );
      $self->_send_simple( $req, $status, $headers->{'Content-Type'} // 'application/json', $body );
    }
    else {
      $self->$code( $proto, $req );
    }
  } catch {
    my $err = $_;
    $log->errorf("Request error (%s): %s", $action, $err);
    $self->_send_simple( $req, 500, 'application/json',
      $self->_json->encode({ error => { message => "$err" } }) );
  };
}

sub _action_chat {
  my ($self, $proto, $req) = @_;
  my $body = $req->body;
  my $sb_req = $proto->parse_chat_request( $req, \$body );

  # Raw passthrough: pipe bytes 1:1 to upstream, skip handler chain
  if ( $self->_is_raw_passthrough($sb_req) ) {
    return $self->_handle_raw_passthrough( $proto, $req, $sb_req );
  }

  my $session = $self->session( $sb_req->session_id );
  my $handler = $self->handler;

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
      $log->errorf("Chat response error: %s", $err);
      $self->_send_simple( $req, 500, 'application/json',
        $self->_json->encode({ error => { message => "$err" } }) );
    };
  });
  $f->on_fail( sub {
    my ($err) = @_;
    $log->errorf("Chat handler error: %s", $err);
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
          # The backend's terminal reason and its complete tool calls are
          # known only now; the protocol maps the reason into its own
          # vocabulary (k18) and frames the calls (k19).
          my $finish_reason = $stream->can('finish_reason') ? $stream->finish_reason : undef;
          my $tool_calls    = $stream->can('tool_calls')    ? $stream->tool_calls    : [];
          $write->( $proto->format_stream_close( $sb_req, $finish_reason, $tool_calls ) );
          $write->( $proto->format_stream_done( $sb_req, $finish_reason, $tool_calls ) );
          $req->write_chunk_eof;
          undef $pump;
        }
      })->on_fail( sub {
        my ($err) = @_;
        $log->errorf("Stream chunk error: %s", $err);
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
    $log->errorf("Stream handler error: %s", $err);
    $write->( $proto->format_stream_chunk( "[error: $err]", $sb_req ) );
    $req->write_chunk_eof;
  });
  $f->retain;
}

sub _handle_raw_passthrough {
  my ($self, $proto, $req, $sb_req) = @_;
  my ($http_req, $trace) = $self->_raw_passthrough_request(
    $sb_req, [ $req->headers ], $req->body );
  my $pt = $self->raw_passthrough;
  my $model = $sb_req->model // 'unknown';

  if ($sb_req->stream) {
    my $f = $pt->_http->do_request(
      request   => $http_req,
      on_header => sub {
        my ($response) = @_;
        my $header = HTTP::Response->new($response->code);
        $header->protocol('HTTP/1.1');
        $header->header('Content-Type'  => scalar $response->header('Content-Type'));
        $header->header('Cache-Control' => 'no-cache');
        $req->respond_chunk_header($header);

        return sub {
          my ($data) = @_;
          if (!defined $data) {
            $req->write_chunk_eof unless $req->is_closed;
            $self->tracing->end_trace($trace, output => '[stream]') if $trace;
            return;
          }
          $req->write_chunk($data) unless $req->is_closed;
        };
      },
    );
    $f->on_fail(sub {
      my ($err) = @_;
      $log->errorf("Passthrough stream error [%s]: %s", $model, $err);
      $self->tracing->end_trace($trace, error => "$err") if $trace;
      $req->write_chunk_eof unless $req->is_closed;
    });
    $f->retain;
  } else {
    my $f = $pt->_http->do_request(request => $http_req);
    $f->on_done(sub {
      $self->_send_simple( $req,
        $self->_raw_passthrough_answer( $sb_req, $trace, $_[0] ) );
    });
    $f->on_fail(sub {
      $self->_send_simple( $req,
        $self->_raw_passthrough_failed( $sb_req, $trace, $_[0] ) );
    });
    $f->retain;
  }
}

# Raw passthrough is decided and prepared here for both transports, the
# native server and Langertha::Knarr::PSGI (k26), so they cannot drift:
# which requests bypass the handler chain, which client headers reach the
# upstream, what the upstream request and its trace look like, and how an
# answer or a failure is returned. Only the byte pumping differs -- the
# native server streams chunks as they arrive, PSGI buffers.
sub _is_raw_passthrough {
  my ($self, $sb_req) = @_;
  return $self->raw_passthrough && $self->router
    && $self->router->is_passthrough_model( $sb_req->model ) ? 1 : 0;
}

# $headers: the client's request headers as [ name, value ] pairs.
sub _raw_passthrough_request {
  my ($self, $sb_req, $headers, $body) = @_;
  my $model = $sb_req->model // 'unknown';
  my $protocol = $sb_req->protocol;

  # Build upstream URL from passthrough config
  my $url = $self->raw_passthrough->_upstream_url($protocol);
  my $http_req = HTTP::Request->new(POST => $url);

  # Forward all client headers except hop-by-hop / connection-specific
  my %skip = map { lc($_) => 1 } qw( host content-length connection transfer-encoding );
  for my $pair (@$headers) {
    my ($name, $value) = @$pair;
    next if $skip{lc($name)};
    $http_req->header($name => $value);
  }
  $http_req->content($body);

  $log->infof("Passthrough %s [%s] -> %s", $model, $protocol, $url);

  # Lightweight tracing for passthrough requests
  my $trace = $self->tracing ? $self->tracing->start_trace(
    model    => $model,
    engine   => 'passthrough',
    format   => $protocol,
    messages => $sb_req->messages,
  ) : undef;

  return ( $http_req, $trace );
}

# The upstream's answer as ( status, content type, body bytes ). A buffered
# stream (PSGI) is traced as a stream, like the native one.
sub _raw_passthrough_answer {
  my ($self, $sb_req, $trace, $resp) = @_;
  $self->tracing->end_trace( $trace,
    output => $sb_req->stream ? '[stream]' : '[passthrough]' ) if $trace;
  return ( $resp->code,
    scalar $resp->header('Content-Type') // 'application/json',
    $resp->decoded_content( charset => 'none' ) // '' );
}

sub _raw_passthrough_failed {
  my ($self, $sb_req, $trace, $err) = @_;
  $log->errorf("Passthrough error [%s]: %s", $sb_req->model // 'unknown', $err);
  $self->tracing->end_trace($trace, error => "$err") if $trace;
  return ( 502, 'application/json',
    $self->_json->encode({ error => { message => "passthrough failed: $err" } }) );
}

sub _action_acp_agents { goto &_action_models }
sub _action_a2a_card {
  my ($self, $proto, $req) = @_;
  my ($status, $headers, $body) = $proto->format_agent_card;
  $self->_send_simple( $req, $status, $headers->{'Content-Type'} // 'application/json', $body );
}

# Actions answered with one buffered response from the request body alone.
# The native server and the PSGI adapter both dispatch through this table,
# so the two cannot drift: action => method( $proto, $body_bytes ) returning
# ( status, \%headers, body ).
my %SIMPLE_ACTIONS = (
  version => '_simple_version',
  show    => '_simple_show',
);

sub _simple_action {
  my ($self, $action) = @_;
  return $SIMPLE_ACTIONS{$action};
}

sub _simple_version {
  my ($self, $proto) = @_;
  return $proto->format_version_response( $self->ollama_compat_version );
}

# POST /api/show (k29). VS Code Copilot calls it for every model and reads
# tools/vision from capabilities; Continue reads it too. Only a model Knarr
# lists (the /api/tags surface) is shown, anything else gets Ollama's 404.
# capabilities never carry "thinking": Knarr drops think on the Ollama wire.
sub _simple_show {
  my ($self, $proto, $body) = @_;
  my $data = eval { $self->_json->decode( defined $body && length $body ? $body : '{}' ) };
  $data = {} unless ref $data eq 'HASH';
  my $model = $data->{model};
  $model = $data->{name} unless defined $model && length $model;   # Ollama's legacy field
  return $proto->format_error_response( 400, 'model is required' )
    unless defined $model && !ref $model && length $model;

  my $router = $self->router;
  my $listed = $router ? $router->list_models : $self->handler->list_models;
  my ($known) = grep { $_ eq $model }
    map { ref $_ eq 'HASH' ? $_->{id} // '' : "$_" } @{ $listed || [] };
  return $proto->format_error_response( 404, "model '$model' not found" )
    unless defined $known;

  # The engine the router sends this model to, when it can build one; a
  # model it cannot build (key variable unset) or a custom handler without
  # a router leaves the capabilities at what the Ollama endpoint forwards.
  my $engine = $router
    ? eval { ( $router->resolve( $model, skip_default => 1 ) )[0] } : undef;
  my $caps = blessed($engine) && $engine->can('supports') ? $engine : undef;

  my @capabilities = ('completion');
  push @capabilities, 'tools'
    if !$caps || $caps->supports('tools_native') || $caps->supports('tools_hermes');
  # "vision" from core's model-scoped image_input (core k266, ADR 0019),
  # evaluated for the upstream model: the router builds one engine per model,
  # so its chat_model is the model this name is sent to. A core without the
  # flag (0.503) cannot tell, so no claim; nor without a routed engine.
  push @capabilities, 'vision'
    if $caps && _image_input_known() && eval { $caps->supports('image_input') };
  my $context_length = blessed($engine) && $engine->can('get_context_size')
    ? eval { $engine->get_context_size } : undef;

  return $proto->format_show_response( $model, {
    capabilities => \@capabilities,
    ( defined $context_length ? ( context_length => $context_length ) : () ),
  } );
}

# True when the installed Langertha core knows the image_input capability
# (Langertha::Role::ImageInput contributes it). Checked once per process.
my $IMAGE_INPUT_KNOWN;
sub _image_input_known {
  $IMAGE_INPUT_KNOWN //= eval { require Langertha::Role::ImageInput; 1 } ? 1 : 0;
  return $IMAGE_INPUT_KNOWN;
}

sub _action_manifest {
  my ($self, $proto, $req) = @_;
  my $proto_header = lc( scalar( $req->header('X-Forwarded-Proto') ) // '' );
  my ($status, $body) = $self->manifest_response(
    scheme => ( $proto_header =~ /\A(https?)\z/ ? $1 : 'http' ),
    host   => scalar $req->header('Host'),
  );
  $self->_send_simple( $req, $status, 'application/json', $body );
}

sub manifest_response {
  my ($self, %request) = @_;
  my $error = sub {
    my ($status, $message) = @_;
    return ( $status, $self->_json->encode({ error => { message => $message } }) );
  };
  return $error->( 404, 'provider manifest not available: the installed Langertha'
    . ' has no Langertha::Manifest::Builder' )
    unless Langertha::Knarr::Manifest->available;

  my $base_url = $self->public_url;
  unless ( defined $base_url && length $base_url ) {
    my $host = $request{host} // '';
    # A hostname or bracketed IPv6 address, optional port; nothing else can
    # reach the published URLs.
    return $error->( 400, 'cannot derive the public URL: no valid Host header'
      . ' (set public_url)' )
      unless $host =~ /\A(?:[A-Za-z0-9](?:[A-Za-z0-9.\-]*[A-Za-z0-9])?|\[[0-9A-Fa-f:.]+\])(?::[0-9]{1,5})?\z/;
    $base_url = ( $request{scheme} // 'http' ) . '://' . $host . ( $request{prefix} // '' );
  }

  my $manifest = eval { $self->_manifest->build($base_url) };
  unless ( $manifest ) {
    my $err = $@ || 'unknown error';
    $err =~ s/ at \S+ line \d+\.?\n?\z//;
    $log->errorf("Manifest error: %s", $err);
    return $error->( 500, "provider manifest failed: $err" );
  }
  return ( 200, $manifest->to_json );
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
