package Langertha::Knarr::Admin;
# ABSTRACT: Admin routes that deliver, rotate and drop Knarr's routing setup at runtime, in memory only
our $VERSION = '1.103';
use Moose;
use Carp qw( croak );
use Digest::SHA qw( sha256 );
use JSON::MaybeXS;
use Log::Any qw( $log );
use POSIX ();
use Storable qw( dclone );
use Try::Tiny;
use Langertha::Knarr::Config;

=head1 SYNOPSIS

    use Langertha::Knarr;
    use Langertha::Knarr::Admin;
    use Langertha::Knarr::Stack;

    my $stack = Langertha::Knarr::Stack->new( config => $config, loop => $loop );
    my $knarr = Langertha::Knarr->new(
        loop  => $loop,
        admin => Langertha::Knarr::Admin->new(
            key      => $ENV{KNARR_ADMIN_KEY},
            stack    => $stack,
            ram_only => 1,
        ),
    );

    # From the central service:
    #   PUT    /knarr/admin/config   { "models": {...}, "default": {...}, ... }
    #   PATCH  /knarr/admin/keys     { "gpt-4o": "sk-...", "default": "sk-..." }
    #   GET    /knarr/admin/status
    #   DELETE /knarr/admin/config
    # each with  Authorization: Bearer $KNARR_ADMIN_KEY

=head1 DESCRIPTION

The admin routes let a central service hand a running Knarr its routing
setup -- the models, the default engine, the passthrough upstreams and the
keys -- as JSON, rotate the keys, and take the setup back. What arrives is
held in memory only: nothing is written to a file, a cache or a log, and a
restarted Knarr has forgotten it, so the central service delivers it again.
C<knarr start> enables the routes when L<Langertha::Knarr::Config/admin_key>
(C<KNARR_ADMIN_KEY>) is set; L<Langertha::Knarr::Config/ram_only> starts
Knarr with no setup at all.

=head2 Routes

Every route answers JSON with C<Cache-Control: no-store>, and no answer
ever contains a key.

=over

=item C<GET /knarr/admin/status>

C<200> with C<generation> (how many changes since the start, C<0> before the
first), C<applied_at> (ISO 8601, UTC) and C<applied_at_epoch> (when the
current state took effect), C<source> (C<ram> after a push; at start
C<file>, C<env> for a config not read from a file -- C<--from-env> or the
Perl API --, or C<none> under L</ram_only>), C<configured>, C<ram_only>,
C<models> (the names under C<models:>), C<default_engine> (whether there is
one) and C<passthrough> (the protocols with an upstream, without their
URLs).

=item C<PUT /knarr/admin/config>

Replaces the running setup with the JSON object in the body: the keys of
L<Langertha::Knarr::Config/runtime_keys> (C<models>, C<default>,
C<passthrough>, C<auto_discover>, C<proxy_api_key>, the upstream timeouts
and the capability probe settings), structured as in the YAML config. A key
it leaves out is unset, not kept. The process settings (C<listen>,
C<workers>, C<logging>, C<langfuse>, C<admin_key>, C<ram_only>, ...) stay
as they were at the start; a body that names one is refused. Keys arrive
literally as C<api_key>: an C<api_key_env> in a model or the default is
refused, because the start environment's secrets must not follow a pushed
C<url>. The new setup
is checked like a config file (L<Langertha::Knarr::Config/validate>) and
every model's engine, and the default engine, is built before anything
changes; any problem answers C<400> and the running setup stays exactly as
it was. On success: C<200> with the status above, under the next
generation.

=item C<PATCH /knarr/admin/keys>

Swaps API keys only: a JSON object of name to key, where a name is a model
under C<models:> or C<default> for the default engine (refused as ambiguous
when a model is called C<default> too). The key becomes that entry's
C<api_key>, and its C<api_key_env> is dropped. All names must be known and
every key a non-empty string, or nothing changes (C<400>). C<409> when
there is no setup yet. Applied like a C<PUT> of the patched setup.

=item C<DELETE /knarr/admin/config>

Drops what was delivered: back to the setup Knarr started with (its config
file or environment), or under L</ram_only> back to no setup, where every
other request answers C<503>.

=back

=head2 Applying a setup

