
requires 'Langertha', '0.310';
requires 'Moose';
requires 'MooseX::Role::Parameterized';
requires 'Moo';
requires 'MooX::Cmd';
requires 'MooX::Options';
requires 'Future';
requires 'Future::AsyncAwait', '>= 0.66';
requires 'IO::Async', '>= 0.802';
requires 'Net::Async::HTTP::Server';
requires 'Net::Async::HTTP';
requires 'YAML::PP';
requires 'JSON::MaybeXS';
requires 'HTTP::Message';
requires 'HTTP::Request';
requires 'HTTP::Response';
requires 'Data::UUID';
requires 'Module::Runtime';
requires 'Log::Any';
requires 'Time::HiRes';
requires 'Try::Tiny';
requires 'MIME::Base64';
requires 'File::ShareDir::ProjectDistDir';

recommends 'Plack';
recommends 'HTTP::Message::PSGI';

on test => sub {
  requires 'Test2::Suite';
  requires 'MooX::Cmd::Tester';
};
