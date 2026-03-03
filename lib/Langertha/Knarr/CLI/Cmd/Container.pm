package Langertha::Knarr::CLI::Cmd::Container;
# ABSTRACT: Auto-start Knarr from environment variables (Docker mode)
use Moo;
use MooX::Cmd;
use MooX::Options protect_argv => 0, usage_string => 'USAGE: knarr container [options]';
use Log::Any qw( $log );
use Log::Any::Adapter;

option workers => (
  is      => 'ro',
  format  => 'i',
  short   => 'w',
  doc     => 'Number of worker processes (default: 1)',
  default => 1,
);

option host => (
  is      => 'ro',
  format  => 's',
  short   => 'H',
  doc     => 'Host to bind to (default: 0.0.0.0)',
  default => '0.0.0.0',
);

option trace_name => (
  is      => 'ro',
  format  => 's',
  short   => 'n',
  doc     => 'Langfuse trace name (default: knarr-proxy, or KNARR_TRACE_NAME env)',
  predicate => 'has_trace_name',
);

sub execute {
  my ($self, $args, $chain) = @_;
  my $main = $chain->[0];

  my $verbose = $main->verbose;
  Log::Any::Adapter->set('Stderr') if $verbose;

  _log("Knarr LLM Proxy starting in container mode...");
  _log("");

  require Langertha::Knarr::Config;

  # Check if a config file was explicitly provided or exists at default location
  my $config_file = $main->config;
  my $config;

  if (-f $config_file) {
    # Use config file if available (e.g., mounted into container)
    $config = Langertha::Knarr::Config->new(file => $config_file);
    my @errors = $config->validate;
    if (@errors) {
      _err("Configuration errors:");
      _err("  - $_") for @errors;
      exit 1;
    }
    _log("Config: loaded from $config_file");
  } else {
    _log("Config: auto-detecting from environment variables");
    # Auto-detect engines from environment (no TEST_ keys)
    $config = Langertha::Knarr::Config->from_env(include_test => 0);
  }

  # Inject CLI trace_name into config langfuse data
  if ($self->has_trace_name) {
    $config->data->{langfuse} //= {};
    $config->data->{langfuse}{trace_name} = $self->trace_name;
  }

  # Log discovered engines and models
  my $models = $config->models;
  my $model_count = scalar keys %$models;
  if ($model_count) {
    _log("Engines: $model_count provider(s) configured");
    _log("");
    for my $name (sort keys %$models) {
      my $m = $models->{$name};
      my $line = "  $name";
      $line .= " => $m->{engine}";
      $line .= " / $m->{model}" if $m->{model};
      if ($m->{api_key_env}) {
        $line .= " (key from \$$m->{api_key_env})";
      }
      _log($line);
    }
    _log("");
  } else {
    _log("Engines: none (passthrough only mode)");
  }

  if ($config->auto_discover) {
    _log("Auto-discover: enabled (will query provider model lists)");
  }

  if ($config->default_engine) {
    _log("Default engine: $config->{data}{default}{engine}");
  }

  # Passthrough status
  my $pt = $config->passthrough;
  if (keys %$pt) {
    my @fmts;
    for my $fmt (sort keys %$pt) {
      push @fmts, "$fmt -> $pt->{$fmt}";
    }
    _log("Passthrough: " . join(', ', @fmts));
  } else {
    _log("Passthrough: disabled");
  }

  # Langfuse tracing status
  my $lf_pub = $config->langfuse->{public_key} // _strip_quotes($ENV{LANGFUSE_PUBLIC_KEY});
  my $lf_sec = $config->langfuse->{secret_key} // _strip_quotes($ENV{LANGFUSE_SECRET_KEY});
  my $lf_url = $config->langfuse->{url} // _strip_quotes($ENV{LANGFUSE_URL}) // _strip_quotes($ENV{LANGFUSE_BASE_URL}) // 'https://cloud.langfuse.com';
  if ($lf_pub && $lf_sec) {
    _log("Langfuse: enabled -> $lf_url");
  } else {
    _log("Langfuse: disabled (set LANGFUSE_PUBLIC_KEY + LANGFUSE_SECRET_KEY to enable)");
  }

  # Proxy auth status
  if ($config->has_proxy_api_key) {
    _log("Proxy auth: enabled (KNARR_API_KEY)");
  } else {
    _log("Proxy auth: open (set KNARR_API_KEY to require authentication)");
  }

  _log("");

  # Container mode: always listen on all interfaces
  my $h = $self->host;
  my @listen_addrs = ("$h:8080", "$h:11434");

  require Langertha::Knarr;
  my $app = Langertha::Knarr->build_app(config => $config);

  my @listen_urls = map { "http://$_" } @listen_addrs;

  _log("Starting server:");
  _log("  Port 8080  — OpenAI / Anthropic API");
  _log("  Port 11434 — Ollama API");
  _log("  Health     — http://$h:8080/health");
  _log("");

  my $daemon = Mojo::Server::Daemon->new(
    app    => $app,
    listen => \@listen_urls,
  );
  $daemon->workers($self->workers) if $daemon->can('workers');
  $daemon->run;
}

sub _log { print STDERR "[knarr] $_[0]\n" }
sub _err { print STDERR "[knarr] $_[0]\n" }

sub _strip_quotes {
  my $v = shift;
  return $v unless defined $v;
  $v =~ s/^["']|["']$//g;
  return $v;
}

1;
