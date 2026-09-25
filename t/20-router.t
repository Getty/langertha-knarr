use strict;
use warnings;
use Test::More;
use File::Temp qw( tempfile );

BEGIN {
  package LangerthaX::Engine::TestKnarr;
  sub new { my ($class, %args) = @_; bless \%args, $class }
  sub simple_chat { return 'ok' }
  $INC{'LangerthaX/Engine/TestKnarr.pm'} = __FILE__;

  # Offline gateway stand-in for auto_discover: list_models without a network.
  package LangerthaX::Engine::TestKnarrGateway;
  sub new { my ($class, %args) = @_; bless \%args, $class }
  sub chat_model { $_[0]{model} }
  sub list_models { [ 'vendor-a/model-one', 'vendor-b/model-two' ] }
  $INC{'LangerthaX/Engine/TestKnarrGateway.pm'} = __FILE__;
}
use JSON::PP ();

use Langertha::Knarr::Config;
use Langertha::Knarr::Router;

# Test: resolve configured model
{
  my ($fh, $file) = tempfile(SUFFIX => '.yaml', UNLINK => 1);
  print $fh <<'YAML';
models:
  local-test:
    engine: OllamaOpenAI
    url: http://test.invalid:11434/v1
    model: llama3.2
YAML
  close $fh;

  my $config = Langertha::Knarr::Config->new(file => $file);
  my $router = Langertha::Knarr::Router->new(config => $config);

  my ($engine, $model) = $router->resolve('local-test');
  ok $engine, 'engine resolved';
  isa_ok $engine, 'Langertha::Engine::OllamaOpenAI';
  is $model, 'llama3.2', 'correct model name';
}

# Test: resolve with default engine
{
  my ($fh, $file) = tempfile(SUFFIX => '.yaml', UNLINK => 1);
  print $fh <<'YAML';
models: {}
default:
  engine: OllamaOpenAI
  url: http://test.invalid:11434/v1
YAML
  close $fh;

  my $config = Langertha::Knarr::Config->new(file => $file);
  my $router = Langertha::Knarr::Router->new(config => $config);

  my ($engine, $model) = $router->resolve('any-model');
  ok $engine, 'default engine resolved';
  isa_ok $engine, 'Langertha::Engine::OllamaOpenAI';
  is $model, 'any-model', 'model name passed through';
}

# Test: engine caching
{
  my ($fh, $file) = tempfile(SUFFIX => '.yaml', UNLINK => 1);
  print $fh <<'YAML';
models:
  test:
    engine: OllamaOpenAI
    url: http://test.invalid:11434/v1
    model: test
YAML
  close $fh;

  my $config = Langertha::Knarr::Config->new(file => $file);
  my $router = Langertha::Knarr::Router->new(config => $config);

  my ($engine1) = $router->resolve('test');
  my ($engine2) = $router->resolve('test');
  is "$engine1", "$engine2", 'same engine instance returned (cached)';
}

# Test: unknown model without default
{
  my ($fh, $file) = tempfile(SUFFIX => '.yaml', UNLINK => 1);
  print $fh <<'YAML';
models:
  known:
    engine: OllamaOpenAI
    url: http://test.invalid:11434/v1
YAML
  close $fh;

  my $config = Langertha::Knarr::Config->new(file => $file);
  my $router = Langertha::Knarr::Router->new(config => $config);

  eval { $router->resolve('unknown') };
  like $@, qr/not configured/, 'unknown model without default croaks';
}

# Test: list_models
{
  my ($fh, $file) = tempfile(SUFFIX => '.yaml', UNLINK => 1);
  print $fh <<'YAML';
models:
  model-a:
    engine: OllamaOpenAI
    url: http://test.invalid:11434/v1
    model: llama3.2
  model-b:
    engine: OllamaOpenAI
    url: http://test.invalid:11434/v1
    model: qwen2.5
YAML
  close $fh;

  my $config = Langertha::Knarr::Config->new(file => $file);
  my $router = Langertha::Knarr::Router->new(config => $config);

  my $models = $router->list_models;
  is scalar @$models, 2, 'two models listed';
  is $models->[0]{source}, 'configured', 'source is configured';
}

# Test: no model specified
{
  my $config = Langertha::Knarr::Config->new;
  my $router = Langertha::Knarr::Router->new(config => $config);

  eval { $router->resolve(undef) };
  like $@, qr/No model specified/, 'undef model croaks';

  eval { $router->resolve('') };
  like $@, qr/No model specified/, 'empty model croaks';
}

