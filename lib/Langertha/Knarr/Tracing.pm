package Langertha::Knarr::Tracing;
our $VERSION = '0.002';
# ABSTRACT: Automatic Langfuse tracing per proxy request
use Moo;
use Time::HiRes qw( gettimeofday );
use Carp qw( croak );
use JSON::MaybeXS ();
use MIME::Base64 qw( encode_base64 );
use Log::Any qw( $log );

has config => (
  is       => 'ro',
  required => 1,
);

has _enabled => (
  is      => 'lazy',
  builder => '_build__enabled',
);

sub _build__enabled {
  my ($self) = @_;
  my $lf = $self->config->langfuse;
  my $pub = $lf->{public_key} // _strip_quotes($ENV{LANGFUSE_PUBLIC_KEY});
  my $sec = $lf->{secret_key} // _strip_quotes($ENV{LANGFUSE_SECRET_KEY});
  return ($pub && $sec) ? 1 : 0;
}

has _public_key => (
  is      => 'lazy',
  builder => '_build__public_key',
);

sub _build__public_key {
  my ($self) = @_;
  return $self->config->langfuse->{public_key} // _strip_quotes($ENV{LANGFUSE_PUBLIC_KEY});
}

has _secret_key => (
  is      => 'lazy',
  builder => '_build__secret_key',
);

sub _build__secret_key {
  my ($self) = @_;
  return $self->config->langfuse->{secret_key} // _strip_quotes($ENV{LANGFUSE_SECRET_KEY});
}

has _url => (
  is      => 'lazy',
  builder => '_build__url',
);

has trace_name => (
  is      => 'lazy',
  builder => '_build_trace_name',
);

sub _build_trace_name {
  my ($self) = @_;
  return $self->config->langfuse->{trace_name}
    // _strip_quotes($ENV{LANGFUSE_TRACE_NAME})
    // _strip_quotes($ENV{KNARR_TRACE_NAME})
    // 'knarr-proxy';
}

sub _build__url {
  my ($self) = @_;
  return $self->config->langfuse->{url} // _strip_quotes($ENV{LANGFUSE_URL}) // _strip_quotes($ENV{LANGFUSE_BASE_URL}) // 'https://cloud.langfuse.com';
}

has _batch => (
  is      => 'rw',
  default => sub { [] },
);

has _json => (
  is      => 'lazy',
  builder => '_build__json',
);

# Strip surrounding quotes from env values (Docker --env-file includes them literally)
sub _strip_quotes {
  my $v = shift;
  return $v unless defined $v;
  $v =~ s/^["']|["']$//g;
  return $v;
}

sub _build__json {
  return JSON::MaybeXS->new(utf8 => 1, convert_blessed => 1);
}

sub _uuid {
  my @hex = map { sprintf("%04x", int(rand(65536))) } 1..8;
  return join('-',
    $hex[0].$hex[1],
    $hex[2],
    '4'.substr($hex[3], 1),
    sprintf("%x", 8 + int(rand(4))).substr($hex[4], 1),
    $hex[5].$hex[6].$hex[7],
  );
}

sub _timestamp {
  my ($s, $us) = gettimeofday;
  my @t = gmtime($s);
  return sprintf("%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
    $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0], int($us/1000));
}

sub start_trace {
  my ($self, %opts) = @_;
  return undef unless $self->_enabled;

  my $trace_id = _uuid();
  my $gen_id   = _uuid();
  my $now      = _timestamp();

  push @{$self->_batch}, {
    id        => _uuid(),
    type      => 'trace-create',
    timestamp => $now,
    body      => {
      id       => $trace_id,
      name     => $self->trace_name,
      input    => $opts{messages},
      metadata => {
        format  => $opts{format},
        engine  => $opts{engine},
        model   => $opts{model},
        params  => $opts{params},
      },
      tags => ['knarr'],
    },
  };

  push @{$self->_batch}, {
    id        => _uuid(),
    type      => 'generation-create',
    timestamp => $now,
    body      => {
      id        => $gen_id,
      traceId   => $trace_id,
      name      => 'proxy-request',
      model     => $opts{model},
      input     => $opts{messages},
      startTime => $now,
    },
  };

  return { trace_id => $trace_id, gen_id => $gen_id, start_time => $now };
}

sub end_trace {
  my ($self, $trace_info, %opts) = @_;
  return unless $self->_enabled;
  return unless $trace_info;

  my $now = _timestamp();

  if ($opts{error}) {
    push @{$self->_batch}, {
      id        => _uuid(),
      type      => 'generation-update',
      timestamp => $now,
      body      => {
        id            => $trace_info->{gen_id},
        endTime       => $now,
        level         => 'ERROR',
        statusMessage => $opts{error},
      },
    };
  } else {
    push @{$self->_batch}, {
      id        => _uuid(),
      type      => 'generation-update',
      timestamp => $now,
      body      => {
        id      => $trace_info->{gen_id},
        output  => $opts{output},
        endTime => $now,
        $opts{model} ? (model => $opts{model}) : (),
        $opts{usage} ? (usage => $opts{usage}) : (),
      },
    };
  }

  push @{$self->_batch}, {
    id        => _uuid(),
    type      => 'trace-create',
    timestamp => $now,
    body      => {
      id     => $trace_info->{trace_id},
      output => $opts{output} // $opts{error},
    },
  };

  $self->flush;
}

sub flush {
  my ($self) = @_;
  return unless $self->_enabled;
  my $batch = $self->_batch;
  return unless @$batch;

  eval {
    require LWP::UserAgent;
    my $ua = LWP::UserAgent->new(
      agent   => 'Langertha-Knarr/0.001',
      timeout => 5,
    );

    my $auth = encode_base64($self->_public_key . ':' . $self->_secret_key, '');
    my $body = $self->_json->encode({ batch => $batch });

    my $request = HTTP::Request->new(
      POST => $self->_url . '/api/public/ingestion',
      [
        'Content-Type'  => 'application/json',
        'Authorization' => 'Basic ' . $auth,
      ],
      $body,
    );

    my $response = $ua->request($request);
    unless ($response->is_success) {
      $log->warnf("Langfuse ingestion failed: %s", $response->status_line);
    }
  };
  if ($@) {
    $log->warnf("Langfuse flush error: %s", $@);
  }

  $self->_batch([]);
}

1;