A change builds a new L<Langertha::Knarr::Stack> -- a new
L<Langertha::Knarr::Router>, so the engine cache and the discovered models
start empty -- and hands it to the Knarr in one step, under the next
generation. A request that is already running, a stream in particular, goes
on with the engine it started with and is not cut off. The capability
probe (L<Langertha::Knarr::Config/probe_capabilities>) runs again for the
new router on the native server.

=head2 Keys

The admin key is the only key the admin routes accept, as
C<Authorization: Bearer> I<key>, compared in constant time. The proxy key
(L<Langertha::Knarr/auth_token>) never opens them, and a request that
presents the admin key to any other route is refused with C<401>, so the
admin key never reaches an upstream. A pushed C<proxy_api_key> equal to the
admin key is refused. The admin key is held only as its SHA-256 digest.

Error messages name the problem without echoing what was sent: a body that
is not JSON gets no excerpt, unknown names are counted, not listed, and
every string value of the body (four characters or more) is replaced by
C<[redacted]> in a message from validation.

=head2 Wrong keys

A request without the admin key gets C<401>. After L</free_failures> such
requests in a row from one peer address, every further one locks that
address out for 1, 2, 4 ... up to L</max_lockout> seconds: until then its
requests answer C<429> with C<Retry-After>, without even checking the key.
A request with the key ends the count. Failures more than an hour apart do
not add up.

=head2 Limits

The body of C<PUT> and C<PATCH> may be at most L</max_body> bytes, else
C<413>; under PSGI the body is not even read then, nor before the key was
checked. The routes are not published anywhere: not in the provider
manifest, not as a protocol route.

Each process holds its own setup, so the admin routes need a single
process: L<Langertha::Knarr> refuses L<Langertha::Knarr/workers> above
C<1> with an admin, C<knarr start> sets it to C<1> with a warning, and
under a PSGI server that sets C<psgi.multiprocess> the routes answer C<501>.

=attr key

Required, at construction only. The admin key, at least
L<Langertha::Knarr::Config/admin_key_min_length> characters. Only its digest
is kept.

=attr stack

Required. The L<Langertha::Knarr::Stack> Knarr starts with; afterwards the
one currently installed.

=attr ram_only

Boolean, default C<0>. Start without a setup (L</configured> false) and go
back to none on C<DELETE>.

=attr configured

False while there is no setup to serve from (L</ram_only> before the first
push, or after a C<DELETE>). L<Langertha::Knarr> answers every route but the
admin routes with C<503> then.

=attr generation

Starts at C<0>, one more for every change.

=attr max_body

Largest admin request body in bytes. Default C<1048576> (1 MiB).

=attr free_failures

Wrong-key requests in a row from one address before the lockouts start.
Default C<2>.

=attr max_lockout

Longest lockout in seconds. Default C<300>.

=method routes

    my @routes = Langertha::Knarr::Admin->routes;

The admin routes as C<{ method, path, action }> hashes.

=method is_key

    $admin->is_key($candidate);

True when C<$candidate> is the admin key, compared in constant time.

=method status

The status as a HashRef (see C<GET /knarr/admin/status>).

=method handle

    my ( $status, $content_type, $body, $headers ) = $admin->handle(
        knarr          => $knarr,
        action         => 'admin_put_config',
        request        => $req,          # ->header($name)
        content_length => $length,
        body           => sub { $bytes },
        peer           => $address,
        multiprocess   => 0,
    );

Answers one admin request; C<$headers> are further C<[ name, value ]>
pairs. Used by L<Langertha::Knarr> and L<Langertha::Knarr::PSGI>.

=cut

my @ROUTES = (
  { method => 'GET',    path => '/knarr/admin/status', action => 'admin_status' },
  { method => 'PUT',    path => '/knarr/admin/config', action => 'admin_put_config' },
  { method => 'DELETE', path => '/knarr/admin/config', action => 'admin_delete_config' },
  { method => 'PATCH',  path => '/knarr/admin/keys',   action => 'admin_patch_keys' },
);

# Config keys that only take effect at start, named in a refusal; any other
# key a push may not set is counted, not echoed.
my @PROCESS_KEYS = qw(
  listen workers logging langfuse admin_key ram_only public_url
  ollama_compat_version a2a
);

# Actions that read a body.
my %WITH_BODY = ( admin_put_config => 1, admin_patch_keys => 1 );

