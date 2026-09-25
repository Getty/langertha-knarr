package Langertha::Knarr::Handler::ACPClient;
# ABSTRACT: Steerboard handler that consumes a remote ACP (BeeAI) agent
our $VERSION = '1.102';
use Moose;
use Future::AsyncAwait;
use JSON::MaybeXS;
use HTTP::Request;
use Langertha::Knarr::Response;

with 'Langertha::Knarr::Handler', 'Langertha::Knarr::Role::UpstreamHTTP';

=head1 SYNOPSIS

    use Langertha::Knarr::Handler::ACPClient;

    my $handler = Langertha::Knarr::Handler::ACPClient->new(
        url        => 'https://some-acp-server.example',
        agent_name => 'my-agent',
    );

=head1 DESCRIPTION

Consumes a remote IBM/BeeAI Agent Communication Protocol (ACP) agent
as a Knarr backend. Each chat request is sent as a synchronous
C<POST /runs> with a single C<text/plain> input part; the returned
run's output text becomes the response.

Pair with a front-side Knarr speaking OpenAI to expose any ACP agent
to OpenAI-format clients.

=attr url

Required. Base URL of the upstream ACP server (path C</runs> is
appended).

=attr agent_name

Required. The C<agent_name> to send in each ACP run request.

=attr timeout

Seconds the remote agent may take to answer, in total. Default C<300>;
C<0> disables it. See L<Langertha::Knarr::Role::UpstreamHTTP>.

=attr model_id

Optional. Defaults to L</agent_name>.

=cut

has url        => ( is => 'ro', isa => 'Str', required => 1 );  # base URL of ACP server
has agent_name => ( is => 'ro', isa => 'Str', required => 1 );
has model_id   => ( is => 'ro', isa => 'Str', lazy => 1, default => sub { $_[0]->agent_name } );

has _json => ( is => 'ro', default => sub { JSON::MaybeXS->new( utf8 => 1, canonical => 1 ) } );

sub _extract_text {
  my ($self, $run) = @_;
  return '' unless ref $run eq 'HASH';
  my @bits;
  for my $msg ( @{ $run->{output} || [] } ) {
    for my $part ( @{ $msg->{parts} || [] } ) {
      push @bits, ( $part->{content} // '' )
        if ( $part->{content_type} // '' ) =~ m{^text/};
    }
  }
  return join '', @bits;
}

async sub handle_chat_f {
  my ($self, $session, $request) = @_;
  my @user = grep { ($_->{role} // '') eq 'user' } @{ $request->messages };
  my $last = $user[-1] // { content => '' };

  my $body = {
    agent_name => $self->agent_name,
    mode       => 'sync',
    input      => [ {
      parts => [ { content_type => 'text/plain', content => $last->{content} // '' } ],
    } ],
  };

  ( my $base = $self->url ) =~ s{/$}{};
  my $http_req = HTTP::Request->new( POST => "$base/runs" );
  $http_req->header( 'Content-Type' => 'application/json' );
  $http_req->content( $self->_json->encode($body) );

  my $resp = await $self->_upstream_request_f( request => $http_req );
  die "ACP remote failed: " . $resp->status_line . "\n" unless $resp->is_success;

  my $data = $self->_json->decode( $resp->decoded_content );
  return Langertha::Knarr::Response->new(
    content => $self->_extract_text($data),
    model   => $self->model_id,
    raw     => $data,
  );
}

sub list_models {
  my ($self) = @_;
  return [ { id => $self->model_id, object => 'model' } ];
}

__PACKAGE__->meta->make_immutable;
1;
