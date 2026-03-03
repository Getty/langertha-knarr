package Langertha::Knarr::Proxy::OpenAI;
our $VERSION = '0.002';
# ABSTRACT: OpenAI API format proxy handler
use strict;
use warnings;
use JSON::MaybeXS qw( encode_json );
use Time::HiRes qw( time );

sub format_name { 'openai' }

sub passthrough_format { 'openai' }

sub streaming_content_type { 'text/event-stream' }

sub extract_model {
  my ($class, $body) = @_;
  return $body->{model} // 'default';
}

sub extract_stream {
  my ($class, $body) = @_;
  return $body->{stream} ? 1 : 0;
}

sub extract_messages {
  my ($class, $body) = @_;
  return $body->{messages} // [];
}

sub extract_params {
  my ($class, $body) = @_;
  my %params;
  $params{temperature}  = $body->{temperature}  if defined $body->{temperature};
  $params{max_tokens}   = $body->{max_tokens}    if defined $body->{max_tokens};
  $params{top_p}        = $body->{top_p}         if defined $body->{top_p};
  $params{stream}       = $body->{stream}        if defined $body->{stream};
  $params{input}        = $body->{input}         if defined $body->{input};
  return \%params;
}

sub format_response {
  my ($class, $result, $model) = @_;
  my $content = "$result";
  my $id = 'chatcmpl-knarr-' . int(time * 1000);

  my %response = (
    id      => $id,
    object  => 'chat.completion',
    created => int(time),
    model   => $model,
    choices => [{
      index         => 0,
      message       => { role => 'assistant', content => $content },
      finish_reason => 'stop',
    }],
  );

  if (ref $result && $result->isa('Langertha::Response')) {
    if ($result->has_usage) {
      $response{usage} = {
        prompt_tokens     => $result->prompt_tokens,
        completion_tokens => $result->completion_tokens,
        total_tokens      => $result->total_tokens,
      };
    }
    $response{model} = $result->model if $result->has_model;
  }

  return \%response;
}

sub format_stream_chunk {
  my ($class, $chunk, $model) = @_;
  my $id = 'chatcmpl-knarr-' . int(time * 1000);

  my %data = (
    id      => $id,
    object  => 'chat.completion.chunk',
    created => int(time),
    model   => $model,
    choices => [{
      index => 0,
      delta => { content => $chunk->content },
      finish_reason => $chunk->is_final ? 'stop' : undef,
    }],
  );

  my $json = encode_json(\%data);
  return ["data: $json\n\n"];
}

sub stream_end_marker { "data: [DONE]\n\n" }

sub format_error {
  my ($class, $message, $type) = @_;
  return {
    error => {
      message => $message,
      type    => $type // 'server_error',
    },
  };
}

sub format_models_response {
  my ($class, $models) = @_;
  return {
    object => 'list',
    data   => [map {{
      id       => $_->{id},
      object   => 'model',
      created  => int(time),
      owned_by => 'knarr:' . ($_->{engine} // 'unknown'),
    }} @$models],
  };
}

1;
