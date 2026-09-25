package Langertha::Knarr::Handler::Passthrough;
# ABSTRACT: Knarr handler that forwards requests verbatim to an upstream HTTP API
our $VERSION = '1.102';
use Moose;
use Future;
use Future::AsyncAwait;
use HTTP::Request;
use Net::Async::HTTP;
use IO::Async::Loop;
use JSON::MaybeXS;
use Langertha::Knarr::Stream;
use Langertha::Knarr::Response;
use Langertha::ToolCall;

with 'Langertha::Knarr::Handler';

=head1 SYNOPSIS

    use Langertha::Knarr::Handler::Passthrough;

    my $handler = Langertha::Knarr::Handler::Passthrough->new(
        upstreams => {
            openai    => 'https://api.openai.com',
            anthropic => 'https://api.anthropic.com',
            ollama    => 'http://localhost:11434',
        },
    );

=head1 DESCRIPTION

Forwards the original wire-format request verbatim to a real upstream
API. The protocol's parser already turned the body into a
L<Langertha::Knarr::Request>; Passthrough rebuilds the upstream JSON
from C<$request-E<gt>raw> and re-POSTs it.

Both sync and streaming requests are supported. A sync answer carries
the upstream's text, its tool calls as L<Langertha::ToolCall> objects
and its finish reason (verbatim; the front-side protocol maps it). For
streaming, the
upstream's protocol-native chunks are extracted into plain text deltas,
the upstream's tool calls are assembled into complete
L<Langertha::ToolCall> objects on the stream's C<tool_calls>
which the front-side protocol then re-frames — keeping symmetry even
when client and upstream use the same protocol.

This is the building block behind Knarr's classic "configure your API
keys once, point everything at me" use case.

=attr upstreams

Required. HashRef mapping protocol name (C<openai>, C<anthropic>,
C<ollama>) to upstream base URL. The protocol's default chat path is
appended.

=attr default_auth

Optional. An C<Authorization> header value to inject when the client
didn't send one. Usually you let the client supply its own key.

=attr model_id

Optional. Defaults to C<passthrough>.

=cut

# Forwards the original wire-format request to a real upstream API. The
# protocol's parser already turned the body into a Knarr::Request, so we
# rebuild a body from $request->raw and re-POST it. Headers (especially
# Authorization) are passed through if the caller registers them with the
# session via $request->extra->{forward_headers}.

# Per-protocol upstream URLs. Keys are protocol names ("openai", "anthropic",
# "ollama"). Each value is the base URL of the upstream provider — e.g.
# https://api.openai.com or https://api.anthropic.com. Knarr appends the
# original request path to this base URL.
has upstreams => (
  is       => 'ro',
  isa      => 'HashRef[Str]',
  required => 1,
);

# Optional: a default Authorization header value to inject if the client
# didn't send one. If undef, the client must supply its own.
has default_auth => (
  is => 'ro',
  isa => 'Maybe[Str]',
  default => sub { undef },
);

has model_id => ( is => 'ro', isa => 'Str', default => 'passthrough' );

has loop => (
  is => 'ro',
  lazy => 1,
  default => sub { IO::Async::Loop->new },
);

has _http => ( is => 'ro', lazy => 1, builder => '_build_http' );
sub _build_http {
  my ($self) = @_;
  my $h = Net::Async::HTTP->new;
  $self->loop->add($h);
  return $h;
}

has _json => ( is => 'ro', default => sub { JSON::MaybeXS->new( utf8 => 1, canonical => 1 ) } );

# Per-protocol path the request should hit upstream. We use the protocol
# defaults; this lookup table can be extended.
my %DEFAULT_PATH = (
  openai    => '/v1/chat/completions',
  anthropic => '/v1/messages',
  ollama    => '/api/chat',
);

sub _upstream_url {
  my ($self, $protocol_name) = @_;
  my $base = $self->upstreams->{$protocol_name}
    or die "Passthrough: no upstream configured for protocol '$protocol_name'\n";
  $base =~ s{/+$}{};
  my $path = $DEFAULT_PATH{$protocol_name}
    or die "Passthrough: no default path for protocol '$protocol_name'\n";
  return "$base$path";
}

