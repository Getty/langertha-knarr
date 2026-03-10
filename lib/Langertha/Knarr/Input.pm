package Langertha::Knarr::Input;
our $VERSION = '0.006';
# ABSTRACT: Primary input normalization API for Knarr
use strict;
use warnings;
use Langertha::Input;

sub normalize_tools {
  shift;
  return Langertha::Input->normalize_tools(@_);
}

sub to_openai_tools {
  shift;
  return Langertha::Input->to_openai_tools(@_);
}

sub to_anthropic_tools {
  shift;
  return Langertha::Input->to_anthropic_tools(@_);
}

sub normalize_tool_choice {
  shift;
  return Langertha::Input->normalize_tool_choice(@_);
}

sub to_openai_tool_choice {
  shift;
  return Langertha::Input->to_openai_tool_choice(@_);
}

sub to_anthropic_tool_choice {
  shift;
  return Langertha::Input->to_anthropic_tool_choice(@_);
}

1;
