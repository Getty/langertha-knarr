package Langertha::Knarr::Role::UpstreamHTTP;
# ABSTRACT: Timed Net::Async::HTTP client for handlers that call an upstream
our $VERSION = '1.103';
use Moose::Role;
use Future;
use Net::Async::HTTP;
use IO::Async::Loop;

=head1 SYNOPSIS

    package My::Handler;
    use Moose;
    with 'Langertha::Knarr::Handler', 'Langertha::Knarr::Role::UpstreamHTTP';

    my $resp = await $self->_upstream_request_f( request => $http_req );
    # streaming: stall_timeout instead of a total timeout
    await $self->_upstream_request_f( request => $http_req, on_header => sub { ... } );

=head1 DESCRIPTION

The HTTP client of the handlers that call an upstream themselves
(L<Langertha::Knarr::Handler::Passthrough>,
L<Langertha::Knarr::Handler::A2AClient>,
L<Langertha::Knarr::Handler::ACPClient>) and the timeouts it applies.
L<Net::Async::HTTP> sets none of its own, so an upstream that accepts the
connection and never answers would hold the client's request open forever.

A plain request gets L</timeout> as its total time. A streaming request
(C<on_header>, or C<stream =E<gt> 1> for a stream read whole) gets
L</stall_timeout> instead: the time the upstream may stay silent, since a
long steady stream is legitimate. On expiry the future fails with
C<< <class>: upstream <url> timed out after Ns >> and the category C<timeout>
or C<stall_timeout>, which L</is_upstream_timeout> recognizes.

=attr timeout

Seconds a non-streaming upstream request may take in total. Default C<300>;
C<0> disables it. Set from C<upstream_timeout> /
C<KNARR_UPSTREAM_TIMEOUT> by C<knarr start>.

=attr stall_timeout

Seconds a streaming upstream request may go without receiving a byte,
waiting for the response headers included. Default C<120>; C<0> disables
it. Set from C<upstream_stall_timeout> / C<KNARR_UPSTREAM_STALL_TIMEOUT> by
C<knarr start>.

=attr loop

Optional L<IO::Async::Loop>. Defaults to C<< IO::Async::Loop->new >>.

=method is_upstream_timeout

    my $is_timeout = Langertha::Knarr::Role::UpstreamHTTP->is_upstream_timeout($category);

True when a failure category from L<Net::Async::HTTP> is one of its
timeouts (C<timeout>, C<stall_timeout>).

=cut

has timeout => ( is => 'ro', isa => 'Num', default => 300 );

has stall_timeout => ( is => 'ro', isa => 'Num', default => 120 );

has loop => (
  is => 'ro',
  lazy => 1,
  default => sub { IO::Async::Loop->new },
);

has _http => ( is => 'ro', lazy => 1, builder => '_build_http' );
sub _build_http {
  my ($self) = @_;
  my $h = Net::Async::HTTP->new;
  $self->loop->add($h);
  return $h;
}

sub is_upstream_timeout {
  my ($class, $category) = @_;
  return defined $category && ( $category eq 'timeout' || $category eq 'stall_timeout' ) ? 1 : 0;
}

# Net::Async::HTTP treats a timeout of 0 as "expire now", so a disabled
# timeout is left out rather than passed. The URL in the failure drops its
# query and userinfo, where a key could sit.
sub _upstream_request_f {
  my ($self, %args) = @_;
  my $stream = delete $args{stream};
  $stream = 1 if $args{on_header};
  my ($option, $secs) = $stream
    ? ( stall_timeout => $self->stall_timeout )
    : ( timeout       => $self->timeout );
  return $self->_http->do_request(%args) unless $secs && $secs > 0;

  my $uri = $args{request}->uri->clone;
  $uri->query(undef);
  $uri->fragment(undef);
  $uri->userinfo(undef) if $uri->can('userinfo');
  my $what = ref($self) . ": upstream $uri";

  return $self->_http->do_request( %args, $option => $secs )->else( sub {
    my ($message, $category, @details) = @_;
    return Future->fail(@_) unless __PACKAGE__->is_upstream_timeout($category);
    my $text = $category eq 'timeout'
      ? "$what timed out after ${secs}s"
      : "$what timed out after ${secs}s without data";
    return Future->fail( "$text\n", $category, @details );
  });
}

1;
