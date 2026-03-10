package Langertha::Knarr::Output;
our $VERSION = '0.005';
# ABSTRACT: Primary output normalization API for Knarr
use strict;
use warnings;
use Langertha::Output;

sub extract_from_raw {
  shift;
  return Langertha::Output->extract_from_raw(@_);
}

sub parse_hermes_calls_from_text {
  shift;
  return Langertha::Output->parse_hermes_calls_from_text(@_);
}

sub to_openai_tool_calls {
  shift;
  return Langertha::Output->to_openai_tool_calls(@_);
}

sub to_anthropic_tool_use_blocks {
  shift;
  return Langertha::Output->to_anthropic_tool_use_blocks(@_);
}

sub to_ollama_tool_calls {
  shift;
  return Langertha::Output->to_ollama_tool_calls(@_);
}

1;
