package Test::Knarr::Virtual;
# ABSTRACT: A real Knarr over loopback with Langertha::Engine::Virtual as its backend
use strict;
use warnings;
use Carp ();
use Exporter 'import';
use IO::Async::Loop;
use Net::Async::HTTP;
use HTTP::Request;
use JSON::MaybeXS;
use Path::Tiny;
use YAML::PP;

use Langertha::Knarr;
use Langertha::Knarr::Admin;
use Langertha::Knarr::Config;
use Langertha::Knarr::Stack;
use Langertha::Knarr::RequestLog;

our @EXPORT_OK = qw( virtual_available knarr_virtual );

=head1 SYNOPSIS

    use Test::Knarr::Virtual qw( knarr_virtual );

    my $kv = knarr_virtual(
      config   => { models => { fast => { engine => 'KnarrVirtual', model => 'v1' } } },
      backends => { v1 => { rules => { Hello => { answer => 'Hi!' } } } },
    );
    my $res = $kv->chat( openai => model => 'fast', prompt => 'Hello' );
    $res->{text};                    # Hi!
    $kv->backend('v1')->requests;    # what the backend engine saw

=head1 DESCRIPTION

Builds what C<knarr start> builds -- Config, Stack, Admin, Knarr -- and
serves it on an ephemeral loopback port. The backend of every model is a
C<LangerthaX::Engine::KnarrVirtual>, a L<Langertha::Engine::Virtual> that
takes its rules from the C<backends> map by the model it was built for (the
model the config names under C<model:>, else the name the client asked for;
C<*> is the fallback entry). A backend entry is the rules-file format of the
Virtual engine: C<rules>, C<after>, C<fallback> or C<script>. No network, no
key. The C<engine:> of a model in the config is written C<KnarrVirtual>.

=cut

sub virtual_available { eval { require Langertha::Engine::Virtual; 1 } ? 1 : 0 }

our ( %BACKENDS, %ENGINES );

