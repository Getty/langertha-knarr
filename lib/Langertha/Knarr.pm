package Langertha::Knarr;
# ABSTRACT: Universal LLM hub — proxy, server, and translator across OpenAI/Anthropic/Ollama/A2A/ACP/AG-UI
our $VERSION = '1.102';
use Moose;
use Future;
use Future::AsyncAwait;
use IO::Async::Loop;
use Net::Async::HTTP;
use Net::Async::HTTP::Server;
use HTTP::Response;
use JSON::MaybeXS;
use Data::UUID;
use Module::Runtime qw( use_module );
use Scalar::Util qw( blessed );
use Try::Tiny;
use Carp ();
use POSIX ();
use Socket ();
use Log::Any qw( $log );
use Langertha::Knarr::Session;
use Langertha::Knarr::Manifest;
use Langertha::Knarr::Role::UpstreamHTTP ();

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
        router  => $router,
        loop    => $loop,
        listen  => $config->listen,
    );
    $knarr->run;   # blocks; OpenWebUI etc. can now connect

C<knarr start> (see L<knarr>) builds exactly this from a config file, plus
the raw passthrough, the tracing and request-log decorators, the proxy key
and the other settings of L<Langertha::Knarr::Config>.

=head1 DESCRIPTION

Langertha::Knarr is a universal LLM hub that exposes any backend — a
L<Langertha::Raider>, a raw L<Langertha::Engine>, a remote A2A or ACP
agent, or any custom L<Langertha::Knarr::Handler> — over the standard
LLM HTTP wire protocols spoken by OpenWebUI, the OpenAI / Anthropic /
Ollama SDKs, and the agent ecosystems around A2A, ACP, and AG-UI.

By default a single running Knarr answers all of these simultaneously on
every listening port, driven by the same handler implementation:

=over

=item * OpenAI: C<POST /v1/chat/completions>, C<GET /v1/models>

=item * Anthropic: C<POST /v1/messages>

=item * Ollama: C<POST /api/chat>, C<POST /api/generate>, C<GET /api/tags>,
C<GET /api/version>, C<POST /api/show>

=item * A2A: C<GET /.well-known/agent.json> and JSON-RPC C<POST />

=item * ACP: C<GET /agents>, C<POST /runs>

=item * AG-UI: C<POST /awp>

=item * Knarr's own C<GET /.well-known/langertha.json> (see L</MANIFEST>)

=back

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

=attr workers

Number of processes that serve requests. Default C<1>: L</run> serves from
the calling process, nothing is forked. With more, L</run> binds the listen
sockets, runs auto-discovery and the capability probe once (see L</run>),
then forks that many workers that all accept on the same sockets, and stays
behind as their supervisor, serving no request itself. Must be C<1> or more;
anything else croaks at construction. C<knarr start> sets it from C<-w N>,
else from L<Langertha::Knarr::Config/workers> (C<workers:> or
C<KNARR_WORKERS>).

Every worker has its own state: L<Langertha::Knarr::Session>s (so a
L<Langertha::Knarr::Handler::Raider> conversation is only continued when
its next request reaches the same worker -- nothing routes it there), the
engine cache, and its own Langfuse batches, flushed by that worker. Request
log lines from all workers go to the same C<logging.file>, one whole line
per write. L<Langertha::Knarr::PSGI> never calls L</run>; there the PSGI
server decides about processes.

=attr protocols

ArrayRef of protocol class basenames to load. Defaults to all six
shipped protocols.

=attr protocol_args

Optional HashRef of constructor arguments per protocol, keyed by the name
as it appears in L</protocols>. The A2A agent card name and description:

    protocol_args => { A2A => {
      agent_name        => 'Support Agent',
      agent_description => 'Answers support questions',
    } },

C<knarr start> passes L<Langertha::Knarr::Config/protocol_args>.

=attr auth_token

Optional shared secret. When set, every incoming request must present
it as C<Authorization: Bearer> or C<x-api-key>. Discovery routes
(C</.well-known/agent.json>) stay anonymous.

