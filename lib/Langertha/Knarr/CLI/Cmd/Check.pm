package Langertha::Knarr::CLI::Cmd::Check;
our $VERSION = '0.002';
# ABSTRACT: Validate Knarr configuration file
use Moo;
use MooX::Cmd;
use MooX::Options protect_argv => 0, usage_string => 'USAGE: knarr check [options]';

sub execute {
  my ($self, $args, $chain) = @_;
  my $main = $chain->[0];
  my $config_file = $main->config;

  unless (-f $config_file) {
    print STDERR "Config file not found: $config_file\n";
    exit 1;
  }

  require Langertha::Knarr::Config;
  my $config = eval { Langertha::Knarr::Config->new(file => $config_file) };
  if ($@) {
    print STDERR "Failed to parse config: $@\n";
    exit 1;
  }

  my @errors = $config->validate;
  if (@errors) {
    print "Configuration INVALID:\n";
    print "  - $_\n" for @errors;
    exit 1;
  }

  my $models = $config->models;
  my $model_count = scalar keys %$models;
  print "Configuration OK\n";
  print "  File: $config_file\n";
  print "  Listen: ", join(', ', @{$config->listen}), "\n";
  print "  Models: $model_count configured\n";
  print "  Default engine: ", ($config->default_engine ? $config->default_engine->{engine} : 'none'), "\n";
  print "  Auto-discover: ", ($config->auto_discover ? 'enabled' : 'disabled'), "\n";
  print "  Proxy auth: ", ($config->has_proxy_api_key && $config->proxy_api_key ? 'enabled' : 'disabled'), "\n";

  # Check Langfuse
  my $lf = $config->langfuse;
  my $lf_pub = $lf->{public_key} // $ENV{LANGFUSE_PUBLIC_KEY};
  my $lf_sec = $lf->{secret_key} // $ENV{LANGFUSE_SECRET_KEY};
  if ($lf_pub && $lf_sec) {
    print "  Langfuse: enabled (", ($lf->{url} // $ENV{LANGFUSE_URL} // 'cloud.langfuse.com'), ")\n";
  } else {
    print "  Langfuse: disabled (set LANGFUSE_PUBLIC_KEY + LANGFUSE_SECRET_KEY to enable)\n";
  }
}

1;
