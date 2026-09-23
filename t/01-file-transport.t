#!/usr/bin/perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;

use FindBin qw($Bin);

BEGIN {
    unshift( @INC, "$Bin/.." );
    unshift( @INC, '/kohadevbox/koha/' );
    unshift( @INC, '/kohadevbox/koha/t/lib/' );
}

use Test::More tests => 2;
use Test::NoWarnings;
use Test::Exception;

use File::Path  qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp  qw(tempdir);

use Koha::Database;
use Koha::File::Transports;
use Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced;

use t::lib::TestBuilder;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

subtest 'get_file_transport() tests' => sub {
    plan tests => 14;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );

    # A directory with a CSV, and a subdirectory with another, for a local file transport to serve
    my $download_dir = tempdir( CLEANUP => 1 );
    make_path("$download_dir/sub");
    write_file( "$download_dir/patrons.csv",     "cardnumber,surname\n1,Hall\n" );
    write_file( "$download_dir/sub/patrons.csv", "cardnumber,surname\n2,Sub\n" );
    my $local_dir = tempdir( CLEANUP => 1 );

    my $transport = $builder->build_object(
        {
            class => 'Koha::File::Transports',
            value => {
                transport          => 'local',
                name               => 'Patrons importer test transport',
                download_directory => $download_dir,
                upload_directory   => undef,
                password           => undef,
                key_file           => undef,
                status             => undef,
            }
        }
    );

    throws_ok { $plugin->get_file_transport( {} ) } qr/requires a filename/,
      'Dies without a file_transport block';
    throws_ok { $plugin->get_file_transport( { file_transport => { id => $transport->id } } ) }
    qr/requires a filename/, 'Dies without a filename';
    throws_ok { $plugin->get_file_transport( { file_transport => { filename => 'patrons.csv' } } ) }
    qr/requires an id or a name/, 'Dies without an id or a name';
    throws_ok {
        $plugin->get_file_transport( { file_transport => { id => $transport->id + 1000, filename => 'patrons.csv' } } )
    }
    qr/No file transport found with id/, 'Dies for an unknown id';
    throws_ok {
        $plugin->get_file_transport( { file_transport => { name => 'No such transport', filename => 'patrons.csv' } } )
    }
    qr/No file transport found named/, 'Dies for an unknown name';

    my $found =
      $plugin->get_file_transport( { file_transport => { id => $transport->id, filename => 'patrons.csv' } } );
    isa_ok( $found, 'Koha::File::Transport::Local', 'Transport found by id' );
    is( $found->id, $transport->id, 'Correct transport found by id' );
    ok( $found->download_file( 'patrons.csv', "$local_dir/by_id.csv" ), 'File downloaded through the transport' );
    is(
        read_file("$local_dir/by_id.csv"), "cardnumber,surname\n1,Hall\n",
        'Downloaded file has the expected contents'
    );
    $found->disconnect;

    $found =
      $plugin->get_file_transport( { file_transport => { name => $transport->name, filename => 'patrons.csv' } } );
    is( $found->id, $transport->id, 'Correct transport found by name' );
    $found->disconnect;

    $builder->build_object(
        {
            class => 'Koha::File::Transports',
            value => {
                transport          => 'local',
                name               => $transport->name,
                download_directory => $download_dir,
                upload_directory   => undef,
                password           => undef,
                key_file           => undef,
                status             => undef,
            }
        }
    );
    throws_ok {
        $plugin->get_file_transport( { file_transport => { name => $transport->name, filename => 'patrons.csv' } } )
    }
    qr/2 file transports are named .* use id instead/, 'Dies when the name matches more than one transport';

    # The job's directory overrides the transport's download directory and can contain template toolkit markup
    my $no_dir_transport = $builder->build_object(
        {
            class => 'Koha::File::Transports',
            value => {
                transport          => 'local',
                name               => 'Patrons importer test transport without a directory',
                download_directory => undef,
                upload_directory   => undef,
                password           => undef,
                key_file           => undef,
                status             => undef,
            }
        }
    );
    $found = $plugin->get_file_transport(
        {
            file_transport => {
                id        => $no_dir_transport->id,
                directory => "$download_dir/[% 'sub' %]",
                filename  => 'patrons.csv',
            }
        }
    );
    ok(
        $found->download_file( 'patrons.csv', "$local_dir/override.csv" ),
        'File downloaded from the overridden directory'
    );
    is(
        read_file("$local_dir/override.csv"), "cardnumber,surname\n2,Sub\n",
        'Template toolkit markup in the directory was rendered'
    );
    $found->disconnect;

    throws_ok {
        $plugin->get_file_transport(
            {
                file_transport => {
                    id        => $transport->id,
                    directory => "$download_dir/missing",
                    filename  => 'patrons.csv',
                }
            }
        )
    }
    qr/change directory to .* failed .* change_directory: Directory not found/, 'Dies when the directory does not exist';

    $schema->storage->txn_rollback;
};
