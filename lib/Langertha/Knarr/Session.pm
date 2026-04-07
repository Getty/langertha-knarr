package Langertha::Knarr::Session;
# ABSTRACT: Per-conversation state for a Steerboard server
our $VERSION = "0.008";
use Moose;
use Time::HiRes qw( time );

has id => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has messages => (
  is => 'rw',
  isa => 'ArrayRef',
  default => sub { [] },
);

has metadata => (
  is => 'rw',
  isa => 'HashRef',
  default => sub { {} },
);

has handler_state => (
  is => 'rw',
  isa => 'HashRef',
  default => sub { {} },
);

has created_at => (
  is => 'ro',
  isa => 'Num',
  default => sub { time() },
);

has last_active => (
  is => 'rw',
  isa => 'Num',
  default => sub { time() },
);

sub touch { $_[0]->last_active( time() ) }

__PACKAGE__->meta->make_immutable;
1;
