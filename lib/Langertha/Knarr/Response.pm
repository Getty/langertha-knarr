package Langertha::Knarr::Response;
# ABSTRACT: Normalized chat response shared across all Knarr handlers and protocol formatters
our $VERSION = '1.002';
use Moose;
use Scalar::Util qw( blessed );

=head1 DESCRIPTION

The single shape every L<Langertha::Knarr::Handler> returns and every
L<Langertha::Knarr::Protocol> formatter consumes. Mirrors
L<Langertha::Response> but is decoupled from it so non-engine handlers
(L<Langertha::Knarr::Handler::Code>, L<Langertha::Knarr::Handler::A2AClient>,
L<Langertha::Knarr::Handler::ACPClient>) can produce a Knarr response
without going through Langertha first.

C<BUILDARGS> upgrades all the legacy shapes Knarr handlers used to
return — a bare string, a C<{ content =E<gt> ..., model =E<gt> ... }>
hashref, or a stringifiable L<Langertha::Response> — into a
proper value object. So existing call sites can pass anything they
already had and downstream code can rely on a single API.

=attr content

Plain assistant text. Defaults to empty string.

=attr model

The model id that produced the response, if known.

=attr usage

A L<Langertha::Usage> object with token counts, if the engine reported
them. C<undef> for handlers that have no usage data (Code, Passthrough).

=attr tool_calls

ArrayRef of L<Langertha::ToolCall> objects produced by the engine.
Empty arrayref when the response is plain text.

=attr finish_reason

Provider-agnostic stop reason (C<stop>, C<tool_calls>, C<length>, ...).
Optional; the protocol formatters fall back to C<stop> / C<end_turn>
when undef.

=attr raw

Optional. The provider-native response body, kept around for handlers
(passthrough-style) that want to preserve every byte upstream returned.

=cut

has content => (
  is => 'ro',
  isa => 'Str',
  default => '',
);

has model => (
  is => 'ro',
  isa => 'Maybe[Str]',
  default => sub { undef },
);

has usage => (
  is => 'ro',
  isa => 'Maybe[Object]',
  default => sub { undef },
);

has tool_calls => (
  is => 'ro',
  isa => 'ArrayRef',
  default => sub { [] },
);

has finish_reason => (
  is => 'ro',
  isa => 'Maybe[Str]',
  default => sub { undef },
);

has raw => (
  is => 'ro',
  default => sub { undef },
);

=method coerce

    my $r = Langertha::Knarr::Response->coerce( $whatever );

Class method. Accepts:

=over

=item * an existing C<Langertha::Knarr::Response> — returned as-is.

=item * a L<Langertha::Response> — fields lifted via
C<from_langertha_response>.

=item * any other blessed object that stringifies — used as C<content>.

=item * a HashRef — fed to C<new> after key normalization.

=item * a plain scalar — used as C<content>.

=item * C<undef> — produces an empty response.

=back

This is the single normalization entry point. Handlers can return
whatever shape is convenient and the dispatcher coerces once at the
boundary.

=cut

sub coerce {
  my ($class, $thing) = @_;
  return $class->new() unless defined $thing;
  if (blessed $thing) {
    return $thing if $thing->isa($class);
    return $class->from_langertha_response($thing) if $thing->isa('Langertha::Response');
    return $class->new( content => "$thing" );
  }
  if (ref $thing eq 'HASH') {
    return $class->new( %$thing );
  }
  return $class->new( content => "$thing" );
}

=method from_langertha_response

    my $r = Langertha::Knarr::Response->from_langertha_response($lresp);

Builds a Knarr response from a L<Langertha::Response>. Carries
C<content>, C<model>, C<usage>, C<tool_calls>, C<finish_reason>, and
C<raw> across.

=cut

sub from_langertha_response {
  my ($class, $r) = @_;
  return $class->new(
    content       => "$r",
    model         => ( $r->can('model')         ? $r->model         : undef ),
    usage         => ( $r->can('usage')         ? $r->usage         : undef ),
    tool_calls    => ( $r->can('tool_calls')    ? ( $r->tool_calls // [] ) : [] ),
    finish_reason => ( $r->can('finish_reason') ? $r->finish_reason : undef ),
    raw           => ( $r->can('raw')           ? $r->raw           : undef ),
  );
}

=method has_tool_calls

True when C<tool_calls> contains at least one entry.

=cut

sub has_tool_calls {
  my ($self) = @_;
  return scalar @{ $self->tool_calls } > 0;
}

=method clone_with

    my $r2 = $r->clone_with( model => 'override' );

Returns a new response with the given fields overridden. All other
attributes carry through from C<$self>.

=cut

sub clone_with {
  my ($self, %override) = @_;
  return ref($self)->new(
    content       => $self->content,
    model         => $self->model,
    usage         => $self->usage,
    tool_calls    => $self->tool_calls,
    finish_reason => $self->finish_reason,
    raw           => $self->raw,
    %override,
  );
}

__PACKAGE__->meta->make_immutable;
1;
