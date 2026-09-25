package Langertha::Knarr::Router;
our $VERSION = '1.102';
# ABSTRACT: Model name to Langertha engine routing with caching
use Moo;
use Carp qw( croak );
use Log::Any qw( $log );
use Scalar::Util qw( blessed refaddr );
use Future;
use Future::Utils qw( fmap_void );
use Langertha ();

=head1 SYNOPSIS

    use Langertha::Knarr::Router;

    my $router = Langertha::Knarr::Router->new(config => $config);

    my ($engine, $model) = $router->resolve('gpt-5.6-terra');
    my $result = $engine->simple_chat(@messages);

    my $models = $router->list_models;

=head1 DESCRIPTION

Resolves a model name to a Langertha engine instance and canonical model
identifier. Engine instances are cached per engine, URL, API key variable,
model and C<context_size>, and reused across requests to avoid repeated construction overhead. Two
models on the same endpoint get two instances, each carrying its own model.

Engine classes are resolved from both C<Langertha::Engine::*> and
C<LangerthaX::Engine::*>.

When C<auto_discover> is enabled in the config, the router queries each
configured endpoint (engine, URL and API key variable) for its full model list on first use, making all discovered
models available as routing targets.

A discovered model is routed with the config of the model entry it was
discovered through, minus the keys that describe that one model. The keys
split into two groups:

=over

=item * Endpoint-level, inherited: C<engine>, C<url>, C<api_key_env>,
C<api_key> (where and how to reach the upstream), and C<system_prompt>,
C<temperature>, C<response_size> (the operator's request policy for that
endpoint; a C<response_size> is a cap on the answer, not a property of the
model).

=item * Model-specific, not inherited: C<model> (replaced by the discovered
id) and C<context_size> (a context window belongs to one model; another
model on the same endpoint may hold less, and on Ollama it sizes the
loaded model through C<num_ctx>). A discovered model gets no
C<context_size>, so the engine and upstream defaults apply.

=back

C<user_agent_timeout> is endpoint-level too: the seconds Langertha waits
for that upstream. A model config without one gets
L<Langertha::Knarr::Config/upstream_timeout> (default C<300>); C<0> in
either leaves the engine without a timeout.

Any other key is inherited. A new per-model key belongs in the
model-specific group.

=cut

# Keys of a model config that describe that one model and therefore never
# pass to the models discovered through it (k31). Everything else is
# endpoint-level and inherited; see the POD above.
my @MODEL_SPECIFIC_KEYS = qw( model context_size );

has config => (
  is       => 'ro',
  required => 1,
);

=attr config

The L<Langertha::Knarr::Config> object. Required.

=cut

has _engine_cache => (
  is      => 'ro',
  default => sub { {} },
);

has _discovered_models => (
  is      => 'rw',
  default => sub { {} },
);

has _discovery_done => (
  is      => 'rw',
  default => 0,
);

# Engine instances a capability probe was started on (k37), by refaddr: each
# cached instance is probed once, whether the probe succeeded or not.
has _probed => (
  is      => 'ro',
  default => sub { {} },
);

has capabilities_generation => (
  is      => 'rw',
  default => 0,
);

=attr capabilities_generation

A counter that grows every time L</probe_capabilities_f> finishes probing an
engine instance. What an engine reports through C<supports()> may have
changed then, so anything that caches capabilities (the manifest) keys on it.

=cut

=method resolve

    my ($engine, $model) = $router->resolve($model_name, %opts);
    my ($engine, $model) = $router->resolve($model_name, skip_default => 1);

Resolves C<$model_name> to a Langertha engine instance and the canonical model
string to use with that engine. The resolution order is:

=over

=item 1. Explicit model config in L<Langertha::Knarr::Config/models>

=item 2. Auto-discovered models (if C<auto_discover> is enabled)

=item 3. The default engine from L<Langertha::Knarr::Config/default_engine>
(skipped when C<skip_default =E<gt> 1> is passed)

=back

The third return value is true when the matched model config has no
C<model> key: the engine is then built without a model, the provider's
default answers, and the returned model string is just the requested alias.
L<Langertha::Knarr::Handler::Router> uses it to report the model that
answered instead of the alias.

    my ($engine, $model, $alias_only) = $router->resolve($model_name);

Croaks if the model cannot be resolved. Pass C<skip_default =E<gt> 1> to allow
the caller to try passthrough before falling back to the default engine.

=cut

sub resolve {
  my ($self, $model_name, %opts) = @_;
  croak "No model specified" unless defined $model_name && length $model_name;

  # Check explicit config first
  my $models = $self->config->models;
  my $def = $models->{$model_name};

  # Check discovered models
  unless ($def) {
    $self->_discover_models unless $self->_discovery_done;
    $def = $self->_discovered_models->{$model_name};
  }

  # Fall back to default engine (skip_default allows caller to try passthrough first)
  unless ($def) {
    return () if $opts{skip_default};
    $def = $self->config->default_engine;
    if ($def) {
      $def = { %$def, model => $model_name };
    }
  }

  croak "Model '$model_name' not configured and no default engine" unless $def;

  my $engine = $self->_get_engine($def, $model_name);
  my $resolved_model = $def->{model} // $model_name;
  # No model: key means the engine was built without a model and the
  # provider default answers; $resolved_model is only the alias then (k22).
  my $alias_only = defined $def->{model} ? 0 : 1;

  return ($engine, $resolved_model, $alias_only);
}

