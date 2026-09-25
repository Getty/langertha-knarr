use strict;
use warnings;
use Test2::V0;

# k37: Langertha core's static tables cannot know which model behind a
# gateway (OpenRouter) or on a self-hosted server (Ollama) sees images, so
# they say "no" and /api/show never offered "vision" for them -- VS Code
# Copilot then refuses image input for a model that has it. Core's opt-in
# probe_model_capabilities_f (ADR 0032) reads the provider's own model
# metadata. Knarr runs it once per routed engine instance after start (and
# after auto-discovery), in the background: the facts must land on the SAME
# instance the router hands to /api/show and the manifest, a failing or
# hanging probe must neither crash nor claim anything, each instance is asked
# once (no retry storm), and a core without the probe (0.503), an engine
# without metadata, or probe_capabilities: 0 sends no probe request at all.

BEGIN {
  # Offline discovery (the sync list_models would deadlock against the
  # in-loop upstream below): the self-hosted endpoint lists one model beyond
  # the configured ones, the failing endpoints and the gateway none.
  package LangerthaX::Engine::TestProbeOllama;
  use Moose;
  extends 'Langertha::Engine::Ollama';
  sub list_models {
    $_[0]->url =~ m{/(?:slow|broken)\z} ? [] : [qw( llava llama3 extra-vis )];
  }
  __PACKAGE__->meta->make_immutable;
  $INC{'LangerthaX/Engine/TestProbeOllama.pm'} = __FILE__;

  package LangerthaX::Engine::TestProbeOpenRouter;
  use Moose;
  extends 'Langertha::Engine::OpenRouter';
  sub list_models { [] }
  __PACKAGE__->meta->make_immutable;
  $INC{'LangerthaX/Engine/TestProbeOpenRouter.pm'} = __FILE__;

  # No model metadata endpoint in core: probing it would answer {} anyway.
  package LangerthaX::Engine::TestProbeOpenAI;
  use Moose;
  extends 'Langertha::Engine::OpenAI';
  sub list_models { [] }
  __PACKAGE__->meta->make_immutable;
  $INC{'LangerthaX/Engine/TestProbeOpenAI.pm'} = __FILE__;

  # What Knarr sees on Langertha 0.503: no probe_model_capabilities_f.
  package LangerthaX::Engine::TestProbeOldCore;
  use Moose;
  extends 'Langertha::Engine::Ollama';
  sub list_models { [] }
  sub can {
    my ($self, $method) = @_;
    return undef if $method eq 'probe_model_capabilities_f';
    return $self->SUPER::can($method);
  }
  __PACKAGE__->meta->make_immutable;
  $INC{'LangerthaX/Engine/TestProbeOldCore.pm'} = __FILE__;
}

use HTTP::Request;
use HTTP::Response;
use IO::Async::Loop;
use Net::Async::HTTP;
use Net::Async::HTTP::Server;
use JSON::MaybeXS;
use Time::HiRes qw( time );

use Langertha::Knarr;
use Langertha::Knarr::Config;
use Langertha::Knarr::Router;
use Langertha::Knarr::Handler::Router;

my $core_probe  = Langertha::Engine::Ollama->can('probe_model_capabilities_f') ? 1 : 0;
my $core_vision = eval { require Langertha::Role::ImageInput; 1 } ? 1 : 0;
my $core_manifest = eval { require Langertha::Manifest::Builder; 1 } ? 1 : 0;
note $core_probe ? 'core can probe' : 'core has no probe (0.503): only the gate is tested';

my $json = JSON::MaybeXS->new( utf8 => 1, canonical => 1 );
my $loop = IO::Async::Loop->new;