# Test: resolve custom LangerthaX engine
{
  my ($fh, $file) = tempfile(SUFFIX => '.yaml', UNLINK => 1);
  print $fh <<'YAML';
models:
  custom:
    engine: TestKnarr
    model: custom-model
YAML
  close $fh;

  my $config = Langertha::Knarr::Config->new(file => $file);
  my $router = Langertha::Knarr::Router->new(config => $config);

  my ($engine, $model) = $router->resolve('custom');
  ok $engine, 'custom engine resolved';
  isa_ok $engine, 'LangerthaX::Engine::TestKnarr';
  is $model, 'custom-model', 'custom model resolved';
}

# k20: the engine cache must be keyed per model. Two models on one
# engine/url/key must not share the first model's instance: chat_model is
# read-only, so a shared instance sends the first model upstream while
# Handler::Router relabels the answer with the requested one, and every
# model-scoped decision in core (capability corrections, exclusions,
# Reasoning::Profile) is evaluated for the wrong model.
{
  my ($fh, $file) = tempfile(SUFFIX => '.yaml', UNLINK => 1);
  print $fh <<'YAML';
models:
  model-a:
    engine: OllamaOpenAI
    url: http://test.invalid:11434/v1
    model: llama3.2
  model-b:
    engine: OllamaOpenAI
    url: http://test.invalid:11434/v1
    model: qwen2.5
YAML
  close $fh;

  my $config = Langertha::Knarr::Config->new(file => $file);
  my $router = Langertha::Knarr::Router->new(config => $config);

  my ($engine_a, $model_a) = $router->resolve('model-a');
  my ($engine_b, $model_b) = $router->resolve('model-b');
  is $model_a, 'llama3.2', 'model-a resolves to llama3.2';
  is $model_b, 'qwen2.5',  'model-b resolves to qwen2.5';
  isnt "$engine_a", "$engine_b", 'two models on one engine/url get two instances';
  is $engine_a->chat_model, 'llama3.2', 'model-a engine carries its own chat_model';
  is $engine_b->chat_model, 'qwen2.5',  'model-b engine carries its own chat_model';

  my %upstream;
  for my $pair ([a => $engine_a], [b => $engine_b]) {
    my $http = $pair->[1]->chat({ role => 'user', content => 'hi' });
    $upstream{$pair->[0]} = JSON::PP::decode_json($http->content)->{model};
  }
  is $upstream{a}, 'llama3.2', 'upstream request for model-a names llama3.2';
  is $upstream{b}, 'qwen2.5',  'upstream request for model-b names qwen2.5';

  my ($engine_a2) = $router->resolve('model-a');
  is "$engine_a2", "$engine_a", 'same model still reuses its cached instance';
}

# k20: default engine — every unconfigured model name gets its own instance.
{
  my ($fh, $file) = tempfile(SUFFIX => '.yaml', UNLINK => 1);
  print $fh <<'YAML';
models: {}
default:
  engine: OllamaOpenAI
  url: http://test.invalid:11434/v1
YAML
  close $fh;

  my $config = Langertha::Knarr::Config->new(file => $file);
  my $router = Langertha::Knarr::Router->new(config => $config);

  my ($engine_x) = $router->resolve('model-x');
  my ($engine_y) = $router->resolve('model-y');
  is $engine_x->chat_model, 'model-x', 'default engine for model-x uses model-x';
  is $engine_y->chat_model, 'model-y', 'default engine for model-y uses model-y';
}

# k20: auto_discover on a gateway — discovered slugs must not collapse onto
# the configured model's instance.
{
  my ($fh, $file) = tempfile(SUFFIX => '.yaml', UNLINK => 1);
  print $fh <<'YAML';
auto_discover: 1
models:
  gw:
    engine: TestKnarrGateway
    url: http://test.invalid/v1
    model: vendor-a/model-one
YAML
  close $fh;

  my $config = Langertha::Knarr::Config->new(file => $file);
  my $router = Langertha::Knarr::Router->new(config => $config);

  my ($engine_gw)  = $router->resolve('gw');
  my ($engine_one, $model_one) = $router->resolve('vendor-a/model-one');
  my ($engine_two, $model_two) = $router->resolve('vendor-b/model-two');
  is $model_two, 'vendor-b/model-two', 'discovered slug resolves to itself';
  is $engine_gw->chat_model,  'vendor-a/model-one', 'configured gateway model keeps its chat_model';
  is $engine_two->chat_model, 'vendor-b/model-two', 'discovered slug gets an engine with its own chat_model';
  isnt "$engine_two", "$engine_gw", 'discovered slug does not reuse the configured instance';
}

done_testing;
