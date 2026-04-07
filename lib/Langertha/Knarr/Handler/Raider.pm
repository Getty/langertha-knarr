package Langertha::Knarr::Handler::Raider;
# ABSTRACT: Steerboard handler that backs each session with a Langertha::Raider
our $VERSION = "0.008";
use Moose;
use Future::AsyncAwait;
use Scalar::Util qw( blessed );
use Storable qw( dclone );

with 'Langertha::Knarr::Handler';

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