around BUILDARGS => sub {
  my ( $orig, $class, @args ) = @_;
  my $args = $class->$orig(@args);
  my $key = delete $args->{key};
  my $min = Langertha::Knarr::Config->admin_key_min_length;
  croak __PACKAGE__.": key must be a string of at least $min characters"
    unless defined $key && !ref $key && length $key >= $min;
  $args->{_key_digest} = sha256( $class->_bytes($key) );
  return $args;
};

has _key_digest => (
  is       => 'ro',
  required => 1,
);

has stack => (
  is       => 'ro',
  required => 1,
  writer   => '_set_stack',
);

has _boot_stack => (
  is       => 'ro',
  init_arg => undef,
  writer   => '_set_boot_stack',
);

has ram_only => (
  is      => 'ro',
  isa     => 'Bool',
  default => 0,
);

has configured => (
  is       => 'ro',
  init_arg => undef,
  writer   => '_set_configured',
);

has generation => (
  is       => 'ro',
  init_arg => undef,
  default  => 0,
  writer   => '_set_generation',
);

has applied_at => (
  is       => 'ro',
  init_arg => undef,
  writer   => '_set_applied_at',
);

has source => (
  is       => 'ro',
  init_arg => undef,
  writer   => '_set_source',
);

has max_body => (
  is      => 'ro',
  isa     => 'Int',
  default => 1_048_576,
);

has free_failures => (
  is      => 'ro',
  isa     => 'Int',
  default => 2,
);

has max_lockout => (
  is      => 'ro',
  isa     => 'Int',
  default => 300,
);

# Wrong-key requests by peer address: { count, last, until }.
has _failures => (
  is      => 'ro',
  default => sub { {} },
);

has _json => (
  is      => 'ro',
  default => sub { JSON::MaybeXS->new( utf8 => 1, canonical => 1 ) },
);

sub BUILD {
  my ($self) = @_;
  $self->_set_boot_stack( $self->stack );
  $self->_set_configured( $self->ram_only ? 0 : 1 );
  $self->_set_source( $self->_boot_source );
  $self->_set_applied_at( $self->_now );
}

sub config_class { 'Langertha::Knarr::Config' }

sub routes { map { { %$_ } } @ROUTES }

sub _now { time }

sub _bytes {
  my ($self, $string) = @_;
  utf8::encode($string) if utf8::is_utf8($string);
  return $string;
}

sub _boot_source {
  my ($self) = @_;
  return 'none' if $self->ram_only;
  my $config = $self->_boot_stack->config;
  return $config->can('has_file') && $config->has_file ? 'file' : 'env';
}

sub is_key {
  my ($self, $candidate) = @_;
  return 0 unless defined $candidate && !ref $candidate && length $candidate;
  # Digests of equal length, compared without an early exit: the time does
  # not depend on how much of the key was right.
  my $given = sha256( $self->_bytes($candidate) );
  my $want  = $self->_key_digest;
  my $diff  = 0;
  $diff |= ord( substr $given, $_, 1 ) ^ ord( substr $want, $_, 1 ) for 0 .. 31;
  return $diff ? 0 : 1;
}

