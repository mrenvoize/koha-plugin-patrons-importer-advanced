#!/usr/bin/perl

use Modern::Perl;

use Test::More tests => 4;

use File::Temp qw(tempfile);

use Koha::Database;

use Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced;

my $schema = Koha::Database->new->schema;

subtest '_content_hash is deterministic and content-sensitive' => sub {
    plan tests => 2;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );

    my ( $fh1, $path1 ) = tempfile();
    print $fh1 "hello"; close $fh1;
    my ( $fh2, $path2 ) = tempfile();
    print $fh2 "hello"; close $fh2;
    my ( $fh3, $path3 ) = tempfile();
    print $fh3 "goodbye"; close $fh3;

    is( $plugin->_content_hash($path1), $plugin->_content_hash($path2), 'identical content hashes identically' );
    isnt( $plugin->_content_hash($path1), $plugin->_content_hash($path3), 'different content hashes differently' );

    $schema->storage->txn_rollback;
};

subtest '_job_should_run defaults to true for a job with no history' => sub {
    plan tests => 1;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );
    ok( $plugin->_job_should_run( 'Never run before', 'abc123' ), 'a job with no recorded history should run' );

    $schema->storage->txn_rollback;
};

subtest '_record_job_run then _job_should_run reflects unchanged vs changed content' => sub {
    plan tests => 2;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );
    $plugin->_record_job_run( 'Nightly job', 'hash-one', { imported => 3 } );

    is( $plugin->_job_should_run( 'Nightly job', 'hash-one' ), 0, 'identical hash is recognised as unchanged, should not run' );
    ok( $plugin->_job_should_run( 'Nightly job', 'hash-two' ), 'a different hash is recognised as changed, should run' );

    $schema->storage->txn_rollback;
};

subtest '_record_job_run keeps history for other jobs independent' => sub {
    plan tests => 2;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );
    $plugin->_record_job_run( 'Job A', 'hash-a', { imported => 1 } );
    $plugin->_record_job_run( 'Job B', 'hash-b', { imported => 2 } );

    is( $plugin->_job_should_run( 'Job A', 'hash-a' ), 0, 'Job A recognises its own unchanged hash' );
    ok( $plugin->_job_should_run( 'Job B', 'hash-a' ), 'Job B is not confused by Job A\'s hash' );

    $schema->storage->txn_rollback;
};
