#!/usr/bin/perl

use Modern::Perl;

use Test::More tests => 5;

use YAML::XS qw(Dump);

use Koha::Database;
use Koha::Encryption;
use Koha::File::Transports;

use Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced;

my $schema = Koha::Database->new->schema;

subtest 'sftp job is migrated to a Koha::File::Transport::SFTP row' => sub {
    plan tests => 8;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );
    _store_configuration(
        $plugin,
        [
            {
                name => 'Nightly SFTP job',
                sftp => {
                    host      => 'sftp.library.org',
                    username  => 'admin',
                    password  => 'secret',
                    directory => '/incoming',
                    filename  => 'patrons.csv',
                    port      => 2222,
                },
                parameters => { matchpoint => 'cardnumber' },
            },
        ]
    );

    $plugin->upgrade();

    my $jobs = $plugin->get_configuration();
    is( scalar @$jobs, 1, 'still exactly one job after migration' );
    ok( $jobs->[0]->{file_transport_id}, 'job now has a file_transport_id' );
    is( $jobs->[0]->{filename}, 'patrons.csv', 'filename carried over to job root' );
    ok( !exists $jobs->[0]->{sftp}, 'legacy sftp block removed' );

    my $transport = Koha::File::Transports->find( $jobs->[0]->{file_transport_id} );
    is( $transport->transport,  'sftp',               'created transport is of type sftp' );
    is( $transport->host,       'sftp.library.org',    'host carried over' );
    is( $transport->user_name,  'admin',                'username carried over to user_name' );
    is( $transport->plain_text_password, 'secret',      'password carried over and is decryptable' );

    $schema->storage->txn_rollback;
};

subtest 'local job is migrated to a Koha::File::Transport::Local row' => sub {
    plan tests => 4;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );
    _store_configuration(
        $plugin,
        [
            {
                name       => 'Local job',
                local      => { directory => '/kohadevbox/koha', filename => 'students.txt' },
                parameters => { matchpoint => 'cardnumber' },
            },
        ]
    );

    $plugin->upgrade();

    my $jobs = $plugin->get_configuration();
    ok( $jobs->[0]->{file_transport_id}, 'job now has a file_transport_id' );
    is( $jobs->[0]->{filename}, 'students.txt', 'filename carried over to job root' );
    ok( !exists $jobs->[0]->{local}, 'legacy local block removed' );

    my $transport = Koha::File::Transports->find( $jobs->[0]->{file_transport_id} );
    is( $transport->transport, 'local', 'created transport is of type local' );

    $schema->storage->txn_rollback;
};

subtest 'upgrade is idempotent and leaves already-migrated jobs untouched' => sub {
    plan tests => 3;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );
    _store_configuration(
        $plugin,
        [
            {
                name => 'Nightly SFTP job',
                sftp => {
                    host => 'sftp.library.org', username => 'admin', password => 'secret',
                    directory => '/incoming', filename => 'patrons.csv',
                },
                parameters => { matchpoint => 'cardnumber' },
            },
        ]
    );

    $plugin->upgrade();
    my $first_id = $plugin->get_configuration->[0]->{file_transport_id};

    $plugin->upgrade();    # calling again must not create a second transport or re-migrate
    my $jobs = $plugin->get_configuration();

    is( $jobs->[0]->{file_transport_id}, $first_id, 'file_transport_id unchanged on second upgrade() call' );
    is(
        Koha::File::Transports->search( { name => 'PatronsImporterAdvanced: Nightly SFTP job' } )->count,
        1, 'only one transport row exists for this job'
    );
    ok( !exists $jobs->[0]->{sftp}, 'no sftp block resurrected' );

    $schema->storage->txn_rollback;
};

subtest 'a mid-migration failure rolls back all transports and leaves the config untouched' => sub {
    plan tests => 5;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );

    # file_transports.name is varchar(80); the "PatronsImporterAdvanced: "
    # prefix is 25 characters, so a 60-character job name overflows it and
    # the second job's transport row fails to store under strict SQL mode.
    my $long_name = 'X' x 60;
    _store_configuration(
        $plugin,
        [
            {
                name => 'Good job',
                sftp => {
                    host => 'sftp.library.org', username => 'admin', password => 'secret',
                    directory => '/incoming', filename => 'patrons.csv',
                },
                parameters => { matchpoint => 'cardnumber' },
            },
            {
                name => $long_name,
                sftp => {
                    host => 'sftp.library.org', username => 'admin', password => 'secret',
                    directory => '/incoming', filename => 'other.csv',
                },
                parameters => { matchpoint => 'cardnumber' },
            },
        ]
    );

    # Relative to whatever is already in the DB - the dev database may hold
    # unrelated pre-existing transport rows.
    my $count_before = Koha::File::Transports->search( {} )->count;

    my $lived = eval { $plugin->upgrade(); 1 };
    ok( !$lived, 'upgrade dies when one job cannot be migrated' );

    is(
        Koha::File::Transports->search( {} )->count,
        $count_before, 'no transport rows left behind, including for the job that migrated before the failure'
    );

    my $jobs = $plugin->get_configuration();
    ok( $jobs->[0]->{sftp}, 'first job still has its legacy sftp block' );
    ok( $jobs->[1]->{sftp}, 'second job still has its legacy sftp block' );
    ok(
        !$jobs->[0]->{file_transport_id} && !$jobs->[1]->{file_transport_id},
        'no job was partially rewritten to file_transport_id'
    );

    $schema->storage->txn_rollback;
};

subtest 'local directory with TT markup migrates to the job path, plain directory to the transport' => sub {
    plan tests => 6;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );
    my $tt_directory = q{/exports/[% USE date %][% date.format(date.now, '%Y%m%d') %]};
    _store_configuration(
        $plugin,
        [
            {
                name       => 'TT dir job',
                local      => { directory => $tt_directory, filename => 'students.txt' },
                parameters => { matchpoint => 'cardnumber' },
            },
            {
                name       => 'Plain dir job',
                local      => { directory => '/kohadevbox/koha', filename => 'students.txt' },
                parameters => { matchpoint => 'cardnumber' },
            },
        ]
    );

    $plugin->upgrade();

    my $jobs = $plugin->get_configuration();

    is( $jobs->[0]->{path}, $tt_directory, 'TT-marked directory moved to the job path key, markup intact' );
    ok( !exists $jobs->[0]->{local}, 'legacy local block still removed for the TT job' );
    my $tt_transport = Koha::File::Transports->find( $jobs->[0]->{file_transport_id} );
    ok( !$tt_transport->download_directory, 'TT-marked directory was not stored on the transport row' );
    is( $tt_transport->transport, 'local', 'TT job still migrated to a local transport' );

    ok( !exists $jobs->[1]->{path}, 'plain directory job gets no path key' );
    my $plain_transport = Koha::File::Transports->find( $jobs->[1]->{file_transport_id} );
    is(
        $plain_transport->download_directory, '/kohadevbox/koha/',
        'plain directory still stored on the transport row as before (store adds a trailing slash)'
    );

    $schema->storage->txn_rollback;
};

sub _store_configuration {
    my ( $plugin, $jobs ) = @_;

    $plugin->store_data( { configuration => Koha::Encryption->new->encrypt_hex( Dump($jobs) ) } );
}
