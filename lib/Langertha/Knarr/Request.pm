package Langertha::Knarr::Request;
# ABSTRACT: Normalized chat request shared across all Steerboard protocols
our $VERSION = "0.008";
use Moose;

has model => (
  is => 'ro',
  isa => 'Maybe[Str]',
  default => sub { undef },
);

has messages => (
  is => 'ro',
  isa => 'ArrayRef[HashRef]',
  default => sub { [] },
);

has stream => (
  is => 'ro',
  isa => 'Bool',
  default => 0,
);

has temperature => (
  is => 'ro',
  isa => 'Maybe[Num]',
  default => sub { undef },
);

has max_tokens => (
  is => 'ro',
  isa => 'Maybe[Int]',
  default => sub { undef },
);

has tools => (
  is => 'ro',
  isa => 'Maybe[ArrayRef]',
  default => sub { undef },
);

has system => (
  is => 'ro',
  isa => 'Maybe[Str]',
  default => sub { undef },
);

has session_id => (
  is => 'rw',
  isa => 'Maybe[Str]',
  default => sub { undef },
);

has protocol => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has raw => (
  is => 'ro',
  isa => 'HashRef',
  default => sub { {} },
);

has extra => (
  is => 'ro',
  isa => 'HashRef',
  default => sub { {} },
);

__PACKAGE__->meta->make_immutable;
1;