sub _build_upstream_request {
  my ($self, $request, $force_stream) = @_;
  my $body = { %{ $request->raw || {} } };
  $body->{stream} = $force_stream ? JSON::MaybeXS::true() : JSON::MaybeXS::false()
    if defined $force_stream;
  my $url = $self->_upstream_url( $request->protocol );
  my $http_req = HTTP::Request->new( POST => $url );
  $http_req->header( 'Content-Type' => 'application/json' );
  # Forward client auth headers (captured by protocol parsers)
  if ( my $fwd = $request->extra->{forward_headers} ) {
    for my $h (keys %$fwd) {
      $http_req->header( $h => $fwd->{$h} );
    }
  }
  if ( my $auth = $self->default_auth ) {
    $http_req->header( Authorization => $auth ) unless $http_req->header('Authorization');
  }
  $http_req->content( $self->_json->encode($body) );
  return $http_req;
}

# Read an upstream response body for the protocol it came from: the
# assistant text, the tool calls as Langertha::ToolCall objects (through
# core's canonical inbound door, the same one the streaming path uses) and
# the terminal reason verbatim -- the client-side protocol maps it (k21).
sub _parse_response {
  my ($self, $protocol_name, $resp_body) = @_;
  my %parsed = ( content => '', tool_calls => [], finish_reason => undef );
  my $data = eval { $self->_json->decode($resp_body) };
  return %parsed unless ref $data eq 'HASH';
  if ( $protocol_name eq 'openai' ) {
    $parsed{content}       = $data->{choices}[0]{message}{content} // '';
    $parsed{finish_reason} = $data->{choices}[0]{finish_reason};
  }
  elsif ( $protocol_name eq 'anthropic' ) {
    for my $b ( @{ $data->{content} || [] } ) {
      $parsed{content} .= $b->{text} // '' if ($b->{type} // '') eq 'text';
    }
    $parsed{finish_reason} = $data->{stop_reason};
  }
  elsif ( $protocol_name eq 'ollama' ) {
    $parsed{content}       = $data->{message}{content} // '';
    $parsed{finish_reason} = $data->{done_reason};
  }
  else {
    return %parsed;
  }
  $parsed{tool_calls} = [ Langertha::ToolCall->extract( $protocol_name, $data ) ];
  return %parsed;
}

async sub handle_chat_f {
  my ($self, $session, $request) = @_;
  my $http_req = $self->_build_upstream_request( $request, 0 );
  my $resp = await $self->_http->do_request( request => $http_req );
  die "Passthrough upstream failed: " . $resp->status_line . "\n" unless $resp->is_success;
  return Langertha::Knarr::Response->new(
    $self->_parse_response( $request->protocol, $resp->decoded_content ),
    model => $request->model // $self->model_id,
  );
}

