package Langertha::Knarr;
our $VERSION = '0.002';
# ABSTRACT: LLM Proxy with Langfuse Tracing
use strict;
use warnings;
use Mojolicious::Lite -signatures;
use Mojo::URL;
use JSON::MaybeXS qw( decode_json encode_json );
use Log::Any qw( $log );
use Langertha::Knarr::Config;
use Langertha::Knarr::Router;
use Langertha::Knarr::Tracing;
use Langertha::Knarr::Proxy::OpenAI;
use Langertha::Knarr::Proxy::Anthropic;
use Langertha::Knarr::Proxy::Ollama;

sub build_app {
  my ( $class, %opts ) = @_;
  my $config_obj = $opts{config}
    || Langertha::Knarr::Config->new(file => $opts{config_file});
  my $router = Langertha::Knarr::Router->new(config => $config_obj);
  my $tracing = Langertha::Knarr::Tracing->new(config => $config_obj);

  my $app = Mojolicious->new;
  $app->secrets(['knarr-llm-proxy']);

  # Configure user agent for passthrough proxying
  $app->ua->connect_timeout(10);
  $app->ua->request_timeout(300);

  # Store objects in app helper
  $app->helper(knarr_config  => sub { $config_obj });
  $app->helper(knarr_router  => sub { $router });
  $app->helper(knarr_tracing => sub { $tracing });

  # Auth middleware
  if ($config_obj->has_proxy_api_key) {
    $app->hook(before_dispatch => sub ($c) {
      my $path = $c->req->url->path->to_string;
      return if $path eq '/health';
      my $auth = $c->req->headers->header('Authorization')
              // $c->req->headers->header('x-api-key')
              // '';
      my $key = $config_obj->proxy_api_key;
      $auth =~ s/^Bearer\s+//i;
      unless ($auth eq $key) {
        $c->render(json => { error => { message => 'Invalid API key', type => 'authentication_error' } }, status => 401);
        return $c->rendered;
      }
    });
  }

  # Health check
  $app->routes->get('/health' => sub ($c) {
    $c->render(json => { status => 'ok', proxy => 'knarr' });
  });

  # --- OpenAI format routes ---
  $app->routes->post('/v1/chat/completions' => sub ($c) {
    _handle_request($c, 'Langertha::Knarr::Proxy::OpenAI', 'chat');
  });

  $app->routes->get('/v1/models' => sub ($c) {
    _handle_models_request($c, 'Langertha::Knarr::Proxy::OpenAI');
  });

  $app->routes->post('/v1/embeddings' => sub ($c) {
    _handle_request($c, 'Langertha::Knarr::Proxy::OpenAI', 'embedding');
  });

  # --- Anthropic format routes ---
  $app->routes->post('/v1/messages' => sub ($c) {
    _handle_request($c, 'Langertha::Knarr::Proxy::Anthropic', 'chat');
  });

  # --- Ollama format routes ---
  $app->routes->post('/api/chat' => sub ($c) {
    _handle_request($c, 'Langertha::Knarr::Proxy::Ollama', 'chat');
  });

  $app->routes->get('/api/tags' => sub ($c) {
    _handle_models_request($c, 'Langertha::Knarr::Proxy::Ollama');
  });

  $app->routes->get('/api/ps' => sub ($c) {
    $c->render(json => { models => [] });
  });

  return $app;
}

