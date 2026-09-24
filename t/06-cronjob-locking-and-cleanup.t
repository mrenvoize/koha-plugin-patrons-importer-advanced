#!/usr/bin/perl

use Modern::Perl;

use Test::More tests => 3;
use Test::MockModule;

use File::Path qw(rmtree);
use File::Temp qw(tempdir);
use YAML::XS   qw(Dump);

use C4::Context;
use Koha::Database;
use Koha::Encryption;
use t::lib::TestBuilder;

use Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

my @import_calls;
my $mock_import = Test::MockModule->new('Koha::Patrons::Import');
$mock_import->mock(
    'import_patrons',
    sub {
        push @import_calls, 1;
        return { feedback => [], errors => [], imported => 1, overwritten => 0, already_in_db => 0, invalid => 0 };
    }
);

subtest 'a job whose lock is already held elsewhere is skipped' => sub {
    plan tests => 3;

    $schema->storage->txn_begin;

    my ($plugin) = _configure_job('Locked job');

    # Simulate a concurrent run holding this job's lock, from a second DB
    # session (GET_LOCK is re-entrant within a single session, so the lock
    # must be held by a different connection to be a meaningful test).
    # NOTE: clone() rather than C4::Context->dbh({ new => 1 }) - the latter
    # replaces Koha's cached schema, detaching us from the test transaction.
    my $other_session = C4::Context->dbh->clone;
    my ($held) =
      $other_session->selectrow_array( q{SELECT GET_LOCK(?, 0)}, undef, 'PatronsImporterAdvanced:Locked job' );
    is( $held, 1, 'test acquired the job lock from a second session' );

    @import_calls = ();
    $plugin->cronjob_nightly();
    is( scalar @import_calls, 0, 'job was skipped while its lock was held elsewhere' );

    $other_session->selectrow_array( q{SELECT RELEASE_LOCK(?)}, undef, 'PatronsImporterAdvanced:Locked job' );

    @import_calls = ();
    $plugin->cronjob_nightly();
    is( scalar @import_calls, 1, 'job runs normally once the lock is released' );

    $schema->storage->txn_rollback;
};

subtest 'the lock is released after a successful, a dedup-skipped, and a failed run' => sub {
    plan tests => 6;

    $schema->storage->txn_begin;

    my ( $plugin, $remote_dir ) = _configure_job('Release job');

    @import_calls = ();
    $plugin->cronjob_nightly();
    is( scalar @import_calls, 1, 'job ran successfully' );

    my $other_session = C4::Context->dbh->clone;
    my ($acquirable) =
      $other_session->selectrow_array( q{SELECT GET_LOCK(?, 0)}, undef, 'PatronsImporterAdvanced:Release job' );
    is( $acquirable, 1, 'lock is free again immediately after a successful run' );
    $other_session->selectrow_array( q{SELECT RELEASE_LOCK(?)}, undef, 'PatronsImporterAdvanced:Release job' );

    # Unchanged content: the run is skipped by the content-hash dedup AFTER
    # the lock was acquired, so this exercises the skip-partway release path
    @import_calls = ();
    $plugin->cronjob_nightly();
    is( scalar @import_calls, 0, 'second run with unchanged content was dedup-skipped' );

    ($acquirable) =
      $other_session->selectrow_array( q{SELECT GET_LOCK(?, 0)}, undef, 'PatronsImporterAdvanced:Release job' );
    is( $acquirable, 1, 'lock is free again after a dedup-skipped run' );
    $other_session->selectrow_array( q{SELECT RELEASE_LOCK(?)}, undef, 'PatronsImporterAdvanced:Release job' );

    # Break the job: remove its source file so the download step dies mid-job
    unlink "$remote_dir/patrons.csv" or die $!;
    @import_calls = ();
    $plugin->cronjob_nightly();
    is( scalar @import_calls, 0, 'broken job did not import' );

    ($acquirable) =
      $other_session->selectrow_array( q{SELECT GET_LOCK(?, 0)}, undef, 'PatronsImporterAdvanced:Release job' );
    is( $acquirable, 1, 'lock is free again after a failed run' );
    $other_session->selectrow_array( q{SELECT RELEASE_LOCK(?)}, undef, 'PatronsImporterAdvanced:Release job' );

    $schema->storage->txn_rollback;
};

subtest 'download tempdirs are cleaned up rather than accumulating' => sub {
    plan tests => 2;

    $schema->storage->txn_begin;

    my ($plugin) = _configure_job('Cleanup job');

    # Point tempdir() at a scoped location we can inspect. Created without
    # CLEANUP so that File::Temp::cleanup() below cannot remove it (and
    # thereby hide any leaked directories inside it); removed manually.
    my $scoped_tmp = tempdir();
    local $ENV{TMPDIR} = $scoped_tmp;

    @import_calls = ();
    $plugin->cronjob_nightly();
    is( scalar @import_calls, 1, 'job ran' );

    # CLEANUP-registered tempdirs are removed at program exit; trigger that
    # removal now so we can assert on the resulting disk state.
    File::Temp::cleanup();

    my @leftover = grep { -d } glob("$scoped_tmp/*");
    is( scalar @leftover, 0, 'no download tempdir left behind after cleanup' )
      or diag "leftover directories: @leftover";

    rmtree($scoped_tmp);

    $schema->storage->txn_rollback;
};

sub _configure_job {
    my ($job_name) = @_;

    my $remote_dir = tempdir( CLEANUP => 1 );
    open my $fh, '>', "$remote_dir/patrons.csv" or die $!;
    print $fh "cardnumber,surname\n1234,Smith\n";
    close $fh;

    my $transport = $builder->build_object(
        {
            class => 'Koha::File::Transports',
            value => {
                transport => 'local', auth_mode => 'noauth', download_directory => $remote_dir, upload_directory => '',
                host => '', port => 22, user_name => undef, password => undef, key_file => undef, passive => 1,
            },
        }
    );

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );
    $plugin->store_data(
        {
            configuration => Koha::Encryption->new->encrypt_hex(
                Dump(
                    [
                        {
                            name              => $job_name,
                            file_transport_id => $transport->id,
                            filename          => 'patrons.csv',
                            columns           => [
                                { output => 'cardnumber', input => 'cardnumber' },
                                { output => 'surname',    input => 'surname' },
                            ],
                            parameters => { matchpoint => 'cardnumber' },
                        },
                    ]
                )
            ),
        }
    );

    return ( $plugin, $remote_dir );
}
