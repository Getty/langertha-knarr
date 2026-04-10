package Langertha::Knarr::Request;
# ABSTRACT: Normalized chat request shared across all Knarr protocols
our $VERSION = '1.001';
use Moose;

=head1 DESCRIPTION

The normalized request shape that every L<Langertha::Knarr::Protocol>
parser produces and every L<Langertha::Knarr::Handler> receives.
Wire-protocol-specific quirks (OpenAI's C<choices>, Anthropic's
C<system> outside C<messages>, A2A's JSON-RPC envelope, etc.) are
handled by the protocol's C<parse_chat_request> and don't leak into
the handler API.

The original wire-format body is preserved in L</raw> for handlers
(like L<Langertha::Knarr::Handler::Passthrough>) that need to forward
it verbatim.

=attr protocol

Required. Short string identifying the parser that produced this
request: C<openai>, C<anthropic>, C<ollama>, C<a2a>, C<acp>, C<agui>.

=attr model

Optional model id from the request body.

=attr messages

ArrayRef of message hashes (C<< { role => ..., content => ... } >>).

=attr stream

Boolean. Whether the client requested streaming.

=attr temperature, max_tokens, tools, system

Optional generation parameters and tool definitions, if the protocol
extracted them.

=attr session_id

Optional session id, used for per-session state. Pulled from
protocol-specific fields (e.g. OpenAI's C<user>, A2A's C<sessionId>,
or the C<x-session-id> header).

=attr raw

The original decoded request body. Useful for passthrough handlers
that need to forward without re-encoding.

=attr extra

Per-protocol scratch space (e.g. JSON-RPC id for A2A, run_id for ACP).

=cut

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