# --- Upstream: Ollama /api/show per model, OpenRouter's /models document.
#     A /broken prefix answers 500, a /slow prefix never answers.
my ( @requests, @held );
my %ollama_caps = (
  'llava'     => [qw( completion vision )],
  'llama3'    => [qw( completion tools )],
  'extra-vis' => [qw( completion vision )],
);
my $upstream = Net::Async::HTTP::Server->new(
  on_request => sub {
    my ($srv, $req) = @_;
    my $body = $req->body // '';
    push @requests, { method => $req->method, path => $req->path, body => $body };
    my $respond = sub {
      my ($code, $data) = @_;
      my $resp = HTTP::Response->new($code);
      $resp->protocol('HTTP/1.1');
      $resp->header( 'Content-Type' => 'application/json' );
      my $content = $json->encode($data);
      $resp->header( 'Content-Length' => length $content );
      $resp->content($content);
      $req->respond($resp);
    };
    my $path = $req->path;
    if ( $path =~ m{\A/slow/} ) { push @held, $req; return }
    return $respond->( 500, { error => 'metadata backend down' } ) if $path =~ m{\A/broken/};
    if ( $path eq '/api/show' ) {
      my $model = eval { $json->decode($body)->{model} } // '';
      return $respond->( 404, { error => "model '$model' not found" } )
        unless $ollama_caps{$model};
      return $respond->( 200, { capabilities => $ollama_caps{$model} } );
    }
    if ( $path eq '/api/v1/models' ) {
      return $respond->( 200, { data => [
        { id => 'vendor/vis', architecture => { input_modalities => [qw( text image )] } },
        { id => 'vendor/txt', architecture => { input_modalities => [qw( text )] } },
      ] } );
    }
    return $respond->( 404, { error => "no route $path" } );
  },
);
$loop->add($upstream);
$upstream->listen( addr => { family => 'inet', socktype => 'stream', ip => '127.0.0.1', port => 0 } )->get;
my $up = 'http://127.0.0.1:' . $upstream->read_handle->sockport;

my $client = Net::Async::HTTP->new( max_connections_per_host => 0 );
$loop->add($client);

sub knarr_for {
  my (%data) = @_;
  my $config = Langertha::Knarr::Config->new( data => { upstream_timeout => 5, %data } );
  my $router = Langertha::Knarr::Router->new( config => $config );
  my $knarr  = Langertha::Knarr->new(
    handler => Langertha::Knarr::Handler::Router->new( router => $router ),
    loop    => $loop,
    listen  => [ '127.0.0.1:0' ],
    router  => $router,
  );
  return ( $knarr, $router );
}

sub show {
  my ($knarr, $model) = @_;
  my $port = $knarr->_server->read_handle->sockport;
  my $resp = $client->do_request( request => HTTP::Request->new(
    POST => "http://127.0.0.1:$port/api/show", [ 'Content-Type' => 'application/json' ],
    $json->encode({ model => $model }) ), timeout => 10 )->get;
  is $resp->code, 200, "/api/show $model: 200";
  return { map { $_ => 1 } @{ $json->decode( $resp->content )->{capabilities} } };
}

sub image_input_in_manifest {
  my ($knarr, $id) = @_;
  my ($status, $body) = $knarr->manifest_response( host => 'knarr.test' );
  is $status, 200, "manifest for $id: 200";
  my ($entry) = grep { $_->{id} eq $id && $_->{endpoint_ref} eq 'ollama' }
    @{ $json->decode($body)->{models} };
  ok $entry, "manifest lists $id on the ollama endpoint";
  return $entry && $entry->{capabilities}{image_input} ? 1 : 0;
}

sub probe_paths { [ sort map { $_->{path} } @requests ] }

# --- Gate: no probe on a core without it, none on engines without metadata,
#     none when probe_capabilities is off. Runs on every core.
subtest 'no probe request without a probing core, engine or opt-in' => sub {
  @requests = ();
  my ($knarr) = knarr_for(
    auto_discover => 1,
    models => {
      'old-core' => { engine => 'TestProbeOldCore', model => 'llava', url => $up },
      'gpt'      => { engine => 'TestProbeOpenAI', model => 'gpt-5.6', api_key => 'sk-test', url => "$up/v1" },
    },
  );
  $knarr->start;
  is $knarr->_capability_probe->get, 0, 'start ran the probe step: nothing to probe';
  is \@requests, [], 'no request reached the upstream';
  ok !show( $knarr, 'old-core' )->{vision}, 'old core: no vision claimed';

  @requests = ();
  my ($off) = knarr_for(
    probe_capabilities => 0,
    models => { 'llava' => { engine => 'TestProbeOllama', model => 'llava', url => $up } },
  );
  $off->start;
  is $off->_capability_probe->get, 0, 'probe_capabilities: 0 probes nothing';
  is \@requests, [], 'probe_capabilities: 0 sends no request';
  ok !show( $off, 'llava' )->{vision}, 'probe_capabilities: 0: static answer, no vision';

  unless ($core_probe) {
    @requests = ();
    my ($real) = knarr_for(
      models => { 'llava' => { engine => 'Ollama', model => 'llava', url => $up } } );
    $real->start;
    is $real->_capability_probe->get, 0, 'installed core without probe: nothing probed';
    is \@requests, [], 'installed core without probe: no request';
  }
};

