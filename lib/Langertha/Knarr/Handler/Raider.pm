package Langertha::Knarr::Handler::Raider;
# ABSTRACT: Knarr handler that backs each session with a Langertha::Raider
our $VERSION = '1.002';
use Moose;
use Future::AsyncAwait;
use Scalar::Util qw( blessed );
use Storable qw( dclone );

with 'Langertha::Knarr::Handler';

=head1 SYNOPSIS

    use Langertha::Engine::Anthropic;
    use Langertha::Raider;
    use Langertha::Knarr::Handler::Raider;

    my $handler = Langertha::Knarr::Handler::Raider->new(
        model_id => 'langertha-raider',
        raider_factory => sub {
            my ($session, $request) = @_;
            return Langertha::Raider->new(
                engine  => Langertha::Engine::Anthropic->new(
                    api_key => $ENV{ANTHROPIC_API_KEY},
                ),
                mission => 'You are a helpful assistant.',
            );
        },
    );

=head1 DESCRIPTION

Spawns a fresh L<Langertha::Raider> per Knarr session via
L</raider_factory> and dispatches the latest user message to its
C<raid_f> method. The Raider keeps its own conversation history across
turns within a session, so subsequent requests in the same session
continue the same agent loop.

Use this when you're exposing a real autonomous agent (with MCP tools,
mission, persistent context) over a standard LLM wire protocol.

=attr raider_factory

Required. Coderef called as C<< $factory->($session, $request) >> the
first time a session needs a Raider. The returned Raider is cached on
the session and reused for subsequent turns.

=attr model_id

Optional. The id reported by L</list_models>. Defaults to
C<steerboard-raider>.

=cut

# A coderef invoked as $raider_factory->($session, $request) to create a fresh
# Raider for a new session. Receives Steerboard session + request for context.
has raider_factory => (
  is => 'ro',
  isa => 'CodeRef',
  required => 1,
);

has model_id => (
  is => 'ro',
  isa => 'Str',
  default => 'steerboard-raider',
);

sub _session_raider {
  my ($self, $session, $request) = @_;
  return $session->handler_state->{raider} //= $self->raider_factory->( $session, $request );
}

async sub handle_chat_f {
  my ($self, $session, $request) = @_;
  my $raider = $self->_session_raider( $session, $request );

  # Take only the latest user message — Raider keeps its own history per session.
  my @user_msgs = grep { ($_->{role} // '') eq 'user' } @{ $request->messages };
  my $last = $user_msgs[-1] or die "Raider handler: no user message in request\n";

  my $result = await $raider->raid_f( $last->{content} );

  my $content = blessed($result) ? "$result" : ( ref $result eq 'HASH' ? ( $result->{content} // '' ) : "$result" );
  return {
    content => $content,
    model   => $self->model_id,
    raider_result => $result,
  };
}

sub list_models {
  my ($self) = @_;
  return [ { id => $self->model_id, object => 'model' } ];
}

__PACKAGE__->meta->make_immutable;
1;
