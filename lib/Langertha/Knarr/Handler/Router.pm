package Langertha::Knarr::Handler::Router;
# ABSTRACT: Knarr handler that resolves model names via Langertha::Knarr::Router and dispatches to engines
our $VERSION = '1.102';
use Moose;
use Future;
use Future::AsyncAwait;
use Langertha::Knarr::Stream;
use Langertha::Knarr::Response;

with 'Langertha::Knarr::Handler';

=head1 SYNOPSIS

    use Langertha::Knarr::Config;
    use Langertha::Knarr::Router;
    use Langertha::Knarr::Handler::Router;
    use Langertha::Knarr::Handler::Passthrough;

    my $config = Langertha::Knarr::Config->new(file => 'knarr.yaml');
    my $router = Langertha::Knarr::Router->new(config => $config);

    my $handler = Langertha::Knarr::Handler::Router->new(
        router      => $router,
        passthrough => Langertha::Knarr::Handler::Passthrough->new(
            upstreams => $config->passthrough,
        ),
    );

=head1 DESCRIPTION

Resolves incoming model names against a L<Langertha::Knarr::Router>
(which knows your C<knarr.yaml>) and dispatches to the matched
L<Langertha::Engine>. When a passthrough fallback handler is supplied,
unknown model names tunnel through to it instead of failing — this
preserves the classic Knarr behaviour where configured models go via
Langertha and everything else passes straight to the upstream API.

Non-streaming answers are labeled with the configured model. For a model
config without a C<model> key the provider's default answers, so the
response keeps the model the upstream reported, else the engine's
C<chat_model>; it is never relabeled with the alias.

Streaming responses are pumped via the engine's
C<chat_stream_realtime_f> for native token-by-token delivery, with the
same capability-filtered generation parameters as the non-streaming path.

=attr router

Required. A L<Langertha::Knarr::Router> instance.

=attr passthrough

Optional. Any L<Langertha::Knarr::Handler> consumer used as a fallback
when the router can't resolve a model.

=cut

# Wraps a Langertha::Knarr::Router (which is Moo) and uses it to resolve
# incoming model names to Langertha engine instances. Also keeps the
# upstream Knarr::Config visible for the rest of the request lifecycle.

has router => ( is => 'ro', required => 1 );

# Optional Passthrough handler used as fallback when the router can't
# resolve a model. Allows mixed mode: configured models go via Langertha
# engines (with tracing/middleware support), unknown models tunnel straight
# to the upstream API the client thinks they're talking to.
has passthrough => (
  is => 'ro',
  isa => 'Maybe[Object]',
  default => sub { undef },
);

sub _resolve {
  my ($self, $model) = @_;
  $model //= 'default';
  if ($self->passthrough) {
    # With passthrough: try without default engine first so unknown models
    # go to passthrough instead of being routed to the default engine.
    my @r = eval { $self->router->resolve($model, skip_default => 1) };
    return @r if @r;
    return ();  # not found or error → passthrough
  }
  my @r = eval { $self->router->resolve($model) };
  return @r unless $@;
  die $@;
}

async sub handle_chat_f {
  my ($self, $session, $request) = @_;
  my ($engine, $canonical_model, $alias_only) = $self->_resolve( $request->model );
  unless ( $engine ) {
    return Langertha::Knarr::Response->coerce(
      await $self->passthrough->handle_chat_f( $session, $request )
    );
  }
  my $response = await $engine->chat_f( $request->chat_f_args($engine) );
  my $r = Langertha::Knarr::Response->coerce($response);
  # An alias without a configured model: the provider default answered, so
  # report the model that answered, never the alias (k22).
  if ( $alias_only ) {
    return $r if defined $r->model;
    my $chat_model = $engine->can('chat_model') ? $engine->chat_model : undef;
    return defined $chat_model ? $r->clone_with( model => $chat_model ) : $r;
  }
  return $r->clone_with( model => $canonical_model );
}

async sub handle_stream_f {
  my ($self, $session, $request) = @_;
  my ($engine) = $self->_resolve( $request->model );

  unless ( $engine ) {
    return await $self->passthrough->handle_stream_f( $session, $request );
  }

  unless ( _supports_streaming($engine) ) {
    my $r = await $self->handle_chat_f($session, $request);
    my $stream = Langertha::Knarr::Stream->from_list( $r->content );
    $stream->finish_reason( $r->finish_reason );
    $stream->tool_calls( $r->tool_calls );
    return $stream;
  }

  return Langertha::Knarr::Stream->from_callback( sub {
    my ($emit, $done, $fail, $finish, $tool_call) = @_;
    my $cb = sub {
      my ($chunk) = @_;
      my $text = ref $chunk && $chunk->can('content') ? $chunk->content : "$chunk";
      $emit->($text);
      # Langertha::Stream::Chunk carries the backend's finish_reason on the
      # terminal chunk; the protocol maps it when it closes the stream.
      $finish->( $chunk->finish_reason )
        if ref $chunk && $chunk->can('has_finish_reason') && $chunk->has_finish_reason;
      # Core assembles streamed tool-call fragments and attaches the finished
      # Langertha::ToolCall objects to a chunk (Role::Chat::aggregate_tool_calls
      # collects the same); a core whose parser attaches none yields none. The
      # protocol emits them when it closes the stream (k19).
      $tool_call->( @{ $chunk->tool_calls } )
        if ref $chunk && $chunk->can('has_tool_calls') && $chunk->has_tool_calls;
    };
    my $f = $engine->chat_stream_realtime_f( chunk_callback => $cb, $request->chat_f_args($engine) );
    $f->on_done( $done );
    $f->on_fail( $fail );
    $f->retain;
  });
}

sub _supports_streaming {
  my ($engine) = @_;
  return $engine->supports('streaming') if $engine->can('supports');
  return $engine->can('simple_chat_stream_realtime_f') && $engine->can('chat_stream_request');
}

sub list_models {
  my ($self) = @_;
  my $models = $self->router->list_models;
  return [ map { ref $_ eq 'HASH' ? $_ : { id => "$_", object => 'model' } } @{ $models || [] } ];
}

__PACKAGE__->meta->make_immutable;
1;
