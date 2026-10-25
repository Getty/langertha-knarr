package Langertha::Knarr::CLI::Cmd::Check;
our $VERSION = '1.104';
# ABSTRACT: Validate Knarr configuration file
use Moo;
with 'Langertha::Knarr::CLI::Role::GlobalOptions';
use MooX::Cmd;
use MooX::Options protect_argv => 0, usage_string => 'USAGE: knarr check [options]';

=head1 DESCRIPTION

Implements the C<knarr check> command. Parses the config file, runs
L<Langertha::Knarr::Config/validate>, and prints a status summary including
listen addresses, model count, auto-discover state, proxy auth state, and
Langfuse tracing state. With a C<token_auth:> section it reports the backend and
routes (never the DSN, user, password or relation) instead of models and proxy
auth, and fails when the backend's driver (C<DBD::Pg>) is missing. Exits with a non-zero code on invalid config.

See L<knarr> for option details and L<Langertha::Knarr::Config> for the
configuration file format.

=seealso

=over

=item * L<knarr> — CLI synopsis and option reference

=item * L<Langertha::Knarr::Config/validate> — Validation logic

=back

=cut

sub execute {
  my ($self, $args, $chain) = @_;
  my $config_file = $self->config_file($chain);

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

  if ( $config->token_auth ) {
    # The stack builds the token store, which needs DBD::Pg; nothing connects.
    require Langertha::Knarr::Stack;
    unless ( eval { Langertha::Knarr::Stack->new( config => $config )->build; 1 } ) {
      ( my $err = $@ ) =~ s/ at \S+ line \d+\.?\n?\z//;
      print "Configuration INVALID:\n  - $err\n";
      exit 1;
    }
    print "Configuration OK\n";
    print "  File: $config_file\n";
    print "  Listen: ", join(', ', @{$config->listen}), "\n";
    print "  Token auth: ", $config->token_auth->{backend},
      " (routes: ", join(', ', sort keys %{ $config->routes }), ")\n";
    print "  Models: from the tokens (no static list)\n";
    print "  Admin routes: ", ($config->has_admin_key ? 'enabled' : 'disabled'), "\n";
    my $lf = $config->langfuse;
    my $lf_pub = $lf->{public_key} // $ENV{LANGFUSE_PUBLIC_KEY};
    my $lf_sec = $lf->{secret_key} // $ENV{LANGFUSE_SECRET_KEY};
    print "  Langfuse: ", ( $lf_pub && $lf_sec ? 'enabled' : 'disabled' ), "\n";
    return;
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
  # Whether, never which key (k75)
  print "  Admin routes: ", ($config->has_admin_key ? 'enabled' : 'disabled'), "\n";
  print "  Remote config: ", ($config->remote_config ? 'yes (a setup may arrive by PUT /knarr/admin/config)' : 'no'), "\n";

  # Check Langfuse
  my $lf = $config->langfuse;
  my $lf_pub = $lf->{public_key} // $ENV{LANGFUSE_PUBLIC_KEY};
  my $lf_sec = $lf->{secret_key} // $ENV{LANGFUSE_SECRET_KEY};
  if ($lf_pub && $lf_sec) {
    print "  Langfuse: enabled (", ($lf->{url} // $ENV{LANGFUSE_URL} // 'cloud.langfuse.com'),
      ", ", $config->langfuse_transport, ")\n";
  } else {
    print "  Langfuse: disabled (set LANGFUSE_PUBLIC_KEY + LANGFUSE_SECRET_KEY to enable)\n";
  }
}

1;