sub _get_engine {
  my ($self, $def, $model_name) = @_;

  my $engine_class = $def->{engine};
  my $cache_key = $self->_engine_cache_key($def);

  if (my $cached = $self->_engine_cache->{$cache_key}) {
    return $cached;
  }

  my $full_class = Langertha->resolve_engine_class($engine_class);

  my %args;

  # API key from env var if specified
  if ($def->{api_key_env}) {
    $args{api_key} = $ENV{$def->{api_key_env}}
      // croak "Environment variable $def->{api_key_env} not set for engine $engine_class";
  } elsif ($def->{api_key}) {
    $args{api_key} = $def->{api_key};
  }

  $args{url} = $def->{url} if $def->{url};
  $args{model} = $def->{model} if $def->{model};
  $args{system_prompt} = $def->{system_prompt} if $def->{system_prompt};
  $args{temperature} = $def->{temperature} if defined $def->{temperature};
  $args{response_size} = $def->{response_size} if defined $def->{response_size};
  # context_size is operator intent: engines composing core's
  # Role::ContextSize take it (and put it on their wire, e.g. Ollama's
  # num_ctx); Config warned once at load about engines that cannot (k30).
  $args{context_size} = $def->{context_size}
    if defined $def->{context_size} && $full_class->can('context_size');

  # A hanging upstream must not hold the client's request open forever
  # (k35): the model config's own user_agent_timeout, else the global
  # upstream_timeout. 0 leaves the engine without one.
  my $timeout = $def->{user_agent_timeout} // $self->config->upstream_timeout;
  $args{user_agent_timeout} = $timeout
    if $timeout && $timeout > 0 && $full_class->can('user_agent_timeout');

  # Langfuse config from global config
  my $langfuse = $self->config->langfuse;
  if ($langfuse && %$langfuse) {
    $args{langfuse_public_key} = $langfuse->{public_key} if $langfuse->{public_key};
    $args{langfuse_secret_key} = $langfuse->{secret_key} if $langfuse->{secret_key};
    $args{langfuse_url}        = $langfuse->{url}        if $langfuse->{url};
  }

  $log->debugf("Creating engine %s for model %s", $full_class, $model_name);
  my $engine = $full_class->new(%args);

  $self->_engine_cache->{$cache_key} = $engine;
  return $engine;
}

