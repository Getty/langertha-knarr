package Langertha::Knarr::PSGI::FakeReq;
# ABSTRACT: Header access on a PSGI environment, shaped like a Net::Async::HTTP::Server request
our $VERSION = '1.103';
use strict;
use warnings;

=head1 DESCRIPTION

Internal to L<Langertha::Knarr::PSGI>: wraps a PSGI C<$env> so the Knarr
code shared with the native server (auth check, protocol parsers, raw
passthrough) can read request headers and the path the way it reads them from a
L<Net::Async::HTTP::Server::Request>.

=cut

sub new {
  my ($class, $env) = @_;
  return bless { env => $env }, $class;
}

=method new

    my $req = Langertha::Knarr::PSGI::FakeReq->new($env);

=cut

sub path { $_[0]{env}{PATH_INFO} // '/' }

=method path

    my $path = $req->path;   # /api/generate

The request path (C<PATH_INFO>), like
L<Net::Async::HTTP::Server::Request/path>; the Ollama protocol reads it to
tell C</api/generate> from C</api/chat>.

=cut

sub header {
  my ($self, $name) = @_;
  ( my $key = uc $name ) =~ tr/-/_/;
  return $self->{env}{"HTTP_$key"};
}

=method header

    my $value = $req->header('x-api-key');

The value of one request header, C<undef> when it was not sent.

=cut

# The request headers as [ name, value ] pairs, like
# Net::Async::HTTP::Server::Request->headers. PSGI keeps only the CGI form
# of a header name, so it comes back lower-cased with dashes (x-api-key).
sub headers {
  my ($self) = @_;
  my $env = $self->{env};
  my @pairs;
  for my $key ( sort keys %$env ) {
    my $name = $key =~ /\AHTTP_(.+)\z/ ? $1
      : $key =~ /\A(CONTENT_TYPE)\z/ ? $1 : next;
    ( $name = lc $name ) =~ tr/_/-/;
    push @pairs, [ $name, $env->{$key} ];
  }
  return @pairs;
}

=method headers

    for my $pair ( $req->headers ) { my ($name, $value) = @$pair; ... }

All request headers as C<[ name, value ]> pairs, names lower-cased with
dashes (PSGI keeps only the CGI form of a name).

=cut

1;