sub _handle_request ($c, $proxy_class, $type) {
  my $router  = $c->knarr_router;
  my $tracing = $c->knarr_tracing;
  my $body    = $c->req->json;

  unless ($body) {
    $c->render(json => { error => { message => 'Invalid JSON body', type => 'invalid_request_error' } }, status => 400);
    return;
  }

  my $model_name = $proxy_class->extract_model($body);
  my $stream     = $proxy_class->extract_stream($body);
  my $messages   = $proxy_class->extract_messages($body);
  my $params     = $proxy_class->extract_params($body);

  # 1. Try explicit config / discovered models first
  my ($engine, $resolved_model) = eval { $router->resolve($model_name, skip_default => 1) };

  if ($engine) {
    _route_to_engine($c, $proxy_class, $engine, $resolved_model, $messages, $params, $stream, $tracing, $type);
    return;
  }

  # 2. Try passthrough (before default engine — passthrough uses client's own API key)
  my $pt_format = $proxy_class->passthrough_format;
  my $upstream   = $pt_format ? $c->knarr_config->passthrough_url_for($pt_format) : undef;

  if ($upstream) {
    my $trace_id = $tracing->start_trace(
      model    => $model_name,
      engine   => "passthrough:$pt_format",
      messages => $messages,
      params   => $params,
      format   => $proxy_class->format_name,
    );
    _handle_passthrough($c, $proxy_class, $upstream, $body, $model_name, $tracing, $trace_id);
    return;
  }

  # 3. Try default engine as last resort
  ($engine, $resolved_model) = eval { $router->resolve($model_name) };

  if ($engine) {
    _route_to_engine($c, $proxy_class, $engine, $resolved_model, $messages, $params, $stream, $tracing, $type);
    return;
  }

  my $err = $@ || "Model '$model_name' not configured and passthrough disabled";
  $c->render(json => $proxy_class->format_error($err, 'model_not_found'), status => 404);
}

sub _route_to_engine ($c, $proxy_class, $engine, $resolved_model, $messages, $params, $stream, $tracing, $type) {
  my $trace_id = $tracing->start_trace(
    model    => $resolved_model,
    engine   => ref($engine),
    messages => $messages,
    params   => $params,
    format   => $proxy_class->format_name,
  );

  if ($stream) {
    _handle_streaming($c, $proxy_class, $engine, $messages, $params, $resolved_model, $tracing, $trace_id);
  } else {
    _handle_sync($c, $proxy_class, $engine, $messages, $params, $resolved_model, $tracing, $trace_id, $type);
  }
}

sub _handle_sync ($c, $proxy_class, $engine, $messages, $params, $model, $tracing, $trace_id, $type) {
  my $result = eval {
    if ($type eq 'embedding') {
      my $input = $params->{input};
      $engine->simple_embedding($input);
    } else {
      my @chat_messages = map { ref $_ ? $_ : { role => 'user', content => $_ } } @$messages;
      $engine->simple_chat(@chat_messages);
    }
  };

  if ($@) {
    $log->errorf("Engine error: %s", $@);
    $tracing->end_trace($trace_id, error => "$@");
    $c->render(json => $proxy_class->format_error("$@", 'server_error'), status => 500);
    return;
  }

  my $response_data = $proxy_class->format_response($result, $model);

  $tracing->end_trace($trace_id,
    output => "$result",
    model  => $model,
    usage  => (ref $result && $result->isa('Langertha::Response') && $result->has_usage)
      ? { input => $result->prompt_tokens, output => $result->completion_tokens, total => $result->total_tokens }
      : undef,
  );

  $c->render(json => $response_data);
}

sub _handle_streaming ($c, $proxy_class, $engine, $messages, $params, $model, $tracing, $trace_id) {
  $c->res->headers->content_type($proxy_class->streaming_content_type);
  $c->res->headers->cache_control('no-cache');
  $c->res->headers->header('Connection' => 'keep-alive');
  $c->res->headers->header('X-Accel-Buffering' => 'no');

  my $full_content = '';
  my $usage;

  my $write = $c->res->content->write_body_data('');
  $c->res->code(200);

  eval {
    my @chat_messages = map { ref $_ ? $_ : { role => 'user', content => $_ } } @$messages;
    $engine->simple_chat_stream(sub {
      my ($chunk) = @_;
      my $chunk_data = $proxy_class->format_stream_chunk($chunk, $model);
      $full_content .= $chunk->content;
      if ($chunk->can('usage') && $chunk->usage) {
        $usage = $chunk->usage;
      }
      for my $line (@$chunk_data) {
        $c->write_chunk($line);
      }
    }, @chat_messages);
  };

  if ($@) {
    $log->errorf("Streaming error: %s", $@);
    $tracing->end_trace($trace_id, error => "$@");
  } else {
    $tracing->end_trace($trace_id,
      output => $full_content,
      model  => $model,
      usage  => $usage,
    );
  }

  # Write stream end marker
  my $end_marker = $proxy_class->stream_end_marker;
  $c->write_chunk($end_marker) if $end_marker;
  $c->write_chunk('');
}