sub _engine_cache_key {
  my ($self, $def) = @_;
  # The model is part of the key: chat_model is read-only on an engine, and
  # core evaluates model-scoped capabilities against it, so each model needs
  # its own instance (k20). context_size is read-only on the engine too, so
  # two aliases of one model with different windows need two instances (k30);
  # so is user_agent_timeout (k35).
  return join('|', $self->_endpoint_key($def),
    map { $def->{$_} // '' } qw( model context_size user_agent_timeout ));
}

# One upstream endpoint: engine, url and API key variable. Discovery runs
# once per endpoint (k23).
sub _endpoint_key {
  my ($self, $def) = @_;
  return join('|', map { $def->{$_} // '' } qw( engine url api_key_env ));
}

sub _discover_models {
  my ($self) = @_;
  return if $self->_discovery_done;
  $self->_discovery_done(1);

  return unless $self->config->auto_discover;

  my $models = $self->config->models;
  my %seen_endpoints;

  for my $name (keys %$models) {
    my $def = $models->{$name};
    my $engine_class = $def->{engine};
    next if $seen_endpoints{ $self->_endpoint_key($def) }++;

    eval {
      my $engine = $self->_get_engine($def, $name);
      if ($engine->can('list_models')) {
        $log->debugf("Discovering models from %s", $engine_class);
        my $model_ids = $engine->list_models;
        for my $id (@$model_ids) {
          next if $models->{$id};
          next if $self->_discovered_models->{$id};
          my %inherited = %$def;
          delete @inherited{@MODEL_SPECIFIC_KEYS};
          $self->_discovered_models->{$id} = {
            %inherited,
            model      => $id,
            discovered => 1,
          };
          $log->debugf("Discovered model: %s (via %s)", $id, $engine_class);
        }
      }
    };
    if ($@) {
      $log->debugf("Model discovery skipped for %s: %s", $engine_class, $@);
    }
  }
}

=method list_models

    my $models = $router->list_models;

Returns an ArrayRef of model hashrefs, each with keys C<id>, C<engine>,
C<model>, and C<source> (either C<configured> or C<discovered>). Triggers
auto-discovery if not already done. Used to build the model list responses
for C<GET /v1/models> and C<GET /api/tags>.

=cut

sub list_models {
  my ($self) = @_;

  $self->_discover_models unless $self->_discovery_done;

  my $configured = $self->config->models;
  my $discovered = $self->_discovered_models;
  my @models;

  for my $name (sort keys %$configured) {
    push @models, {
      id       => $name,
      engine   => $configured->{$name}{engine},
      model    => $configured->{$name}{model} // $name,
      source   => 'configured',
    };
  }

  for my $name (sort keys %$discovered) {
    next if $configured->{$name};
    push @models, {
      id       => $name,
      engine   => $discovered->{$name}{engine},
      model    => $discovered->{$name}{model} // $name,
      source   => 'discovered',
    };
  }

  return \@models;
}

=method probe_capabilities_f

    $router->probe_capabilities_f( loop => $loop )->get;

Asks each routed engine instance once which capabilities its model has, from
the provider's own model metadata (Langertha core's
C<probe_model_capabilities_f>, ADR 0032; today that is C<image_input>). The
facts are stored on the very instance L</resolve> hands out, so
C<POST /api/show> (C<vision>) and the provider manifest (C<image_input>) pick
them up without further work.

Every model L</list_models> shows is resolved (running auto-discovery first
when it is enabled and has not run yet), and every distinct engine instance
behind them is probed for its upstream model. An instance is skipped when the
installed core has no probe (Langertha 0.503), when its engine implements
none (C<model_metadata_format> is undefined: only OpenRouter, Mistral, LM
Studio, Ollama and llama.cpp read model metadata; the others would answer
C<{}> without a request anyway), when it has no model to ask about, or when
it was probed before. Calling the method again therefore probes only engine
instances that are new since the last call, such as the ones a later
discovery added.

The probes run concurrently, at most four at a time. A probe that fails or
takes longer than L<Langertha::Knarr::Config/probe_timeout> seconds (only
when C<loop> is given) is logged as a warning and not retried; its engine
keeps the capabilities it had. The returned Future never fails and resolves
to the number of engine instances probed. With
L<Langertha::Knarr::Config/probe_capabilities> off it resolves to C<0> at
once.

L<Langertha::Knarr/start> calls this once the server listens.

=cut

sub probe_capabilities_f {
  my ($self, %args) = @_;
  my $config = $self->config;
  return Future->done(0)
    unless !$config->can('probe_capabilities') || $config->probe_capabilities;
  my $loop    = $args{loop};
  my $timeout = $args{timeout}
    // ( $config->can('probe_timeout') ? $config->probe_timeout : 0 );

  my @targets;
  for my $row (@{ $self->list_models }) {
    my ($engine, $model, $alias_only) = eval { $self->resolve( $row->{id}, skip_default => 1 ) };
    next unless blessed $engine && $engine->can('probe_model_capabilities_f')
      && $engine->can('model_metadata_format')
      && defined eval { $engine->model_metadata_format };
    next if $self->_probed->{ refaddr $engine };
    # An alias without model: key asks about the engine's own default (k22).
    my $upstream = $alias_only ? eval { $engine->chat_model } : $model;
    next unless defined $upstream && !ref $upstream && length $upstream;
    $self->_probed->{ refaddr $engine } = 1;
    push @targets, [ $engine, $upstream, $row->{id} ];
  }
  return Future->done(0) unless @targets;

  return ( fmap_void {
    my ($engine, $upstream, $id) = @{ $_[0] };
    my $probe = eval { $engine->probe_model_capabilities_f( models => [ $upstream ] ) }
      // Future->fail( $@ || 'probe did not start' );
    $probe = Future->wait_any( $probe,
      $loop->delay_future( after => $timeout )
        ->then_fail("capability probe timed out after ${timeout}s") )
      if $loop && $timeout && $timeout > 0;
    $probe->then(sub {
      my ($learned) = @_;
      $log->debugf( "Capability probe for %s (%s): %s", $id, $upstream,
        join( ', ', map { my $m = $_; map { "$m $_=$learned->{$m}{$_}" } sort keys %{ $learned->{$m} } }
          sort keys %{ $learned || {} } ) || 'nothing learned' );
      Future->done;
    })->else(sub {
      my ($err) = @_;
      ( my $text = "$err" ) =~ s/\s+\z//;
      $log->warnf( "Capability probe for %s (%s) failed: %s", $id, $upstream, $text );
      Future->done;
    })->on_ready(sub {
      $self->capabilities_generation( $self->capabilities_generation + 1 );
    });
  } foreach => [ @targets ], concurrent => 4 )   # fmap consumes the array it is given
    ->then(sub { Future->done( scalar @targets ) });
}

sub is_passthrough_model {
  my ($self, $model) = @_;
  return 0 unless defined $model && length $model;
  my @r = eval { $self->resolve($model, skip_default => 1) };
  return @r ? 0 : 1;
}

=seealso

=over

=item * L<Langertha::Knarr> — Main documentation and routing priority description

=item * L<Langertha::Knarr::Config> — Provides model and engine configuration

=back

=cut

1;
