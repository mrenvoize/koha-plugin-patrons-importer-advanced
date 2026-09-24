#!/usr/bin/perl

use Modern::Perl;

use Test::More tests => 3;
use Test::MockModule;

use File::Temp qw(tempdir);
use YAML::XS   qw(Dump);

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
        my ( $self, $params ) = @_;
        local $/;
        my $fh = $params->{file};
        push @import_calls, { %$params, file_content => <$fh> };
        return { feedback => [], errors => [], imported => 1, overwritten => 0, already_in_db => 0, invalid => 0 };
    }
);

subtest 'job with file_transport_id fetches via Koha::File::Transport::Local' => sub {
    plan tests => 3;

    $schema->storage->txn_begin;

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
    _store_configuration(
        $plugin,
        [
            {
                name              => 'Local job',
                file_transport_id => $transport->id,
                filename          => 'patrons.csv',
                columns           => [
                    { output => 'cardnumber', input => 'cardnumber' },
                    { output => 'surname',    input => 'surname' },
                ],
                parameters        => { matchpoint => 'cardnumber' },
            },
        ]
    );

    @import_calls = ();
    $plugin->cronjob_nightly();

    is( scalar @import_calls, 1, 'import_patrons called exactly once' );
    like( $import_calls[0]->{file_content}, qr/1234,Smith/, 'downloaded file content reached the importer' );
    is( $import_calls[0]->{matchpoint}, 'cardnumber', 'job parameters passed through' );

    $schema->storage->txn_rollback;
};

subtest 'job-level path overrides the transport\'s configured download_directory' => sub {
    plan tests => 1;

    $schema->storage->txn_begin;

    my $base_dir  = tempdir( CLEANUP => 1 );
    my $other_dir = "$base_dir/other";
    mkdir $other_dir or die $!;
    open my $fh, '>', "$other_dir/patrons.csv" or die $!;
    print $fh "cardnumber,surname\n9999,Overridden\n";
    close $fh;

    # Transport's own download_directory points elsewhere; the job's `path` should win.
    my $transport = $builder->build_object(
        {
            class => 'Koha::File::Transports',
            value => {
                transport => 'local', auth_mode => 'noauth', download_directory => $base_dir, upload_directory => '',
                host => '', port => 22, user_name => undef, password => undef, key_file => undef, passive => 1,
            },
        }
    );

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );
    _store_configuration(
        $plugin,
        [
            {
                name              => 'Override job',
                file_transport_id => $transport->id,
                filename          => 'patrons.csv',
                columns           => [
                    { output => 'cardnumber', input => 'cardnumber' },
                    { output => 'surname',    input => 'surname' },
                ],
                path              => $other_dir,
                parameters        => { matchpoint => 'cardnumber' },
            },
        ]
    );

    @import_calls = ();
    $plugin->cronjob_nightly();

    like( $import_calls[0]->{file_content}, qr/9999,Overridden/, 'job-level path override was used instead of the transport default' );

    $schema->storage->txn_rollback;
};

subtest 'job missing file_transport_id is skipped without dying' => sub {
    plan tests => 2;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );
    _store_configuration(
        $plugin,
        [ { name => 'Broken job', parameters => { matchpoint => 'cardnumber' } } ]
    );

    @import_calls = ();
    my $lived = eval { $plugin->cronjob_nightly(); 1 };

    ok( $lived, 'cronjob_nightly does not die on a job with no file_transport_id' );
    is( scalar @import_calls, 0, 'import_patrons was never called for the broken job' );

    $schema->storage->txn_rollback;
};

sub _store_configuration {
    my ( $plugin, $jobs ) = @_;
    $plugin->store_data( { configuration => Koha::Encryption->new->encrypt_hex( Dump($jobs) ) } );
}