unless ( $core_probe && $core_vision ) {
  done_testing;
  exit;
}

subtest 'startup probe teaches /api/show and the manifest' => sub {
  @requests = ();
  my ($knarr, $router) = knarr_for(
    auto_discover => 1,
    probe_timeout => 0.5,
    models => {
      'llava'     => { engine => 'TestProbeOllama', model => 'llava', url => $up },
      'llama'     => { engine => 'TestProbeOllama', model => 'llama3', url => $up },
      'gone'      => { engine => 'TestProbeOllama', model => 'gone-model', url => $up },
      'broken'    => { engine => 'TestProbeOllama', model => 'llava', url => "$up/broken" },
      'slow'      => { engine => 'TestProbeOllama', model => 'llava', url => "$up/slow" },
      'or-vision' => { engine => 'TestProbeOpenRouter', model => 'vendor/vis',
                       url => "$up/api/v1", api_key => 'sk-test' },
      'or-text'   => { engine => 'TestProbeOpenRouter', model => 'vendor/txt',
                       url => "$up/api/v1", api_key => 'sk-test' },
      'gpt'       => { engine => 'TestProbeOpenAI', model => 'gpt-5.6', api_key => 'sk-test', url => "$up/v1" },
    },
  );

  # Before the probe: the static tables say no, and the manifest caches that.
  ok !( $router->resolve('llava') )[0]->supports('image_input'), 'before the probe: no image_input';
  ok !image_input_in_manifest( $knarr, 'llava' ), 'before the probe: manifest without image_input'
    if $core_manifest;

  $knarr->start;
  my $start = time;
  my $probed = $knarr->_capability_probe->get;
  my $took = time - $start;
  # llava, llama3 (= discovered llama3, same instance), gone, broken, slow,
  # extra-vis (discovered), or-vision, or-text; gpt has no metadata.
  is $probed, 8, 'every routed instance with metadata was probed once';
  ok $took < 4, sprintf( 'a hanging probe is given up after probe_timeout (%.1fs)', $took );

  is [ sort map { $json->decode( $_->{body} )->{model} } grep { $_->{path} =~ m{/api/show\z} } @requests ],
    [qw( extra-vis gone-model llama3 llava llava llava )],
    'Ollama: one /api/show per instance, for its own model';
  is scalar( grep { $_->{path} eq '/api/v1/models' } @requests ), 2,
    'OpenRouter: one metadata fetch per instance';
  ok !( grep { $_->{path} =~ m{\A/v1/} } @requests ), 'no request for the engine without metadata';

  # The very instance the router hands out learned it.
  my ($llava) = $router->resolve('llava');
  is $llava->learned_model_capabilities, { llava => { image_input => 1 } },
    'the cached instance holds the learned fact';

  ok show( $knarr, 'llava' )->{vision},       'vision model on Ollama: vision';
  ok !show( $knarr, 'llama' )->{vision},      'text model on Ollama: no vision';
  ok show( $knarr, 'extra-vis' )->{vision},   'discovered vision model: vision';
  ok !show( $knarr, 'gone' )->{vision},       'model the server does not know: no vision';
  ok !show( $knarr, 'broken' )->{vision},     'failed probe: no vision, no crash';
  ok !show( $knarr, 'slow' )->{vision},       'timed-out probe: no vision, no crash';
  ok show( $knarr, 'or-vision' )->{vision},   'gateway vision model: vision';
  ok !show( $knarr, 'or-text' )->{vision},    'gateway text model: no vision';
  my ($gpt) = $router->resolve('gpt');
  is $gpt->learned_model_capabilities, {}, 'engine without metadata learned nothing';
  is !!show( $knarr, 'gpt' )->{vision}, !!$gpt->supports('image_input'),
    'engine without metadata keeps its static answer';

  if ($core_manifest) {
    ok image_input_in_manifest( $knarr, 'llava' ),   'manifest publishes image_input after the probe';
    ok image_input_in_manifest( $knarr, 'or-vision' ), 'manifest: gateway vision model';
    ok !image_input_in_manifest( $knarr, 'llama' ),  'manifest: text model without image_input';
    ok !image_input_in_manifest( $knarr, 'broken' ), 'manifest: failed probe claims nothing';
  }

  # No retry storm: a second pass asks nobody again, failed ones included.
  my $before = @requests;
  is $router->probe_capabilities_f( loop => $loop )->get, 0, 'second pass: nothing new to probe';
  is scalar(@requests), $before, 'second pass: no request';
};

done_testing;
