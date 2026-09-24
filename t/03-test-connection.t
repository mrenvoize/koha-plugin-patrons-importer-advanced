#!/usr/bin/perl

use Modern::Perl;

use Test::More tests => 3;
use Test::MockModule;

use CGI;
use File::Temp qw(tempdir);
use YAML::XS   qw(Dump);

use Koha::Database;
use Koha::Encryption;
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

subtest 'configure() test branch reports a job with no file_transport_id instead of omitting it' => sub {
    plan tests => 5;

    $schema->storage->txn_begin;

    my %template_params;
    my $fake_template = FakeTemplate->new( \%template_params );

    my $mock_base = Test::MockModule->new('Koha::Plugins::Base');
    $mock_base->mock( 'get_template', sub { return $fake_template } );
    $mock_base->mock( 'output_html',  sub { return } );

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
    $plugin->store_data(
        {
            configuration => Koha::Encryption->new->encrypt_hex(
                Dump(
                    [
                        { name => 'No transport job', parameters        => { matchpoint => 'cardnumber' } },
                        { name => 'Good job',         file_transport_id => $transport->id },
                    ]
                )
            ),
        }
    );
    $plugin->{cgi} = CGI->new('test=1');

    $plugin->configure();

    is( $template_params{test_completed}, 1, 'test branch ran to completion' );
    my $results = $template_params{results};
    is( scalar @$results, 2, 'a job with no file_transport_id still appears in the results' );
    is( $results->[0]->{ok}, 0, 'the transportless job is reported as not ok' );
    like( $results->[0]->{error}, qr/no file_transport_id/, 'its error explains the missing transport' );
    ok( $results->[1]->{ok}, 'the properly configured job still tests ok' );

    $schema->storage->txn_rollback;
};

{

    package FakeTemplate;

    sub new {
        my ( $class, $params ) = @_;
        return bless { params => $params }, $class;
    }

    sub param {
        my ( $self, %args ) = @_;
        $self->{params}->{$_} = $args{$_} for keys %args;
    }

    sub output { return q{} }
}
