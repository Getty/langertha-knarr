package Langertha::Knarr::Stream;
# ABSTRACT: Async chunk iterator returned by streaming Knarr handlers
our $VERSION = '1.101';
use Moose;
use Future;

=head1 SYNOPSIS

    use Langertha::Knarr::Stream;

    # From a fixed list of strings
    my $stream = Langertha::Knarr::Stream->from_list('hel', 'lo');

    # From a sync generator
    my @parts = ('hel', 'lo');
    my $stream = Langertha::Knarr::Stream->new(
        generator => sub { @parts ? shift @parts : undef },
    );

    # From a future-yielding source (real async)
    my $stream = Langertha::Knarr::Stream->new(
        source => sub { $next_chunk_future },
    );

    # Drain it
    while ( defined( my $chunk = $stream->next_chunk_f->get ) ) {
        print $chunk;
    }

=head1 DESCRIPTION

The chunk iterator that streaming Knarr handlers return. Supports two
construction modes: a sync C<generator> coderef that returns the next
chunk string each call (or C<undef> for end), or a C<source> coderef
that returns a L<Future> resolving to the next chunk string. The
Future form is the one real async backends like L<Net::Async::HTTP>
use; the generator form is for tests and simple cases.

=attr generator

Optional. CodeRef returning the next chunk synchronously.

=attr source

Optional. CodeRef returning a L<Future> that resolves to the next
chunk.

=method next_chunk_f

Returns a L<Future> resolving to the next chunk string, or C<undef>
when the stream is exhausted.

=method from_list

    my $stream = Langertha::Knarr::Stream->from_list(@chunks);

Convenience constructor that builds a stream from a fixed list of
chunk strings.

=method from_callback

    my $stream = Langertha::Knarr::Stream->from_callback( sub {
        my ($emit, $done, $fail) = @_;
        my $f = $engine->simple_chat_stream_realtime_f(
            sub { $emit->( $_[0]->content ) },
            @messages,
        );
        $f->on_done( $done );
        $f->on_fail( $fail );
        $f->retain;
    });

Builds a stream backed by a callback-driven producer. The setup sub
receives three callbacks — C<$emit-E<gt>($chunk)>, C<$done-E<gt>()>,
C<$fail-E<gt>($err)> — and is expected to wire them to the underlying
async source. Internally maintains a queue and pending Future so the
consumer side can sit on C<next_chunk_f> without polling.

This is the canonical replacement for the queue/pending/finished/error
pump that engine-backed handlers used to inline.

=cut

sub from_callback {
  my ($class, $setup) = @_;
  my @queue;
  my $pending;
  my $finished = 0;
  my $error;

  my $deliver = sub {
    my ($v) = @_;
    if ( $pending ) { my $p = $pending; $pending = undef; $p->done($v) }
    else            { push @queue, $v }
  };

  my $emit = sub {
    my ($chunk) = @_;
    return unless defined $chunk && length $chunk;
    $deliver->($chunk);
  };
  my $done = sub { $finished = 1; $deliver->(undef) };
  my $fail = sub { $error = $_[0] // 'unknown error'; $finished = 1; $deliver->(undef) };

  $setup->($emit, $done, $fail);

  return $class->new(
    source => sub {
      if ( @queue )    { return Future->done( shift @queue ) }
      if ( $finished ) { return $error ? Future->fail($error) : Future->done(undef) }
      $pending = Future->new;
      return $pending;
    },
  );
}

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
