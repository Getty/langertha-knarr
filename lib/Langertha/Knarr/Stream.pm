package Langertha::Knarr::Stream;
# ABSTRACT: Async chunk iterator returned by streaming Steerboard handlers
our $VERSION = "0.008";
use Moose;
use Future;

# Two ways to construct:
#  1) generator => sub { ... }     — sync coderef returning next string or undef
#  2) source    => sub { ... }     — coderef returning a Future[string|undef]
has generator => ( is => 'ro', isa => 'Maybe[CodeRef]' );
has source    => ( is => 'ro', isa => 'Maybe[CodeRef]' );

sub next_chunk_f {
  my ($self) = @_;
  if ( my $g = $self->generator ) {
    my $v = $g->();
    return Future->done($v);
  }
  if ( my $s = $self->source ) {
    return $s->();
  }
  return Future->done(undef);
}

# Convenience: build a stream from a fixed list of chunks
sub from_list {
  my ($class, @chunks) = @_;
  my @queue = @chunks;
  return $class->new( generator => sub { @queue ? shift @queue : undef } );
}

__PACKAGE__->meta->make_immutable;
1;
