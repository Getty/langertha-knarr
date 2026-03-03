package Langertha::Knarr::CLI::Cmd::Init;
our $VERSION = '0.002';
# ABSTRACT: Scan environment and generate Knarr configuration
use Moo;
use MooX::Cmd;
use MooX::Options protect_argv => 0, usage_string => 'USAGE: knarr init [options]';

option env_file => (
  is      => 'ro',
  format  => 's@',
  short   => 'e',
  doc     => 'Additional .env file(s) to scan (repeatable)',
  default => sub { [] },
);

option listen => (
  is      => 'ro',
  format  => 's@',
  short   => 'l',
  doc     => 'Listen address(es), repeatable (default: 127.0.0.1:8080 + 127.0.0.1:11434)',
  default => sub { ['127.0.0.1:8080', '127.0.0.1:11434'] },
);

option output => (
  is      => 'ro',
  format  => 's',
  short   => 'o',
  doc     => 'Output file (default: stdout)',
);

sub execute {
  my ($self, $args, $chain) = @_;

  require Langertha::Knarr::Config;

  # Scan default .env locations too
  my @env_files = @{$self->env_file};
  for my $default_file ('.env', '.env.local', "$ENV{HOME}/.env") {
    push @env_files, $default_file if -f $default_file;
  }

  my $found = Langertha::Knarr::Config->scan_env(env_files => \@env_files);

  my $yaml = Langertha::Knarr::Config->generate_config(
    engines => $found,
    listen  => $self->listen,
  );

  if (my $out = $self->output) {
    open my $fh, '>', $out or die "Cannot write $out: $!";
    print $fh $yaml;
    close $fh;
    my $count = scalar keys %$found;
    print STDERR "Generated $out with $count engine(s) found\n";
    print STDERR "Found: ", join(', ', sort keys %$found), "\n" if $count;
  } else {
    print $yaml;
    my $count = scalar keys %$found;
    print STDERR "# Found $count engine(s) from environment\n";
    print STDERR "# Engines: ", join(', ', sort keys %$found), "\n" if $count;
  }
}

1;