A header sent twice counts as one value of comma-separated elements (that
is how a PSGI server and C<< HTTP::Headers->header >> merge it), and the key
may be any one of them.

The key never leaves Knarr: it is taken out of a request to a passthrough
upstream (the L</raw_passthrough> and a
L<Langertha::Knarr::Handler::Passthrough> in the handler chain alike).
From C<Authorization> and C<x-api-key>, every element that is the key --
bare or as C<Bearer> I<key>, in either header -- is removed, the others are
kept, and a header left with nothing is dropped; a header without the key
goes through unchanged. Every other header is forwarded, so a passthrough
client sends its own provider key in the other header -- the proxy key in
C<x-api-key> and the OpenAI key as C<Authorization: Bearer>, or the proxy
key as C<Authorization: Bearer> and the Anthropic key in C<x-api-key>.

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

=attr raw_passthrough

Optional L<Langertha::Knarr::Handler::Passthrough>. Together with a
L</router>, a chat request for a model the router does not configure -- or
knows only from auto-discovery on that same upstream
(L<Langertha::Knarr::Router/discovered_url>,
L<Langertha::Knarr::Handler::Passthrough/is_upstream_for>), when the
request carries the client's own provider key -- is
piped byte for byte to the upstream for the client's protocol (an Ollama
C</api/generate> to the upstream's C</api/generate>, any other Ollama chat
to C</api/chat>), bypassing the handler chain -- but only when that
protocol has an upstream
(L<Langertha::Knarr::Handler::Passthrough/serves_protocol>). A request in
any other protocol (Ollama without an C<ollama> upstream, A2A, ACP, AG-UI)
goes through the handler, where L<Langertha::Knarr::Handler::Router> hands
it to the default engine, or answers C<404> in the protocol's error shape
when there is none.

Every client header line goes to the upstream as a line of its own, in
its order -- a header sent twice arrives twice -- with the proxy key taken
out of each line (see
L</auth_token>) and without C<Host>, C<Content-Length>, C<Connection> and
C<Transfer-Encoding>. The upstream's response headers come back the same
way, repeats included (C<Set-Cookie> twice), except the connection-level
ones and the framing Knarr sets itself (C<Transfer-Encoding>,
C<Content-Length>). A body compressed with an encoding Knarr's HTTP client
decodes (C<gzip>, C<deflate>) goes back decoded, without its
C<Content-Encoding>, and so does every buffered answer; a stream in any
other encoding is piped as it comes, with it. A stream gets
C<Cache-Control: no-cache> when the upstream sent none.

The provider key is looked for once the proxy key is taken out (see
L</auth_token>): C<Authorization> for OpenAI, C<x-api-key> or
C<Authorization> for Anthropic; Ollama needs none. A discovered model
requested without one goes through the handler instead, to the engine
that listed it, with that engine's key -- the upstream would only answer
C<401>. A model nobody configured or discovered passes through either way.

=attr router

Optional L<Langertha::Knarr::Router>, usually the one the
L<Langertha::Knarr::Handler::Router> handler wraps. Knarr itself uses it
to decide which requests go to the L</raw_passthrough> (models it does not
configure, and models it only discovered on that upstream when the client
sends its own key), to answer
C<POST /api/show> from the routed engine's
capabilities (without a router it falls back to the handler's
C<list_models> and claims no C<vision>), and to start the capability probe
in L</start>.

=attr tracing

Optional L<Langertha::Knarr::Tracing>. Only the L</raw_passthrough> uses
it: a request that bypasses the handler chain gets a lightweight Langfuse
trace from here. Requests through the handler chain are traced by the
L<Langertha::Knarr::Handler::Tracing> decorator instead. Raw passthrough
requests are not written to the request log.

=method start

    $knarr->start;

Binds all listen sockets and registers the dispatcher. Returns
C<$self>. Does not enter the event loop. Each socket queues up to
C<SOMAXCONN> pending connections (C<128> where L<Socket> does not know it;
the kernel caps it at its own limit, C<net.core.somaxconn> on Linux).

