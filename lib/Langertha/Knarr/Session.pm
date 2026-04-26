package Langertha::Knarr::Session;
# ABSTRACT: Per-conversation state for a Knarr server
our $VERSION = '1.101';
use Moose;
use Time::HiRes qw( time );

=head1 DESCRIPTION

Per-conversation state object that Knarr passes to handlers. Sessions
are created on demand by the Knarr core (one per unique session id
seen in incoming requests) and reused across multiple turns. Handlers
that need to remember state across turns store it in
L</handler_state>; for example L<Langertha::Knarr::Handler::Raider>
caches its per-session L<Langertha::Raider> instance there.

=attr id

Required. The unique session id, typically supplied by the client via
the C<x-session-id> header or extracted from a protocol-specific field.

=attr messages

ArrayRef of message hashes, free-form for handlers that want to keep
their own conversation history (most don't — Raider keeps its own).

=attr metadata

HashRef for arbitrary per-session tags. Handlers and middlewares can
read or write this without coordinating with each other.

=attr handler_state

HashRef where decorator handlers can stash per-session state without
colliding with each other. Convention: key by handler class name.

=attr created_at

Numeric epoch seconds when the session was first seen.

=attr last_active

Numeric epoch seconds, updated by L</touch> on every request.

=method touch

Updates L</last_active> to the current time. Called by the Knarr core
on every dispatch.

=cut

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
