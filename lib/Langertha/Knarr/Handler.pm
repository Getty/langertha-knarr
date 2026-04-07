package Langertha::Knarr::Handler;
# ABSTRACT: Role for Steerboard backend handlers (Raider, Engine, Code, ...)
our $VERSION = "0.008";
use Moose::Role;
use Future::AsyncAwait;
use Langertha::Knarr::Stream;

requires 'handle_chat_f';
requires 'list_models';

# Default streaming = run handle_chat_f and emit one chunk.
# Handlers that natively stream should override.
async sub handle_stream_f {
  my ($self, $session, $request) = @_;
  my $r = await $self->handle_chat_f($session, $request);
  my $content = ref $r eq 'HASH' ? ($r->{content} // '') : "$r";
  return Langertha::Knarr::Stream->from_list($content);
}

# Optional capability hooks — handlers may override.
sub handle_embedding_f {
  my ($self) = @_;
  die "embedding not supported by " . ref($self) . "\n";
}

sub handle_transcription_f {
  my ($self) = @_;
  die "transcription not supported by " . ref($self) . "\n";
}

# Returns the sub-handler responsible for a given model id, or self.
sub route_model { return $_[0] }

1;