sub _handle_passthrough ($c, $proxy_class, $upstream_base, $body, $model_name, $tracing, $trace_id) {
  my $path  = $c->req->url->path->to_string;
  my $query = $c->req->url->query->to_string;
  my $url   = Mojo::URL->new("$upstream_base$path");
  $url->query($query) if $query;

  $log->infof("Passthrough: %s %s -> %s", $c->req->method, $path, $url);

  # Forward client headers (auth, content-type, etc.)
  # Strip encoding headers — proxy handles data uncompressed
  my %fwd_headers;
  for my $name (@{$c->req->headers->names}) {
    my $lc = lc($name);
    next if $lc eq 'host' || $lc eq 'content-length' || $lc eq 'transfer-encoding'
         || $lc eq 'accept-encoding';
    $fwd_headers{$name} = $c->req->headers->header($name);
  }

  $c->render_later;
  my $ua = $c->app->ua;

  my $tx = $ua->build_tx(
    $c->req->method => $url,
    \%fwd_headers,
    json => $body,
  );

  my $stream = $body->{stream};

  if ($stream) {
    # Streaming passthrough: pipe response chunks to client as they arrive
    my $full_response = '';
    my $headers_sent  = 0;

    $tx->res->content->unsubscribe('read')->on(read => sub {
      my ($content, $bytes) = @_;

      unless ($headers_sent) {
        $c->res->code($tx->res->code // 200);
        for my $name (@{$tx->res->headers->names}) {
          my $lc = lc($name);
          next if $lc eq 'content-length' || $lc eq 'transfer-encoding'
               || $lc eq 'content-encoding';
          $c->res->headers->header($name => $tx->res->headers->header($name));
        }
        $c->res->headers->header('X-Accel-Buffering' => 'no');
        $headers_sent = 1;
      }

      $full_response .= $bytes;
      $c->write($bytes);
    });

    $ua->start($tx => sub {
      my ($ua, $tx) = @_;

      if (my $err = $tx->error) {
        unless ($headers_sent) {
          $tracing->end_trace($trace_id, error => $err->{message}) if $trace_id;
          $c->render(json => $proxy_class->format_error(
            "Upstream error: " . ($err->{message} // 'unknown'), 'upstream_error',
          ), status => 502);
          return;
        }
      }

      $c->finish;
      if ($trace_id) {
        $tracing->end_trace($trace_id,
          output => $full_response,
          model  => $model_name,
        );
      }
    });
  } else {
    # Non-streaming passthrough: wait for full response, forward it
    $ua->start($tx => sub {
      my ($ua, $tx) = @_;

      if (my $err = $tx->error) {
        $tracing->end_trace($trace_id, error => $err->{message}) if $trace_id;
        $c->render(json => $proxy_class->format_error(
          "Upstream error: " . ($err->{message} // 'unknown'), 'upstream_error',
        ), status => $err->{code} // 502);
        return;
      }

      my $res = $tx->res;
      $c->res->code($res->code);
      for my $name (@{$res->headers->names}) {
        my $lc = lc($name);
        next if $lc eq 'content-length' || $lc eq 'transfer-encoding'
             || $lc eq 'content-encoding';
        $c->res->headers->header($name => $res->headers->header($name));
      }
      $c->res->body($res->body);
      $c->rendered;

      if ($trace_id) {
        my $output = eval { decode_json($res->body) };
        $tracing->end_trace($trace_id,
          output => $output // $res->body,
          model  => $model_name,
        );
      }
    });
  }
}

sub _handle_models_request ($c, $proxy_class) {
  my $router = $c->knarr_router;
  my $models = $router->list_models;
  $c->render(json => $proxy_class->format_models_response($models));
}

1;
