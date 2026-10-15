package Langertha::Knarr::Stack;
# ABSTRACT: The routing parts of a running Knarr, built from one config
our $VERSION = '1.103';
use Moose;
use Langertha::Knarr::Router;
use Langertha::Knarr::Handler::Passthrough;
use Langertha::Knarr::Handler::Router;
use Langertha::Knarr::Handler::Tracing;
use Langertha::Knarr::Handler::RequestLog;

=head1 SYNOPSIS

    use Langertha::Knarr::Stack;

    my $stack = Langertha::Knarr::Stack->new(
        config      => $config,      # Langertha::Knarr::Config
        loop        => $loop,
        tracing     => $tracing,     # enabled Langertha::Knarr::Tracing, or undef
        request_log => $request_log, # enabled Langertha::Knarr::RequestLog, or undef
    );

    my $knarr = Langertha::Knarr->new(
        handler         => $stack->handler,
        router          => $stack->router,
        raw_passthrough => $stack->raw_passthrough,
        auth_token      => $stack->auth_token,
        ...
    );

    # Same loop, tracing and request log, a new config, fresh engines:
    my $next = $stack->with_config($new_config);
    my $lf   = $stack->with_config( $new_config, tracing => $other_tracing );

=head1 DESCRIPTION

Everything of a running Knarr that its routing config decides, built the way
C<knarr start> builds it: the L<Langertha::Knarr::Router>, the
L<Langertha::Knarr::Handler::Passthrough> for the configured upstreams, the
L<Langertha::Knarr::Handler::Router> on top of both, wrapped in the
L<Langertha::Knarr::Handler::Tracing> and
L<Langertha::Knarr::Handler::RequestLog> decorators when L</tracing> and
L</request_log> are given, and the proxy key.

L<Langertha::Knarr::Admin> builds a new stack for every admin push with
L</with_config> and hands it to the running Knarr in one step. The new
stack has its own router, so its engine cache starts empty; the old stack
lives on only as long as a request that is still running holds on to it.

=attr config

Required. The L<Langertha::Knarr::Config> the stack is built from.

=attr loop

Optional L<IO::Async::Loop> for the passthrough's HTTP client.

=attr tracing

Optional, enabled L<Langertha::Knarr::Tracing>. Wraps the handler in a
L<Langertha::Knarr::Handler::Tracing>. It is a process setting: L</with_config>
keeps it.

=attr request_log

Optional, enabled L<Langertha::Knarr::RequestLog>. Wraps the handler in a
L<Langertha::Knarr::Handler::RequestLog>, outside the tracing. Kept by
L</with_config> like L</tracing>.

=attr router

The L<Langertha::Knarr::Router> over L</config>. Built on first use.

=attr raw_passthrough

The L<Langertha::Knarr::Handler::Passthrough> for
L<Langertha::Knarr::Config/passthrough>, or C<undef> when no upstream is
configured. Built on first use.

=attr handler

The handler chain: L<Langertha::Knarr::Handler::Router> (with
L</raw_passthrough> as its fallback), inside the tracing and request-log
decorators. Built on first use.

=method auth_token

The proxy key (L<Langertha::Knarr::Config/proxy_api_key>), or C<undef>
when none is set.

=method with_config

    my $next = $stack->with_config($config);
    my $next = $stack->with_config( $config, tracing => $tracing_or_undef );

A new stack for C<$config> with the same L</loop>, L</tracing> and
L</request_log>. Nothing of this stack's router, engines or passthrough is
reused. A C<tracing> argument (an enabled tracing, or C<undef> for none)
replaces the tracing: a delivered C<langfuse> section brings its own.

=method build

    $stack->build;

Builds L</router>, L</raw_passthrough> and L</handler> now, so a config
they cannot be built from fails here and not on the first request. Returns
the stack.

=cut

has config => (
  is       => 'ro',
  required => 1,
);

has loop => (
  is => 'ro',
);

has tracing => (
  is      => 'ro',
  isa     => 'Maybe[Object]',
  default => sub { undef },
);

has request_log => (
  is      => 'ro',
  isa     => 'Maybe[Object]',
  default => sub { undef },
);

has router => (
  is      => 'ro',
  lazy    => 1,
  builder => '_build_router',
);

has raw_passthrough => (
  is      => 'ro',
  lazy    => 1,
  builder => '_build_raw_passthrough',
);

has handler => (
  is      => 'ro',
  lazy    => 1,
  builder => '_build_handler',
);

# The classes the stack is made of, named once each (override points).
sub router_class              { 'Langertha::Knarr::Router' }
sub passthrough_class         { 'Langertha::Knarr::Handler::Passthrough' }
sub router_handler_class      { 'Langertha::Knarr::Handler::Router' }
sub tracing_handler_class     { 'Langertha::Knarr::Handler::Tracing' }
sub request_log_handler_class { 'Langertha::Knarr::Handler::RequestLog' }

sub _build_router {
  my ($self) = @_;
  return $self->router_class->new( config => $self->config );
}

sub _build_raw_passthrough {
  my ($self) = @_;
  my $config = $self->config;
  my $upstreams = $config->passthrough;
  return undef unless $upstreams && %$upstreams;
  return $self->passthrough_class->new(
    upstreams     => $upstreams,
    ( $self->loop ? ( loop => $self->loop ) : () ),
    timeout       => $config->upstream_timeout,
    stall_timeout => $config->upstream_stall_timeout,
  );
}

sub _build_handler {
  my ($self) = @_;
  my $passthrough = $self->raw_passthrough;
  my $handler = $self->router_handler_class->new(
    router => $self->router,
    ( $passthrough ? ( passthrough => $passthrough ) : () ),
  );
  $handler = $self->tracing_handler_class->new(
    wrapped => $handler,
    tracing => $self->tracing,
  ) if $self->tracing;
  $handler = $self->request_log_handler_class->new(
    wrapped     => $handler,
    request_log => $self->request_log,
  ) if $self->request_log;
  return $handler;
}

sub auth_token {
  my ($self) = @_;
  return $self->config->has_proxy_api_key ? $self->config->proxy_api_key : undef;
}

sub with_config {
  my ($self, $config, %over) = @_;
  return ref($self)->new(
    config      => $config,
    loop        => $self->loop,
    tracing     => ( exists $over{tracing} ? $over{tracing} : $self->tracing ),
    request_log => $self->request_log,
  );
}

sub build {
  my ($self) = @_;
  $self->$_ for qw( router raw_passthrough handler );
  return $self;
}

__PACKAGE__->meta->make_immutable;
1;