Once the sockets listen, it starts
L<Langertha::Knarr::Router/probe_capabilities_f> on the L</loop> when a
L</router> that has it is set (see
L<Langertha::Knarr::Config/probe_capabilities>). The probe runs in the
background; until it has finished, C<POST /api/show> and the manifest answer
from Langertha's static capability tables. L<Langertha::Knarr::PSGI> does not
call L</start>, so under PSGI the probe runs only when you call it.

=method run

    $knarr->run;   # blocks

With one L</workers> (the default): calls L</start> if needed, then enters
the L</loop> and blocks.

With more, it prefork-serves and returns only once all workers are gone:

=over

=item 1. The listen sockets are bound here (L</start> may have done it),
and this process stops accepting on them.

=item 2. Auto-discovery and the capability probe run here, once, to the
end, before any worker exists -- each worker inherits the discovered models
and the learned capabilities instead of asking the upstreams again. Until
the probe is done (each probe gives up after
L<Langertha::Knarr::Config/probe_timeout>), connections wait in the
sockets' backlog. Upstream connections the probe kept open are closed, so
no two workers share one.

=item 3. L</workers> processes are forked; each rebuilds the loop's kernel
state (L<IO::Async::Loop/post_fork>) and accepts on the inherited sockets.

=item 4. This process supervises them: a worker that exits is replaced --
one that dies within five seconds of its start after a pause of 1, 2, 4
... up to 30 seconds, so a worker that cannot start does not spin.
C<SIGTERM> or C<SIGINT> is passed on to the workers as C<SIGTERM>; once
they have exited, L</run> returns.

=back

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

# Serving processes (k51): 1 is this one, more are forked by run().
has workers => (
  is => 'ro',
  isa => 'Int',
  default => 1,
  trigger => sub {
    Carp::croak( "workers '$_[1]' must be 1 or more" ) unless $_[1] >= 1;
  },
);

has protocols => (
  is => 'ro',
  isa => 'ArrayRef[Str]',
  default => sub { [qw( OpenAI Anthropic Ollama A2A ACP AGUI )] },
);

