package Langertha::Knarr::CLI;
# ABSTRACT: CLI entry point for Knarr LLM Proxy
use Moo;
use MooX::Cmd;
use MooX::Options protect_argv => 0;

our $VERSION = '0.002';

option config => (
  is      => 'ro',
  format  => 's',
  short   => 'c',
  doc     => 'Config file path (default: ./knarr.yaml)',
  default => sub { './knarr.yaml' },
);

option verbose => (
  is      => 'ro',
  short   => 'v',
  doc     => 'Enable verbose logging',
  default => 0,
  negativable => 1,
);

sub execute {
  my ($self) = @_;
  print _banner();
  print "\n";
  print "USAGE\n";
  print "  knarr <command> [options]\n\n";
  print "COMMANDS\n";
  print "  start       Start the proxy server (requires config file)\n";
  print "  container   Auto-start from environment variables (Docker mode)\n";
  print "  init        Scan environment and generate configuration\n";
  print "  models      List configured models and their backends\n";
  print "  check       Validate configuration file\n\n";
  print "GLOBAL OPTIONS\n";
  print "  -c, --config <path>   Config file (default: ./knarr.yaml)\n";
  print "  -v, --verbose         Enable verbose logging\n\n";
  print "QUICK START (Docker)\n";
  print "  docker run -e OPENAI_API_KEY=sk-... -p 8080:8080 raudssus/langertha-knarr\n\n";
  print "QUICK START (Local)\n";
  print "  knarr init > knarr.yaml\n";
  print "  knarr start\n\n";
  print "EXAMPLES\n";
  print "  knarr start                              # Start with ./knarr.yaml\n";
  print "  knarr start -c production.yaml -p 9090   # Custom config and port\n";
  print "  knarr container                           # Auto-detect from ENV\n";
  print "  knarr init > knarr.yaml                   # Generate config\n";
  print "  knarr models                              # List configured models\n";
  print "  knarr check                               # Validate config\n\n";
  print "ENVIRONMENT\n";
  print "  OPENAI_API_KEY        OpenAI API key\n";
  print "  ANTHROPIC_API_KEY     Anthropic API key\n";
  print "  LANGFUSE_PUBLIC_KEY   Langfuse public key (enables tracing)\n";
  print "  LANGFUSE_SECRET_KEY   Langfuse secret key\n";
  print "  LANGFUSE_URL          Langfuse URL (default: https://cloud.langfuse.com)\n";
  print "  KNARR_API_KEY         Proxy authentication key (optional)\n\n";
  print "Version $VERSION | https://github.com/Getty/langertha-knarr\n";
}

sub _banner {
  return <<'BANNER';
         .  *  .
        . _/|_ .          KNARR
     .  /|    |\ .        Langertha LLM Proxy
   ~~~~~|______|~~~~~
   ~~ ~~~~~~~~~~~~~ ~~    Cargo transport for your LLM calls
   ~~~~~~~~~~~~~~~~~~~~
BANNER
}

1;