sub handle {
  my ($self, %args) = @_;
  my $action = $args{action} // '';
  my $peer = defined $args{peer} && length $args{peer} ? $args{peer} : 'unknown';

  if ( my $wait = $self->_locked_for($peer) ) {
    return $self->_answer( 429, 'too many requests without the admin key, try again later',
      [ 'Retry-After' => $wait ] );
  }
  unless ( $self->_authorized( $args{request} ) ) {
    $self->_record_failure($peer);
    return $self->_answer( 401, 'unauthorized' );
  }
  delete $self->_failures->{$peer};

  return $self->_answer( 501, 'the admin routes need a single-process server:'
    . ' every process holds its own setup in memory (psgi.multiprocess is set)' )
    if $args{multiprocess};

  my $body = '';
  if ( $WITH_BODY{$action} ) {
    my $max = $self->max_body;
    return $self->_answer( 413, "the request body may be at most $max bytes" )
      if ( $args{content_length} // 0 ) > $max;
    $body = $args{body} ? $args{body}->() : '';
    $body = '' unless defined $body;
    return $self->_answer( 413, "the request body may be at most $max bytes" )
      if length $body > $max;
  }

  my $method = '_'.$action;
  return $self->_answer( 404, 'no such admin route' ) unless $self->can($method);
  my @answer;
  try {
    @answer = $self->$method( $args{knarr}, $body );
  } catch {
    # Whatever died here may carry a piece of the body: logged without it.
    $log->errorf( "Admin request %s failed: %s", $action,
      $self->_scrub( $self->_first_line($_), $self->_doc_or_undef($body) ) );
    @answer = $self->_answer( 500, 'the admin request failed' );
  };
  return @answer;
}

sub status {
  my ($self) = @_;
  my $config = $self->stack->config;
  my $configured = $self->configured;
  my $models  = $configured ? eval { $config->models } || {} : {};
  my $default = $configured ? eval { $config->default_engine } : undef;
  my $upstreams = $configured ? eval { $config->passthrough } || {} : {};
  my $at = $self->applied_at;
  return {
    generation       => $self->generation + 0,
    applied_at       => POSIX::strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime $at ),
    applied_at_epoch => $at + 0,
    source           => $self->source,
    configured       => $configured ? JSON::MaybeXS->true : JSON::MaybeXS->false,
    ram_only         => $self->ram_only ? JSON::MaybeXS->true : JSON::MaybeXS->false,
    models           => [ sort keys %$models ],
    default_engine   => $default ? JSON::MaybeXS->true : JSON::MaybeXS->false,
    passthrough      => [ sort keys %$upstreams ],
  };
}

#### Actions

sub _admin_status {
  my ($self) = @_;
  return $self->_answer( 200, $self->status );
}

sub _admin_put_config {
  my ($self, $knarr, $body) = @_;
  my ( $doc, $error ) = $self->_decode($body);
  return $self->_refuse($error) unless $doc;
  return $self->_refuse('the setup must be a JSON object') unless ref $doc eq 'HASH';
  # A pushed setup carries its keys literally. An api_key_env would hand the
  # start environment's secrets to whatever url the same push names.
  if ( my @env = $self->_env_key_refs($doc) ) {
    return $self->_refuse( 'api_key_env is not accepted in a delivered setup ('
      . join( ', ', @env ) . '); deliver the key itself as api_key' );
  }
  my %runtime = map { $_ => 1 } $self->config_class->runtime_keys;
  if ( my @other = grep { !$runtime{$_} } sort keys %$doc ) {
    my %process = map { $_ => 1 } @PROCESS_KEYS;
    my @named = grep { $process{$_} } @other;
    my $unknown = @other - @named;
    return $self->_refuse( 'only the routing setup can be set at runtime ('
      . join( ', ', $self->config_class->runtime_keys ) . ')'
      . ( @named ? '; '.join( ', ', @named ).' take effect only at start' : '' )
      . ( $unknown ? "; $unknown unknown key(s)" : '' ) );
  }
  return $self->_install_runtime( $knarr, $doc, 'replaced' );
}

# Names of the model/default entries of a pushed setup that carry api_key_env.
sub _env_key_refs {
  my ($self, $doc) = @_;
  my @found;
  my $models = ref $doc->{models} eq 'HASH' ? $doc->{models} : {};
  for my $name ( sort keys %$models ) {
    my $def = $models->{$name};
    push @found, "models.$name" if ref $def eq 'HASH' && exists $def->{api_key_env};
  }
  push @found, 'default' if ref $doc->{default} eq 'HASH' && exists $doc->{default}{api_key_env};
  return @found;
}

sub _admin_patch_keys {
  my ($self, $knarr, $body) = @_;
  return $self->_answer( 409, 'there is no setup to change keys in;'
    . ' deliver one with PUT /knarr/admin/config' ) unless $self->configured;
  my ( $doc, $error ) = $self->_decode($body);
  return $self->_refuse($error) unless $doc;
  return $self->_refuse('the body must be a JSON object of name: key pairs')
    unless ref $doc eq 'HASH' && %$doc;

  my $runtime = dclone( $self->_runtime_data( $self->stack->config ) );
  my $models = ref $runtime->{models} eq 'HASH' ? $runtime->{models} : {};
  my $default = ref $runtime->{default} eq 'HASH' ? $runtime->{default} : undef;
  my ( $bad, $unknown, $ambiguous ) = ( 0, 0, 0 );
  for my $name ( sort keys %$doc ) {
    my $key = $doc->{$name};
    unless ( defined $key && !ref $key && length $key ) { $bad++; next }
    my $def = ref $models->{$name} eq 'HASH' ? $models->{$name} : undef;
    if ( $name eq 'default' && $default ) {
      if ($def) { $ambiguous++; next }
      $def = $default;
    }
    unless ($def) { $unknown++; next }
    $def->{api_key} = $key;
    delete $def->{api_key_env};
  }
  my @problems;
  push @problems, "$bad key(s) not a non-empty string" if $bad;
  push @problems, "$unknown name(s) neither a model under models: nor default" if $unknown;
  push @problems, "'default' names both a model and the default engine" if $ambiguous;
  return $self->_refuse( 'no key changed: '.join( '; ', @problems ) ) if @problems;
  return $self->_install_runtime( $knarr, $runtime, 'keys changed' );
}

