package Langertha::Knarr::Handler::Code;
# ABSTRACT: Coderef-backed Knarr handler for fakes, tests, and custom logic
our $VERSION = '1.002';
use Moose;
use Future;
use Future::AsyncAwait;
use Langertha::Knarr::Stream;

with 'Langertha::Knarr::Handler';

=head1 SYNOPSIS

    use Langertha::Knarr::Handler::Code;

    my $handler = Langertha::Knarr::Handler::Code->new(
        code => sub {
            my ($session, $request) = @_;
            return 'echo: ' . $request->messages->[-1]{content};
        },
        stream_code => sub {
            my @parts = ('hel', 'lo');
            return sub { @parts ? shift @parts : undef };
        },
    );

=head1 DESCRIPTION

The simplest possible handler: pass coderefs that return strings (or
chunk generators for streaming) and you get a working Knarr handler.
Useful for tests, fakes, smoketests, and "fake LLM" demos.

=attr code

Required. Coderef called as C<< $code->($session, $request) >> for
non-streaming requests; must return a scalar string.

=attr stream_code

Optional. Coderef returning another coderef that yields the next chunk
per call, C<undef> to signal end.

=attr models

Optional. Arrayref of model descriptors. Defaults to a single
C<steerboard-code> entry.

=cut

has code => (
  is => 'ro',
  isa => 'CodeRef',
  required => 1,
);

# Optional: separate generator for streaming. Returns a coderef that itself
# returns next-chunk strings (undef = done) when called.
has stream_code => (
  is => 'ro',
  isa => 'Maybe[CodeRef]',
  default => sub { undef },
);

has models => (
  is => 'ro',
  isa => 'ArrayRef',
  default => sub { [ { id => 'steerboard-code', object => 'model' } ] },
);

async sub handle_chat_f {
  my ($self, $session, $request) = @_;
  my $out = $self->code->( $session, $request );
  return { content => "$out", model => $request->model // 'steerboard-code' };
}

async sub handle_stream_f {
  my ($self, $session, $request) = @_;
  if ( my $sc = $self->stream_code ) {
    my $gen = $sc->( $session, $request );
    return Langertha::Knarr::Stream->new( generator => $gen );
  }
  my $text = $self->code->( $session, $request );
  return Langertha::Knarr::Stream->from_list("$text");
}

sub list_models { $_[0]->models }

__PACKAGE__->meta->make_immutable;
1;
