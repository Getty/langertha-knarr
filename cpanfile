
requires 'Data::UUID';
requires 'Digest::SHA';
requires 'Future';
requires 'Future::AsyncAwait', '0.66';
requires 'HTTP::Request';
requires 'HTTP::Response';
requires 'IO::Async', '0.802';
requires 'IO::Async::SSL';
requires 'JSON::MaybeXS';
requires 'Langertha', '0.504';
requires 'Log::Any';
requires 'MIME::Base64';
requires 'Module::Runtime';
requires 'Moo';
requires 'Moose';
requires 'MooX::Cmd';
requires 'MooX::Options';
requires 'Net::Async::HTTP';
requires 'Net::Async::HTTP::Server';
requires 'Storable';
requires 'Time::HiRes';
requires 'Try::Tiny';
requires 'URI';
requires 'YAML::PP';
recommends 'DBD::Pg';
recommends 'DBI';
recommends 'HTTP::Message::PSGI';
recommends 'Plack';

on test => sub {
  requires 'Capture::Tiny';
  requires 'Path::Tiny';
  requires 'Test2::Suite';
};
