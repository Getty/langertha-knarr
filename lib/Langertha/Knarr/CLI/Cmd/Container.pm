package Langertha::Knarr::CLI::Cmd::Container;
our $VERSION = '1.001';
# ABSTRACT: Alias for 'knarr start --from-env' (Docker mode)
use Moo;
use MooX::Cmd;
use MooX::Options protect_argv => 0, usage_string => 'USAGE: knarr container [options]';

=head1 DESCRIPTION

Deprecated alias for C<knarr start --from-env>. Kept for backwards
compatibility with existing Docker images. All options are forwarded to
L<Langertha::Knarr::CLI::Cmd::Start>.

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