sub _admin_delete_config {
  my ($self, $knarr) = @_;
  my $boot = $self->_boot_stack;
  my $stack = $boot->with_config( $boot->config )->build;
  $self->_install( $knarr, $stack,
    source     => $self->_boot_source,
    configured => $self->ram_only ? 0 : 1,
  );
  $log->infof( "Admin: delivered setup dropped, generation %d, %s",
    $self->generation, $self->ram_only ? 'no setup (RAM only)' : 'back to the start setup' );
  return $self->_answer( 200, $self->status );
}

#### Applying

# The runtime part of a config's data: the keys a push may set.
sub _runtime_data {
  my ($self, $config) = @_;
  my $data = $config->data;
  return { map { exists $data->{$_} ? ( $_ => $data->{$_} ) : () }
    $self->config_class->runtime_keys };
}

# A pushed (or patched) routing setup on top of the process settings Knarr
# started with: validated, built and installed, or refused with 400 and
# nothing changed.
sub _install_runtime {
  my ($self, $knarr, $runtime, $what) = @_;
  my $boot = $self->_boot_stack->config->data;
  my %runtime_key = map { $_ => 1 } $self->config_class->runtime_keys;
  # ram_only describes how this process started, not the delivered setup:
  # the setup is checked like any config that must name its models.
  my %data = (
    ( map { $_ => $boot->{$_} } grep { !$runtime_key{$_} && $_ ne 'ram_only' } keys %$boot ),
    %$runtime,
    ram_only => 0,
  );
  my $config = $self->config_class->new( data => \%data );

  my @errors = eval { $config->validate };
  push @errors, $self->_first_line($@) if $@;
  push @errors, 'proxy_api_key must differ from the admin key'
    if !@errors && $config->has_proxy_api_key && $self->is_key( $config->proxy_api_key );
  return $self->_refuse( join( '; ', @errors ), $runtime ) if @errors;

  my $stack = $self->_boot_stack->with_config($config);
  @errors = $self->_build_errors($stack);
  return $self->_refuse( join( '; ', @errors ), $runtime ) if @errors;

  $self->_install( $knarr, $stack, source => 'ram', configured => 1 );
  $log->infof( "Admin: setup %s, generation %d, %d model(s)%s", $what,
    $self->generation, scalar keys %{ $config->models },
    $config->default_engine ? ' and a default engine' : '' );
  return $self->_answer( 200, $self->status );
}

# Builds the stack and every engine it names now, so a setup that cannot
# serve is refused instead of failing on its first request.
sub _build_errors {
  my ($self, $stack) = @_;
  return 'the setup cannot be built: '.$self->_first_line($@)
    unless eval { $stack->build; 1 };
  my $config = $stack->config;
  my $router = $stack->router;
  my @errors;
  for my $name ( sort keys %{ $config->models } ) {
    next if eval { $router->resolve( $name, skip_default => 1 ); 1 };
    push @errors, "Model '$name': ".$self->_first_line($@);
  }
  if ( $config->default_engine ) {
    push @errors, 'Default: '.$self->_first_line($@)
      unless eval { $router->resolve(undef); 1 };
  }
  return @errors;
}

# One step, no event loop turn in between: every request after it sees the
# new stack, every request before it keeps the old one.
sub _install {
  my ($self, $knarr, $stack, %meta) = @_;
  $knarr->_apply_stack($stack) if $knarr;
  $self->_set_stack($stack);
  $self->_set_configured( $meta{configured} ? 1 : 0 );
  $self->_set_source( $meta{source} );
  $self->_set_generation( $self->generation + 1 );
  $self->_set_applied_at( $self->_now );
  return;
}

