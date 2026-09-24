#!/usr/bin/perl

use Modern::Perl;

use Test::More tests => 2;

use File::Temp qw(tempdir);

use Koha::Database;
use t::lib::TestBuilder;

use Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

subtest '_test_job_transport reports success for a reachable local transport' => sub {
    plan tests => 2;

    $schema->storage->txn_begin;

    my $dir       = tempdir( CLEANUP => 1 );
    my $transport = $builder->build_object(
        {
            class => 'Koha::File::Transports',
            value => {
                transport => 'local', download_directory => $dir, upload_directory => $dir,
                host => '', port => 22, user_name => undef, password => undef, key_file => undef, passive => 1,
            },
        }
    );

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );
    my $result = $plugin->_test_job_transport( { file_transport_id => $transport->id } );

    ok( $result->{ok}, 'test_connection succeeded for a real, reachable local directory' );
    ok( !exists $result->{error}, 'no error key on success' );

    $schema->storage->txn_rollback;
};

subtest '_test_job_transport reports failure for an unknown file_transport_id' => sub {
    plan tests => 2;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );
    my $result = $plugin->_test_job_transport( { file_transport_id => 999999 } );

    is( $result->{ok}, 0, 'result is not ok for a nonexistent transport id' );
    like( $result->{error}, qr/No such file_transport_id/, 'error message names the problem' );

    $schema->storage->txn_rollback;
};