if (virtual_available()) {
  package LangerthaX::Engine::KnarrVirtual;
  use Moose;
  extends 'Langertha::Engine::Virtual';

  around BUILDARGS => sub {
    my ( $orig, $class, @args ) = @_;
    my $args  = @args == 1 ? { %{ $args[0] } } : { @args };
    my $model = $args->{model} // '*';
    my $spec  = $BACKENDS{$model} // $BACKENDS{'*'}
      or Carp::croak("Test::Knarr::Virtual: no backend for model '$model'");
    my $file = Path::Tiny->tempfile( SUFFIX => '.yml' );
    $file->spew_utf8( YAML::PP->new->dump_string($spec) );
    $Test::Knarr::Virtual::KEEP{ $file->stringify } = $file;
    return $class->$orig( %$args, langfuse_enabled => 0, rules_file => $file->stringify );
  };
  after BUILD => sub { my ( $self, $args ) = @_; push @{ $ENGINES{ $args->{model} // '*' } }, $self };
  __PACKAGE__->meta->make_immutable;
  $INC{'LangerthaX/Engine/KnarrVirtual.pm'} = __FILE__;
}

our %KEEP;

my $json = JSON::MaybeXS->new( utf8 => 1, canonical => 1 );
my $loop = IO::Async::Loop->new;
my $http = Net::Async::HTTP->new;
$loop->add($http);

=func knarr_virtual

    my $kv = knarr_virtual(
      config        => \%knarr_config,   # models, default, proxy_api_key, ...
      backends      => \%by_model,
      admin_key     => $key,             # admin routes on
      remote_config => 1,                # start without a setup (503 until PUT)
      request_log   => 1,                # a JSONL request log (see log_entries)
    );

=cut

sub knarr_virtual {
  my ( %opt ) = @_;
  %BACKENDS = %{ $opt{backends} // {} };
  %ENGINES  = ();
  my $data = { %{ $opt{config} // {} } };
  my $log;
  if ( $opt{request_log} ) {
    $log = Path::Tiny->tempfile( SUFFIX => '.jsonl' );
    $data->{logging} = { file => "$log" };
  }
  my $config = Langertha::Knarr::Config->new( data => $data );
  my $rlog   = $log ? Langertha::Knarr::RequestLog->new( config => $config ) : undef;
  my $stack  = Langertha::Knarr::Stack->new(
    config => $config, loop => $loop, ( $rlog ? ( request_log => $rlog ) : () ) );
  my $admin = defined $opt{admin_key} ? Langertha::Knarr::Admin->new(
    key => $opt{admin_key}, stack => $stack, remote_config => $opt{remote_config} // 0 ) : undef;
  my $knarr = Langertha::Knarr->new(
    loop    => $loop,
    port    => 0,
    handler => $stack->handler,
    router  => $stack->router,
    ( defined $stack->auth_token ? ( auth_token => $stack->auth_token ) : () ),
    ( $admin ? ( admin => $admin ) : () ),
  );
  $knarr->start;
  return bless {
    knarr => $knarr,
    port  => $knarr->_server->read_handle->sockport,
    log   => $log,
  }, __PACKAGE__;
}

sub port { $_[0]{port} }

=method backend

    $kv->backend($model)   # the Virtual engine built for that model (last one)

=cut

sub backend { my ( $self, $model ) = @_; return ( $ENGINES{$model} // [] )->[-1] }

sub log_entries {
  my ( $self ) = @_;
  return () unless $self->{log} && $self->{log}->exists;
  return map { $json->decode($_) } grep { length } $self->{log}->lines_utf8( { chomp => 1 } );
}

=method http

    my $res = $kv->http( METHOD => $path, bearer => $k, xkey => $k, body => \%or_string );

Returns C<< { status, headers, body (decoded JSON or undef), raw } >>.

=cut

sub http {
  my ( $self, $method, $path, %o ) = @_;
  my $req = HTTP::Request->new( $method => 'http://127.0.0.1:'.$self->port.$path );
  $req->header( Authorization => 'Bearer '.$o{bearer} ) if defined $o{bearer};
  $req->header( 'x-api-key' => $o{xkey} ) if defined $o{xkey};
  if ( defined $o{body} ) {
    my $body = ref $o{body} ? $json->encode( $o{body} ) : $o{body};
    $req->header( 'Content-Type' => 'application/json', 'Content-Length' => length $body );
    $req->content($body);
  }
  my $resp = $http->do_request( request => $req )->get;
  my $raw  = $resp->decoded_content // '';
  return {
    status  => $resp->code,
    headers => { map { lc $_ => scalar $resp->header($_) } $resp->header_field_names },
    raw     => $raw,
    body    => scalar( eval { $json->decode($raw) } ),
  };
}

# --- the protocols: request shape and the reading of the answer ---

sub _tools_for {
  my ( $proto, $tools ) = @_;
  return () unless $tools && @$tools;
  return ( tools => [ map { {
    type     => 'function',
    function => { name => $_->{name}, description => $_->{description} // $_->{name},
                  parameters => $_->{parameters} // { type => 'object', properties => {} } },
  } } @$tools ] ) if $proto eq 'openai' || $proto eq 'ollama';
  return ( tools => [ map { {
    name => $_->{name}, description => $_->{description} // $_->{name},
    input_schema => $_->{parameters} // { type => 'object', properties => {} },
  } } @$tools ] );
}

my %PROTOCOL = (
  openai => {
    path => '/v1/chat/completions',
    body => sub { my ( $o ) = @_; +{
      model => $o->{model}, messages => $o->{messages} // [ { role => 'user', content => $o->{prompt} } ],
      _tools_for( openai => $o->{tools} ),
    } },
    read => sub { my ( $b ) = @_;
      my $m = $b->{choices}[0]{message} // {};
      return {
        text => $m->{content}, finish_reason => $b->{choices}[0]{finish_reason}, model => $b->{model},
        tool_calls => [ map { { name => $_->{function}{name}, args => $json->decode( $_->{function}{arguments} ) } }
          @{ $m->{tool_calls} // [] } ],
      } },
  },
  anthropic => {
    path => '/v1/messages',
    body => sub { my ( $o ) = @_; +{
      model => $o->{model}, max_tokens => 256,
      messages => $o->{messages} // [ { role => 'user', content => $o->{prompt} } ],
      _tools_for( anthropic => $o->{tools} ),
    } },
    read => sub { my ( $b ) = @_;
      my @c = @{ $b->{content} // [] };
      return {
        text => join( '', map { $_->{text} } grep { $_->{type} eq 'text' } @c ),
        finish_reason => $b->{stop_reason}, model => $b->{model},
        tool_calls => [ map { { name => $_->{name}, args => $_->{input} } } grep { $_->{type} eq 'tool_use' } @c ],
      } },
  },
  ollama => {
    path => '/api/chat',
    body => sub { my ( $o ) = @_; +{
      model => $o->{model}, stream => JSON::MaybeXS::false(),
      messages => $o->{messages} // [ { role => 'user', content => $o->{prompt} } ],
      _tools_for( ollama => $o->{tools} ),
    } },
    read => sub { my ( $b ) = @_;
      my $m = $b->{message} // {};
      return {
        text => $m->{content}, finish_reason => $b->{done_reason}, model => $b->{model},
        tool_calls => [ map { { name => $_->{function}{name}, args => $_->{function}{arguments} } }
          @{ $m->{tool_calls} // [] } ],
      } },
  },
  a2a => {
    path => '/',
    body => sub { my ( $o ) = @_; +{
      jsonrpc => '2.0', id => 1, method => 'tasks/send',
      params => { id => 't1', message => { role => 'user', parts => [ { type => 'text', text => $o->{prompt} } ] } },
    } },
    read => sub { my ( $b ) = @_;
      my $r = $b->{result} // {};
      my @parts = map { @{ $_->{parts} // [] } } @{ $r->{artifacts} // [] };
      return { text => join( '', map { $_->{text} // '' } @parts ), state => $r->{status}{state}, tool_calls => [] } },
  },
  acp => {
    path => '/runs',
    body => sub { my ( $o ) = @_; +{
      agent_name => $o->{model}, mode => 'sync',
      input => [ { parts => [ { content_type => 'text/plain', content => $o->{prompt} } ] } ],
    } },
    read => sub { my ( $b ) = @_;
      my @parts = map { @{ $_->{parts} // [] } } @{ $b->{output} // [] };
      return { text => join( '', map { $_->{content} // '' } @parts ), state => $b->{status}, tool_calls => [] } },
  },
);

=method chat

    my $res = $kv->chat( $protocol, model => ..., prompt => ..., tools => [...],
                         messages => [...], bearer => ..., xkey => ...,
                         stream => 1, extra => \%more_body_fields );

Sends one non-streaming chat in the protocol's own wire format and returns
C<http> extended with C<text>, C<finish_reason>, C<model>, C<tool_calls>
(C<< { name, args } >>) read from the answer when the status is 200.

=cut

sub chat {
  my ( $self, $proto, %o ) = @_;
  my $p = $PROTOCOL{$proto} or die "unknown protocol '$proto'";
  my $body = $p->{body}->( \%o );
  $body->{stream} = $o{stream} ? JSON::MaybeXS::true() : JSON::MaybeXS::false() if exists $o{stream};
  $body = { %$body, %{ $o{extra} } } if $o{extra};
  my $res = $self->http( POST => $p->{path}, ( map { $_ => $o{$_} } grep { defined $o{$_} } qw( bearer xkey ) ),
    body => $body );
  %$res = ( %$res, %{ $p->{read}->( $res->{body} ) } ) if $res->{status} == 200 && ref $res->{body} && !$o{stream};
  return $res;
}

sub protocols { sort keys %PROTOCOL }

1;
