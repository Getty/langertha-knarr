use strict;
use warnings;
use Test2::V0;
use Path::Tiny;
use YAML::PP;

# k75: knarr start --ram-only (and KNARR_RAM_ONLY) starts without a config
# file and without models, with the admin routes on; an admin key forces one
# worker; the banner never shows a key. Knarr::run is replaced, so nothing
# listens, and exit is turned into a die to see the refusals.

BEGIN { delete @ENV{qw( KNARR_API_KEY KNARR_ADMIN_KEY KNARR_RAM_ONLY KNARR_WORKERS KNARR_LOG_FILE KNARR_LOG_DIR )} }
BEGIN { *CORE::GLOBAL::exit = sub { die "EXIT $_[0]\n" } }

BEGIN {
  eval { require Capture::Tiny; 1 } or plan skip_all => 'Capture::Tiny required';
}
use Capture::Tiny qw( capture );
use Langertha::Knarr;
use Langertha::Knarr::CLI::Cmd::Start;

my $ADMIN = 'admin-key-start-0123456789';
my $tmp = Path::Tiny->tempdir;

{
  package MockMain;
  sub new { bless { config => $_[1], verbose => 0 }, $_[0] }
  sub config  { $_[0]->{config} }
  sub verbose { $_[0]->{verbose} }
}

my $ran;
{
  no warnings 'redefine';
  *Langertha::Knarr::run = sub { $ran = $_[0]; return };
}

sub start {
  my ( $file, %opt ) = @_;
  undef $ran;
  my $cmd = Langertha::Knarr::CLI::Cmd::Start->new( port => [ 0 ], %opt );
  my ( $out, $err, $died ) = capture {
    my $ok = eval { $cmd->execute( [], [ MockMain->new($file) ] ); 1 };
    $ok ? '' : $@;
  };
  return ( $err, $died );
}

my $missing = $tmp->child('none.yaml')->stringify;

# --- --ram-only without a file ---
{
  local $ENV{KNARR_ADMIN_KEY} = $ADMIN;
  my ( $err, $died ) = start( $missing, ram_only => 1 );
  is( $died, '', 'knarr start --ram-only starts without a config file' );
  ok( $ran, '... and runs a Knarr' );
  ok( $ran->admin, '... with the admin routes' );
  ok( !$ran->admin->configured, '... and no setup' );
  ok( $ran->admin->ram_only, '... RAM only' );
  like( $err, qr/Config: RAM only, no config file/, 'the banner says RAM only' );
  like( $err, qr/Admin routes: enabled/, '... and that the admin routes are on' );
  unlike( $err, qr/\Q$ADMIN\E/, '... never the key' );
}

# --- KNARR_RAM_ONLY wins over --from-env (the Docker default) ---
{
  local $ENV{KNARR_ADMIN_KEY} = $ADMIN;
  local $ENV{KNARR_RAM_ONLY}  = 1;
  local $ENV{OPENAI_API_KEY}  = 'sk-from-env-not-used-0001';
  my ( $err, $died ) = start( $missing, from_env => 1 );
  is( $died, '', 'KNARR_RAM_ONLY with --from-env starts' );
  like( $err, qr/--from-env ignored/, '... saying --from-env is ignored' );
  is( $ran->router->config->models, {}, '... with no models from the environment' );
  unlike( $err, qr/sk-from-env-not-used/, '... and no key in the banner' );
}

# --- No admin key, no RAM only ---
{
  my ( $err, $died ) = start( $missing, ram_only => 1 );
  is( $died, "EXIT 1\n", 'RAM only without an admin key: refused' );
  like( $err, qr/ram_only needs an admin_key/, '... saying why' );
  ok( !$ran, '... before anything runs' );
}

# --- An admin key forces one worker ---
{
  local $ENV{KNARR_ADMIN_KEY} = $ADMIN;
  my $file = $tmp->child('w.yaml');
  $file->spew_utf8( YAML::PP->new->dump_string({ models => { m => { engine => 'OpenAI', api_key => 'sk-file-key-000001' } } }) );
  my ( $err, $died ) = start( "$file", workers => 3 );
  is( $died, '', 'a config file with an admin key and -w 3 starts' );
  is( $ran->workers, 1, '... with one worker' );
  like( $err, qr/workers forced to 1 \(was 3\)/, '... saying so' );
  ok( $ran->admin->configured, '... configured from the file' );
  is( $ran->admin->source, 'file', '... source file' );
  unlike( $err, qr/\Q$ADMIN\E|sk-file-key/, 'no key in the banner' );
}

# --- A RAM-only config file must not carry the setup ---
{
  local $ENV{KNARR_ADMIN_KEY} = $ADMIN;
  my $file = $tmp->child('r.yaml');
  $file->spew_utf8( YAML::PP->new->dump_string({ ram_only => 1, models => { m => { engine => 'OpenAI', api_key => 'sk-file-key-000002' } } }) );
  my ( $err, $died ) = start("$file");
  is( $died, "EXIT 1\n", 'ram_only with models in the file: refused' );
  like( $err, qr/ram_only: models must not be in the config file/, '... saying why' );
  unlike( $err, qr/sk-file-key/, '... without the key' );
}

# --- --from-env: the admin key is still checked ---
{
  local $ENV{KNARR_ADMIN_KEY} = 'too-short';
  my ( $err, $died ) = start( $missing, from_env => 1 );
  is( $died, "EXIT 1\n", '--from-env with a short admin key: refused' );
  like( $err, qr/admin_key must be at least 16 characters/, '... saying why' );
  unlike( $err, qr/too-short/, '... without the key' );
}

# --- Without an admin key: no admin routes, workers as asked ---
{
  my $file = $tmp->child('p.yaml');
  $file->spew_utf8( YAML::PP->new->dump_string({ models => { m => { engine => 'OpenAI', api_key => 'sk-file-key-000003' } } }) );
  my ( $err, $died ) = start( "$file", workers => 2 );
  is( $died, '', 'no admin key: starts' );
  ok( !$ran->admin, '... without admin routes' );
  is( $ran->workers, 2, '... with the workers asked for' );
  like( $err, qr/Admin routes: off/, '... and says so' );
}

done_testing;