has protocol_args => (
  is => 'ro',
  isa => 'HashRef[HashRef]',
  default => sub { {} },
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

# The startup capability probe (k37), held until it is ready.
has _capability_probe => (
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
    push @objs, $class->new( %{ $self->protocol_args->{$name} // {} } );
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
  $self->_listen;
  $self->_start_capability_probe;
  return $self;
}

sub _listen {
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
      queuesize => $self->_listen_backlog,
    )->get;
    push @servers, $server;
  }
  $self->_servers(\@servers);
  $self->_server( $servers[0] );
  return;
}

# Connections the kernel queues until a process accepts them (k51): the
# system maximum, not IO::Async's default of 3 -- with workers, connections
# wait here while the probe runs before the fork. The kernel caps it at
# net.core.somaxconn.
sub _listen_backlog {
  my ($self) = @_;
  my $max = eval { Socket::SOMAXCONN() };
  return $max && $max > 0 ? $max : 128;
}

# k37: once the server listens, ask each routed engine for its model's
# capabilities (Router->probe_capabilities_f). Deferred to the running loop
# so start() does not block on discovery; the Future is held here until it
# is ready. It never fails: probe errors are logged by the router.
sub _start_capability_probe {
  my ($self) = @_;
  my $router = $self->router;
  return unless $router && $router->can('probe_capabilities_f');
  return if $self->_capability_probe;
  my $loop = $self->loop;
  $self->_capability_probe( $loop->delay_future( after => 0 )->then(sub {
    $router->probe_capabilities_f( loop => $loop );
  })->else(sub {
    $log->warnf( "Capability probe failed: %s", $_[0] );
    Future->done(0);
  }) );
  return;
}

sub run {
  my ($self) = @_;
  return $self->_run_workers if $self->workers > 1;
  $self->start unless $self->_server;
  $self->loop->run;
}

# k51: prefork. This process binds, discovers and probes once, forks the
# workers -- which inherit all of it -- and supervises them until SIGTERM or
# SIGINT. It serves no request itself.
sub _run_workers {
  my ($self) = @_;
  $self->_prepare_workers;

  my %workers;   # pid => start time
  my $stopping = 0;
  my $stop = sub {
    my ($signal) = @_;
    $log->infof( "SIG%s: stopping %d worker(s)", $signal, scalar keys %workers )
      unless $stopping;
    $stopping = 1;
    kill TERM => keys %workers;
  };
  local $SIG{TERM} = $stop;
  local $SIG{INT}  = $stop;

  my $spawn = sub {
    my $pid = $self->_fork_worker;
    $workers{$pid} = time;
    kill TERM => $pid if $stopping;   # the signal came in during the fork
    $log->infof( "Worker %d started", $pid );
  };

  try {
    $spawn->() for 1 .. $self->workers;
    my $delay = 0;
    while ( %workers ) {
      my $pid = waitpid( -1, 0 );
      last if $pid < 0;
      my $started = delete $workers{$pid} // next;
      next if $stopping;
      my $status = $?;
      # A worker that dies within 5s of its start is crashing: pause 1, 2,
      # 4 ... 30 seconds before the next one, so it cannot spin.
      $delay = time - $started < 5 ? ( $delay ? $delay * 2 : 1 ) : 0;
      $delay = 30 if $delay > 30;
      $log->warnf( "Worker %d %s, starting a new one%s", $pid,
        $self->_exit_text($status), $delay ? " in ${delay}s" : '' );
      sleep $delay if $delay;   # a signal ends it early
      $spawn->() unless $stopping;
    }
  } catch {
    my $err = $_;
    kill TERM => keys %workers;
    waitpid( $_, 0 ) for keys %workers;
    die $err;
  };
  return;
}

sub _prepare_workers {
  my ($self) = @_;
  $self->_listen unless $self->_server;
  my $loop = $self->loop;
  # The sockets stay bound here for the workers, but this process accepts
  # nothing on them.
  $loop->remove($_) for grep { $_->loop } @{ $self->_servers };
  if ( my $router = $self->router ) {
    $router->list_models if $router->can('list_models');   # auto-discovery
    $self->_start_capability_probe;
    $self->_capability_probe->get if $self->_capability_probe;
  }
  $self->_drop_upstream_connections;
  return;
}

# Keep-alive upstream connections (the probe's) must not reach the workers:
# two processes on one socket read each other's responses. A
# Net::Async::HTTP closes its pooled connections when it leaves the loop and
# connects anew once it is back.
sub _drop_upstream_connections {
  my ($self) = @_;
  my $loop = $self->loop;
  for my $http ( grep { $_->isa('Net::Async::HTTP') } $loop->notifiers ) {
    if ( my $parent = $http->parent ) {
      $parent->remove_child($http);
      $parent->add_child($http);
    }
    else {
      $loop->remove($http);
      $loop->add($http);
    }
  }
  return;
}

# Returns the worker's pid in the supervisor; the worker itself never
# returns. It drops the supervisor's signal handlers, rebuilds the loop's
# kernel state (epoll/kqueue fd, signal pipe) and accepts on the inherited
# sockets. POSIX::_exit: the supervisor's END blocks and destructors are not
# the worker's to run.
sub _fork_worker {
  my ($self) = @_;
  my $pid = fork;
  Carp::croak( "Cannot fork a worker: $!" ) unless defined $pid;
  return $pid if $pid;
  my $ok = eval {
    $SIG{$_} = 'DEFAULT' for qw( TERM INT );
    my $loop = $self->loop;
    $loop->post_fork;
    $loop->add($_) for @{ $self->_servers };
    $loop->run;
    1;
  };
  $log->errorf( "Worker %d failed: %s", $$, $@ ) unless $ok;
  POSIX::_exit( $ok ? 0 : 1 );
}

sub _exit_text {
  my ($self, $status) = @_;
  return 'was killed by signal ' . ( $status & 127 ) if $status & 127;
  return 'exited with status ' . ( $status >> 8 );
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
  # One element of the value is enough: a header sent twice arrives as one
  # value joined with ', ' (k53).
  for my $name ( 'Authorization', 'x-api-key' ) {
    my $value = scalar $req->header($name);
    next unless defined $value;
    my $bearer = lc $name eq 'authorization';
    for my $element ( split /,/, $value ) {
      $element =~ s/\A\s+|\s+\z//g;
      next if $bearer && $element !~ s/\ABearer\s+//i;
      return 1 if $element eq $self->auth_token;
    }
  }
  return 0;
}

# Headers Knarr reads its own key (auth_token) from.
my %PROXY_KEY_HEADER = ( 'authorization' => 1, 'x-api-key' => 1 );

# A client header's value as it may leave Knarr (k44, k53). In Authorization
# and x-api-key, every comma-separated element that is Knarr's key -- bare
# or as 'Bearer <key>', in either header -- is removed: a header sent twice
# arrives as one value joined with ', ' (a PSGI server's HTTP_*, the
# parsers' scalar ->header). Returns the value unchanged, byte for byte, when
# no element carries the key; the remaining elements joined with ', ' when
# some do; nothing when only the key was there, so the header is dropped.
# Every path that forwards client headers goes through here: the raw
# passthrough and the forward_headers of the protocol parsers.
sub _without_proxy_key {
  my ($self, $name, $value) = @_;
  my $key = $self->auth_token;
  return $value unless defined $key && length $key && defined $value
    && $PROXY_KEY_HEADER{ lc $name };
  my ( @kept, $dropped );
  for my $element ( split /,/, $value ) {
    ( my $token = $element ) =~ s/\A\s+|\s+\z//g;
    next unless length $token;
    ( my $bare = $token ) =~ s/\ABearer\s+//i;
    if ( $bare eq $key ) { $dropped = 1; next }
    push @kept, $token;
  }
  return $value unless $dropped;
  return @kept ? join( ', ', @kept ) : ();
}

# The protocol's parse, with Knarr's key taken out of the headers a
# passthrough handler in the chain forwards (forward_headers, k44). Shared
# by the native server and the PSGI adapter.
sub _parse_chat_request {
  my ($self, $proto, $req, $body_ref) = @_;
  my $sb_req = $proto->parse_chat_request( $req, $body_ref );
  my $fwd = $sb_req->extra && $sb_req->extra->{forward_headers};
  if ( ref $fwd eq 'HASH' ) {
    for my $name ( keys %$fwd ) {
      my ($value) = $self->_without_proxy_key( $name, $fwd->{$name} );
      if ( defined $value ) { $fwd->{$name} = $value } else { delete $fwd->{$name} }
    }
  }
  return $sb_req;
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
  my $sb_req = $self->_parse_chat_request( $proto, $req, \$body );

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
    my ($err, $category) = @_;
    $log->errorf("Chat handler error: %s", $err);
    if ( my @answer = $self->_handler_failure_answer( $proto, $err, $category ) ) {
      return $self->_send_simple( $req, @answer );
    }
    $self->_send_simple( $req, 500, 'application/json',
      $self->_json->encode({ error => { message => "$err" } }) );
  });
  $f->retain;
}

