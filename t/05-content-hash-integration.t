#!/usr/bin/perl

use Modern::Perl;

use Test::More tests => 1;
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
        push @import_calls, 1;
        return { feedback => [], errors => [], imported => 1, overwritten => 0, already_in_db => 0, invalid => 0 };
    }
);

subtest 'unchanged file content is skipped on a second run, changed content is re-imported' => sub {
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
                transport => 'local', download_directory => $remote_dir, upload_directory => '',
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
                            name              => 'Frequent job',
                            file_transport_id => $transport->id,
                            filename          => 'patrons.csv',
                            parameters        => { matchpoint => 'cardnumber' },
                            columns           => [
                                { output => 'cardnumber', input => 'cardnumber' },
                                { output => 'surname',    input => 'surname' },
                            ],
                        },
                    ]
                )
            ),
        }
    );

    @import_calls = ();
    $plugin->cronjob_nightly();
    is( scalar @import_calls, 1, 'first run imports' );

    # Same content, simulating a second cron tick minutes later with no new file yet.
    @import_calls = ();
    $plugin->cronjob_nightly();
    is( scalar @import_calls, 0, 'second run with unchanged content is skipped' );

    # File updated with new content, simulating a new export landing.
    open my $fh2, '>', "$remote_dir/patrons.csv" or die $!;
    print $fh2 "cardnumber,surname\n5678,Jones\n";
    close $fh2;

    @import_calls = ();
    $plugin->cronjob_nightly();
    is( scalar @import_calls, 1, 'third run with changed content imports again' );

    $schema->storage->txn_rollback;
};