#### Keys and lockouts

sub _authorized {
  my ($self, $req) = @_;
  return 0 unless $req;
  my $value = $req->header('Authorization');
  return 0 unless defined $value;
  $value =~ s/\A\s+|\s+\z//g;
  return 0 unless $value =~ s/\ABearer\s+//i;
  return $self->is_key($value);
}

sub _locked_for {
  my ($self, $peer) = @_;
  my $entry = $self->_failures->{$peer} or return 0;
  my $wait = ( $entry->{until} // 0 ) - $self->_now;
  return $wait > 0 ? POSIX::ceil($wait) : 0;
}

sub _record_failure {
  my ($self, $peer) = @_;
  my $now = $self->_now;
  my $table = $self->_failures;
  $self->_prune_failures($now) if keys %$table >= 10_000;
  my $entry = $table->{$peer};
  $entry = $table->{$peer} = { count => 0, until => 0 }
    if !$entry || $entry->{last} < $now - 3600;
  $entry->{count}++;
  $entry->{last} = $now;
  my $over = $entry->{count} - $self->free_failures;
  if ( $over > 0 ) {
    my $secs = 2 ** ( $over > 20 ? 20 : $over - 1 );
    $secs = $self->max_lockout if $secs > $self->max_lockout;
    $entry->{until} = $now + $secs;
  }
  $log->warnf( "Admin: refused a request from %s without the admin key (%d in a row)",
    $peer, $entry->{count} );
  return;
}

# Bounded memory: forget what no longer locks anyone out, and when that is
# not enough, everything that does not lock right now.
sub _prune_failures {
  my ($self, $now) = @_;
  my $table = $self->_failures;
  for my $peer ( keys %$table ) {
    my $entry = $table->{$peer};
    delete $table->{$peer} if $entry->{until} <= $now && $entry->{last} < $now - 3600;
  }
  return if keys %$table < 10_000;
  delete $table->{$_} for grep { $table->{$_}{until} <= $now } keys %$table;
  return;
}

#### Answers

sub _answer {
  my ($self, $status, $content, $headers) = @_;
  my $data = ref $content ? $content : { error => { message => $content } };
  my @pairs = ( [ 'Cache-Control', 'no-store' ] );
  my @extra = @{ $headers || [] };
  push @pairs, [ splice @extra, 0, 2 ] while @extra;
  return ( $status, 'application/json', $self->_json->encode($data), \@pairs );
}

sub _refuse {
  my ($self, $message, $doc) = @_;
  $message = $self->_scrub( $message, $doc );
  $log->warnf( "Admin: change refused: %s", $message );
  return $self->_answer( 400, $message );
}

# A parse error of JSON::XS & co. quotes the text around the error -- part
# of a key, possibly. Neither the answer nor the log gets it.
sub _decode {
  my ($self, $body) = @_;
  return ( undef, 'the request body is empty' ) unless defined $body && length $body;
  my $doc = eval { $self->_json->decode($body) };
  return ( undef, 'the request body is not valid JSON' ) if $@ || !defined $doc;
  return ($doc);
}

sub _doc_or_undef {
  my ($self, $body) = @_;
  return unless defined $body && length $body;
  my $doc = eval { $self->_json->decode($body) };
  return $doc;
}

# Every string value of the delivered document, four characters or more,
# is taken out of a message -- a key in the wrong place (default: "sk-...")
# would otherwise come back in the error that names the place.
sub _scrub {
  my ($self, $text, $doc) = @_;
  return $text unless defined $doc;
  my %seen;
  my @values = sort { length $b <=> length $a } grep { length >= 4 && !$seen{$_}++ }
    $self->_leaves($doc);
  $text =~ s/\Q$_\E/[redacted]/g for @values;
  return $text;
}

sub _leaves {
  my ($self, $data) = @_;
  return map { $self->_leaves($_) } values %$data if ref $data eq 'HASH';
  return map { $self->_leaves($_) } @$data if ref $data eq 'ARRAY';
  return if ref $data || !defined $data;
  return "$data";
}

sub _first_line {
  my ($self, $err) = @_;
  ( my $text = "$err" ) =~ s/\n.*//s;
  $text =~ s/\s+at \S+ line \d+\.?\s*\z//;
  return $text;
}

__PACKAGE__->meta->make_immutable;
1;
