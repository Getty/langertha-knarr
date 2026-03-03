package Langertha::Knarr::Router;
our $VERSION = '0.002';
# ABSTRACT: Model name to Langertha engine routing with caching
use Moo;
use Module::Runtime qw( require_module );
use Carp qw( croak );
use Log::Any qw( $log );

has config => (
  is       => 'ro',
  required => 1,
);

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

  return ($engine, $resolved_model);
}

sub _get_engine {
  my ($self, $def, $model_name) = @_;

  my $engine_class = $def->{engine};
  my $cache_key = $self->_engine_cache_key($def);

  if (my $cached = $self->_engine_cache->{$cache_key}) {
    return $cached;
  }

  my $full_class = "Langertha::Engine::$engine_class";
  require_module($full_class);

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
  my $engine = $def->{engine} // '';
  my $url = $def->{url} // '';
  my $key_env = $def->{api_key_env} // '';
  return join('|', $engine, $url, $key_env);
}

sub _discover_models {
  my ($self) = @_;
  return if $self->_discovery_done;
  $self->_discovery_done(1);

  return unless $self->config->auto_discover;

  my $models = $self->config->models;
  my %seen_engines;

  for my $name (keys %$models) {
    my $def = $models->{$name};
    my $engine_class = $def->{engine};
    next if $seen_engines{$engine_class}++;

    eval {
      my $engine = $self->_get_engine($def, $name);
      if ($engine->can('list_models')) {
        $log->debugf("Discovering models from %s", $engine_class);
        my $model_ids = $engine->list_models;
        for my $id (@$model_ids) {
          next if $models->{$id};
          next if $self->_discovered_models->{$id};
          $self->_discovered_models->{$id} = {
            %$def,
            model      => $id,
            discovered => 1,
          };
          $log->debugf("Discovered model: %s (via %s)", $id, $engine_class);
        }
      }
    };
    if ($@) {
      $log->warnf("Model discovery failed for %s: %s", $engine_class, $@);
    }
  }
}

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

1;
