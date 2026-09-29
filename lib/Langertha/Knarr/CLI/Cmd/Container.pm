package Langertha::Knarr::CLI::Cmd::Container;
our $VERSION = '1.102';
# ABSTRACT: Alias for 'knarr start --from-env' (Docker mode)
use Moo;
use MooX::Cmd;
use MooX::Options protect_argv => 0, usage_string => 'USAGE: knarr container [options]';

=head1 DESCRIPTION

Deprecated alias for C<knarr start --from-env>. Kept for backwards
compatibility with existing Docker images. It takes no options of its own
(C<-p> and the other C<start> options are refused; the global C<-c>/C<-v>
before the subcommand still apply) and starts like
C<knarr start --from-env> without C<-p>: on the config's listen addresses,
which default to loopback (C<127.0.0.1:8080>, C<127.0.0.1:11434>). Use
C<knarr start --from-env -p 8080 -p 11434> instead, as the Docker image
does.

=cut

sub execute {
  my ($self, $args, $chain) = @_;
  print STDERR "[knarr] NOTE: 'knarr container' is now 'knarr start --from-env'\n";
  require Langertha::Knarr::CLI::Cmd::Start;
  my $start = Langertha::Knarr::CLI::Cmd::Start->new(
    from_env => 1,
    host     => '0.0.0.0',
    port     => [],
    workers  => 1,
  );
  $start->execute($args, $chain);
}

1;