sub _handle_stream {
  my ($self, $proto, $req, $sb_req, $session, $handler) = @_;

  # A handler that refuses the request outright (no route for the model,
  # k41) has failed before any stream exists: answer it like a
  # non-streaming request, before the stream's 200 goes out.
  my $f = $handler->handle_stream_f( $session, $sb_req );
  if ( $f->is_failed ) {
    if ( my @answer = $self->_handler_failure_answer( $proto, $f->failure ) ) {
      return $self->_send_simple( $req, @answer );
    }
  }

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
        my ($err, $category) = @_;
        $log->errorf("Stream chunk error: %s", $err);
        undef $pump;
        return if $self->_stream_failure_frame( $proto, $req, $err, $category );
        $write->( $proto->format_stream_chunk( "[error: $err]", $sb_req ) );
        $write->( $proto->format_stream_close($sb_req) );
        $req->write_chunk_eof;
      })->retain;
      # Held until ready: a decorator's chained read (Tracing, RequestLog)
      # is referenced by nothing else while the upstream is silent (k36).
    };
    $pump->();
  });
  $f->on_fail( sub {
    my ($err, $category) = @_;
    $log->errorf("Stream handler error: %s", $err);
    return if $self->_stream_failure_frame( $proto, $req, $err, $category );
    $write->( $proto->format_stream_chunk( "[error: $err]", $sb_req ) );
    $req->write_chunk_eof;
  });
  $f->retain;
}