async sub handle_stream_f {
  my ($self, $session, $request) = @_;
  my $http_req = $self->_build_upstream_request( $request, 1 );

  my @queue;
  my $pending;
  my $finished = 0;
  my $error;
  my $buffer = '';

  my $deliver = sub {
    my ($v) = @_;
    if ( $pending ) { my $p = $pending; $pending = undef; $p->done($v) }
    else            { push @queue, $v }
  };

  # Streaming request: hand the body chunks straight back as deltas. The
  # upstream already speaks the same wire format the client requested, so
  # we forward bytes 1:1 by extracting just the text content from each
  # protocol-native chunk. The Knarr core then re-frames them via the
  # client-side protocol's format_stream_chunk — keeping symmetry even
  # when client and upstream use the same protocol.
  my $stream = Langertha::Knarr::Stream->new(
    source => sub {
      if ( @queue )    { return Future->done( shift @queue ) }
      if ( $finished ) { return $error ? Future->fail($error) : Future->done(undef) }
      $pending = Future->new;
      return $pending;
    },
  );

  my $proto_name = $request->protocol;
  # The upstream's terminal reason, verbatim; the client-side protocol maps
  # it when it closes the stream (k18).
  my $note_finish = sub {
    my ($reason) = @_;
    $stream->finish_reason($reason) if defined $reason && length $reason;
  };
  # The upstream's tool calls, assembled into complete Langertha::ToolCall
  # objects: OpenAI delta.tool_calls fragments per index until the stream
  # ends, Anthropic tool_use blocks with their input_json_delta until
  # content_block_stop, Ollama message.tool_calls whole. The client-side
  # protocol frames them when it closes the stream (k19).
  my %openai_calls;
  my %anthropic_blocks;
  my $note_calls = sub {
    my @calls = @_;
    $stream->tool_calls( [ @{ $stream->tool_calls }, @calls ] ) if @calls;
  };
  my $finish_openai_calls = sub {
    return unless %openai_calls;
    my @raw = map { $openai_calls{$_} } sort { $a <=> $b } keys %openai_calls;
    %openai_calls = ();
    $note_calls->( Langertha::ToolCall->extract( 'openai',
      { choices => [ { message => { tool_calls => \@raw } } ] } ) );
  };
  my $extract_chunk = sub {
    my ($line) = @_;
    if ( $proto_name eq 'openai' || $proto_name eq 'anthropic' ) {
      return undef unless $line =~ /^data:\s*(.+)$/;
      my $payload = $1;
      return undef if $payload eq '[DONE]';
      my $d = eval { $self->_json->decode($payload) };
      return undef unless ref $d eq 'HASH';
      if ( $proto_name eq 'openai' ) {
        $note_finish->( $d->{choices}[0]{finish_reason} );
        my $frags = $d->{choices}[0]{delta}{tool_calls};
        for my $frag ( ref $frags eq 'ARRAY' ? @$frags : () ) {
          next unless ref $frag eq 'HASH';
          my $call = $openai_calls{ $frag->{index} // 0 } //=
            { id => '', type => 'function', function => { name => '', arguments => '' } };
          $call->{id} = $frag->{id} if defined $frag->{id} && length $frag->{id};
          my $fn = ref $frag->{function} eq 'HASH' ? $frag->{function} : {};
          $call->{function}{name} = $fn->{name} if defined $fn->{name} && length $fn->{name};
          $call->{function}{arguments} .= $fn->{arguments} // '';
        }
        return $d->{choices}[0]{delta}{content};
      } else {
        my $type = $d->{type} // '';
        $note_finish->( $d->{delta}{stop_reason} ) if $type eq 'message_delta';
        my $index = $d->{index} // 0;
        if ( $type eq 'content_block_start'
          && ref $d->{content_block} eq 'HASH'
          && ( $d->{content_block}{type} // '' ) eq 'tool_use' ) {
          $anthropic_blocks{$index} = { %{ $d->{content_block} }, json => '' };
          return undef;
        }
        if ( $type eq 'content_block_delta' && $anthropic_blocks{$index} ) {
          $anthropic_blocks{$index}{json} .= $d->{delta}{partial_json} // '';
          return undef;
        }
        if ( $type eq 'content_block_stop' && ( my $block = delete $anthropic_blocks{$index} ) ) {
          my $json = delete $block->{json};
          $block->{input} = $json if length $json;
          $note_calls->( grep { defined } Langertha::ToolCall->from_anthropic($block) );
          return undef;
        }
        return $d->{delta}{text} if $type eq 'content_block_delta';
        return undef;
      }
    }
    if ( $proto_name eq 'ollama' ) {
      my $d = eval { $self->_json->decode($line) };
      return undef unless ref $d eq 'HASH';
      $note_finish->( $d->{done_reason} ) if $d->{done};
      $note_calls->( Langertha::ToolCall->extract( 'ollama', $d ) );
      return $d->{message}{content};
    }
    return undef;
  };

  my $f = $self->_http->do_request(
    request => $http_req,
    on_header => sub {
      my ($r) = @_;
      return sub {
        my ($data) = @_;
        if ( !defined $data ) {
          $finish_openai_calls->();
          $finished = 1;
          $deliver->(undef);
          return;
        }
        $buffer .= $data;
        # Frame separator: blank line for SSE, single \n for NDJSON.
        my $sep = $proto_name eq 'ollama' ? qr/\n/ : qr/\n\n/;
        while ( $buffer =~ s/^(.*?)$sep//s ) {
          my $frame = $1;
          for my $line ( split /\n/, $frame ) {
            next unless length $line;
            my $delta = $extract_chunk->($line);
            $deliver->($delta) if defined $delta && length $delta;
          }
        }
      };
    },
  );
  $f->on_fail( sub { $error = $_[0]; $finished = 1; $deliver->(undef) } );
  $f->retain;

  return $stream;
}

sub list_models {
  my ($self) = @_;
  return [ { id => $self->model_id, object => 'model' } ];
}

__PACKAGE__->meta->make_immutable;
1;