# The status a handler failure answers with, from its category (the second
# failure value). A Net::Async::HTTP timeout category (core's k278 engine
# timeouts, the UpstreamHTTP role's) is an upstream that did not answer in
# time: 504, as on the raw passthrough (k35, k36). 'model_not_found' is
# Handler::Router finding nothing to serve the model -- not configured, no
# passthrough for the protocol, no default engine: 404 (k41). Undef for any
# other failure, and for a core that sets no category.
sub _handler_failure_status {
  my ($self, $category) = @_;
  return 504 if Langertha::Knarr::Role::UpstreamHTTP->is_upstream_timeout($category);
  return 404 if defined $category && $category eq 'model_not_found';
  return;
}

# That status in the client protocol's error shape. Empty for a failure
# without one.
sub _handler_failure_answer {
  my ($self, $proto, $err, $category) = @_;
  my $code = $self->_handler_failure_status($category) or return;
  my ($status, $headers, $body) = $proto->format_error_response( $code, _error_text($err) );
  return ( $status, $headers->{'Content-Type'} // 'application/json', $body );
}

# The same for a stream whose headers are out: the protocol's error frame,
# then the end of the stream. False (nothing written) when the failure has
# no status or the protocol has no error frame, so the caller answers as
# before.
sub _stream_failure_frame {
  my ($self, $proto, $req, $err, $category) = @_;
  my $code = $self->_handler_failure_status($category) or return 0;
  my $frame = $proto->format_stream_error( $code, _error_text($err) );
  return 0 unless length $frame;
  return 1 if $req->is_closed;
  $req->write_chunk($frame);
  $req->write_chunk_eof;
  return 1;
}

sub _handle_raw_passthrough {
  my ($self, $proto, $req, $sb_req) = @_;
  my ($http_req, $trace) = $self->_raw_passthrough_request(
    $sb_req, [ $req->headers ], $req->body, $req->path );
  my $pt = $self->raw_passthrough;
  my $model = $sb_req->model // 'unknown';

  if ($sb_req->stream) {
    # The upstream may go silent before its headers (answered like a
    # non-streaming failure: 504 or 502 in the protocol's shape) or in the
    # middle of the stream (the headers are out: the protocol's error frame,
    # then the end of the stream). stall_timeout covers both (k35).
    my $headers_sent = 0;
    my $tail = '';
    my $f = $pt->_upstream_request_f(
      request   => $http_req,
      on_header => sub {
        my ($response) = @_;
        # The upstream's headers go back with it (k56).
        my $header = HTTP::Response->new($response->code);
        $header->protocol('HTTP/1.1');
        $header->header('Content-Type'  => scalar $response->header('Content-Type'));
        $header->push_header(@$_) for @{ $self->_raw_passthrough_response_headers($response) };
        $header->header('Cache-Control' => 'no-cache') unless defined $header->header('Cache-Control');
        $req->respond_chunk_header($header);
        $headers_sent = 1;

        return sub {
          my ($data) = @_;
          if (!defined $data) {
            $req->write_chunk_eof unless $req->is_closed;
            $self->tracing->end_trace($trace, output => '[stream]') if $trace;
            return;
          }
          return unless length $data;
          $tail = substr( $tail . $data, -2 );
          $req->write_chunk($data) unless $req->is_closed;
        };
      },
    );
    $f->on_fail(sub {
      my ($err, $category) = @_;
      unless ($headers_sent) {
        return $self->_send_simple( $req,
          $self->_raw_passthrough_failed( $proto, $sb_req, $trace, $err, $category ) );
      }
      $log->errorf("Passthrough stream error [%s]: %s", $model, $err);
      $self->tracing->end_trace($trace, error => "$err") if $trace;
      return if $req->is_closed;
      my $frame = $proto->format_stream_error(
        $self->_raw_passthrough_status($category), _error_text($err) );
      if ( length $frame ) {
        # A frame cut off by the stall is ended first, so the error frame
        # stands on its own: a blank line for SSE, a newline for NDJSON.
        my $pad = $proto->stream_content_type =~ /ndjson/
          ? ( $tail eq '' || $tail =~ /\n\z/ ? '' : "\n" )
          : ( $tail eq '' || $tail eq "\n\n" ? '' : $tail =~ /\n\z/ ? "\n" : "\n\n" );
        $req->write_chunk( $pad . $frame );
      }
      $req->write_chunk_eof;
    });
    $f->retain;
  } else {
    my $f = $pt->_upstream_request_f(request => $http_req);
    $f->on_done(sub {
      $self->_send_simple( $req,
        $self->_raw_passthrough_answer( $sb_req, $trace, $_[0] ) );
    });
    $f->on_fail(sub {
      $self->_send_simple( $req,
        $self->_raw_passthrough_failed( $proto, $sb_req, $trace, @_[0, 1] ) );
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
  my $pt = $self->raw_passthrough;
  my $router = $self->router;
  # Only for a protocol the passthrough has an upstream for: a request in
  # any other protocol goes through the handler chain, to the default
  # engine or to a 404 in the protocol's error shape (k41).
  return 0 unless $pt && $router && $pt->serves_protocol( $sb_req->protocol );
  return 1 if $router->is_passthrough_model( $sb_req->model );
  # A model only auto-discovery knows, listed by this very upstream, goes
  # there byte for byte too; discovery then only feeds the model lists
  # (k47). One listed by another provider stays with its engine.
  my $url = $router->can('discovered_url') ? $router->discovered_url( $sb_req->model ) : undef;
  return 0 unless defined $url && $pt->can('is_upstream_for')
    && $pt->is_upstream_for( $sb_req->protocol, $url );
  # ...but only with the client's own provider key: without one the upstream
  # would answer 401, while the engine that listed the model holds Knarr's
  # key (k52).
  return $self->_carries_provider_key($sb_req);
}

# The headers a protocol's upstream takes its key from. A protocol not listed
# (Ollama) needs none.
my %PROVIDER_KEY_HEADERS = (
  openai    => [ 'authorization' ],
  anthropic => [ 'x-api-key', 'authorization' ],
);

# True when the request carries a provider key for its protocol's upstream,
# after Knarr's proxy key was taken out: the parser's forward_headers, as
# _parse_chat_request left them (k52).
sub _carries_provider_key {
  my ($self, $sb_req) = @_;
  my $names = $PROVIDER_KEY_HEADERS{ $sb_req->protocol // '' } or return 1;
  my $fwd = ( $sb_req->extra && $sb_req->extra->{forward_headers} ) || {};
  return ( grep { defined $fwd->{$_} && length $fwd->{$_} } @$names ) ? 1 : 0;
}

# $headers: the client's request headers as [ name, value ] pairs; $path:
# the path the client asked for (Ollama /api/chat or /api/generate, k46).
sub _raw_passthrough_request {
  my ($self, $sb_req, $headers, $body, $path) = @_;
  my $model = $sb_req->model // 'unknown';
  my $protocol = $sb_req->protocol;

  # Build upstream URL from passthrough config
  my $url = $self->raw_passthrough->_upstream_url( $protocol, $path );
  my $http_req = HTTP::Request->new(POST => $url);

  # Forward all client headers except hop-by-hop / connection-specific
  # ones, with Knarr's own key taken out of each line (k44, k53). Every line
  # is added, not set: a header sent twice reaches the upstream twice, in
  # its order (k56).
  my %skip = map { lc($_) => 1 } qw( host content-length connection transfer-encoding );
  for my $pair (@$headers) {
    my ($name, $value) = @$pair;
    next if $skip{lc($name)};
    ($value) = $self->_without_proxy_key( $name, $value );
    next unless defined $value;
    $http_req->push_header($name => $value);
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

# The upstream's answer as ( status, content type, body bytes, its other
# headers ). A buffered stream (PSGI) is traced as a stream, like the
# native one. The body goes back decoded, so its Content-Encoding stays
# behind.
sub _raw_passthrough_answer {
  my ($self, $sb_req, $trace, $resp) = @_;
  $self->tracing->end_trace( $trace,
    output => $sb_req->stream ? '[stream]' : '[passthrough]' ) if $trace;
  return ( $resp->code,
    scalar $resp->header('Content-Type') // 'application/json',
    $resp->decoded_content( charset => 'none' ) // '',
    $self->_raw_passthrough_response_headers( $resp, 1 ) );
}

# Upstream response headers that stay behind: connection-level ones, the
# framing Knarr sets for what it sends itself, Content-Type, which the
# callers set, and the note Net::Async::HTTP leaves on a body it decoded.
my %RESPONSE_HEADER_SKIP = map { $_ => 1 } qw(
  connection keep-alive proxy-connection te trailer upgrade
  transfer-encoding content-length content-type x-original-content-encoding );

# The upstream's response headers that go back to the client, as [ name,
# value ] pairs: every line, a repeated header (Set-Cookie) repeated in its
# order (k56). Content-Encoding goes along only while the bytes still carry
# it: Net::Async::HTTP decodes every encoding it knows (gzip, deflate)
# before Knarr sees a byte, and $buffered bytes go back decoded anyway.
sub _raw_passthrough_response_headers {
  my ($self, $resp, $buffered) = @_;
  my @pairs;
  $resp->headers->scan( sub {
    my ($name, $value) = @_;
    my $lc = lc $name;
    return if $RESPONSE_HEADER_SKIP{$lc};
    return if $lc eq 'content-encoding'
      && ( $buffered || Net::Async::HTTP->can_decode($value) );
    push @pairs, [ $name, $value ];
  });
  return \@pairs;
}

# An upstream that did not answer in time is a 504, any other failure to
# reach it a 502, in the client protocol's error shape (k35).
sub _raw_passthrough_failed {
  my ($self, $proto, $sb_req, $trace, $err, $category) = @_;
  $log->errorf("Passthrough error [%s]: %s", $sb_req->model // 'unknown', $err);
  $self->tracing->end_trace($trace, error => "$err") if $trace;
  my ($status, $headers, $body) = $proto->format_error_response(
    $self->_raw_passthrough_status($category), 'passthrough failed: ' . _error_text($err) );
  return ( $status, $headers->{'Content-Type'} // 'application/json', $body );
}

sub _raw_passthrough_status {
  my ($self, $category) = @_;
  return Langertha::Knarr::Role::UpstreamHTTP->is_upstream_timeout($category) ? 504 : 502;
}

sub _error_text {
  my ($err) = @_;
  ( my $text = "$err" ) =~ s/\s+\z//;
  return $text;
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

# $headers: optional further [ name, value ] pairs, each line added (the
# raw passthrough's upstream headers, k56).
sub _send_simple {
  my ($self, $req, $status, $ctype, $body, $headers) = @_;
  my $resp = HTTP::Response->new( $status );
  $resp->protocol('HTTP/1.1');
  $resp->push_header(@$_) for @{ $headers // [] };
  $resp->header( 'Content-Type'   => $ctype );
  $resp->header( 'Content-Length' => length($body) );
  $resp->content($body);
  $req->respond($resp);
}

__PACKAGE__->meta->make_immutable;
1;
