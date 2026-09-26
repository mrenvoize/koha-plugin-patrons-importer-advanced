#!/usr/bin/perl

use Modern::Perl;

use Test::More tests => 9;
use Test::MockModule;

use Koha::Database;
use t::lib::TestBuilder;

use GD;
use Archive::Zip qw( :ERROR_CODES );
use File::Temp   qw( tempfile tempdir );
use File::Spec;
use YAML::XS qw(Dump);

use C4::Context;
use Koha::Encryption;
use Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced;
use Koha::Patron::Images;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

subtest '_resolve_photo_patron matchpoint resolution' => sub {
    plan tests => 5;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );

    my $patron = $builder->build_object(
        { class => 'Koha::Patrons', value => { cardnumber => 'TESTCARD1', userid => 'testuser1' } } );

    is( $plugin->_resolve_photo_patron( 'cardnumber', $patron->cardnumber )->borrowernumber,
        $patron->borrowernumber, 'matched by cardnumber' );
    is( $plugin->_resolve_photo_patron( 'userid', $patron->userid )->borrowernumber,
        $patron->borrowernumber, 'matched by userid' );

    my $attribute_type =
      $builder->build_object( { class => 'Koha::Patron::Attribute::Types', value => { unique_id => 1 } } );
    $builder->build_object(
        {
            class => 'Koha::Patron::Attributes',
            value => { borrowernumber => $patron->borrowernumber, code => $attribute_type->code, attribute => 'ATTRVAL1' }
        }
    );
    is(
        $plugin->_resolve_photo_patron( 'patron_attribute_' . $attribute_type->code, 'ATTRVAL1' )->borrowernumber,
        $patron->borrowernumber, 'matched by patron attribute'
    );

    ok( !$plugin->_resolve_photo_patron( 'cardnumber', 'NOSUCHCARD' ), 'no matching patron returns undef' );
    ok( !$plugin->_resolve_photo_patron( 'cardnumber', undef ), 'undef identifier returns undef' );

    $schema->storage->txn_rollback;
};

subtest '_import_photo: validation, resize, and storage' => sub {
    plan tests => 7;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );
    my $patron = $builder->build_object( { class => 'Koha::Patrons', value => { cardnumber => 'PHOTOCARD1' } } );

    my $oversized_bytes = 'x' x 2_097_153;
    my ( $oversized_fh, $oversized_path ) = File::Temp::tempfile( UNLINK => 1 );
    binmode $oversized_fh;
    print $oversized_fh $oversized_bytes;
    close $oversized_fh;
    open $oversized_fh, '<', $oversized_path or die $!;
    is_deeply(
        $plugin->_import_photo( { file => $oversized_fh, identifier => $patron->cardnumber, matchpoint => 'cardnumber' } ),
        { error => 'OVRSIZ' }, 'oversized file rejected'
    );

    my ( $corrupt_fh, $corrupt_path ) = File::Temp::tempfile( UNLINK => 1 );
    binmode $corrupt_fh;
    print $corrupt_fh 'not an image';
    close $corrupt_fh;
    open $corrupt_fh, '<', $corrupt_path or die $!;
    is_deeply(
        $plugin->_import_photo( { file => $corrupt_fh, identifier => $patron->cardnumber, matchpoint => 'cardnumber' } ),
        { error => 'CORERR' }, 'corrupt image rejected'
    );

    is_deeply(
        $plugin->_import_photo( { file => _small_png_fh(), identifier => 'NOSUCHCARD', matchpoint => 'cardnumber' } ),
        { error => 'PATRON_NOT_FOUND' }, 'unmatched identifier rejected'
    );

    is_deeply(
        $plugin->_import_photo( { file => _small_png_fh( 400, 600 ), identifier => $patron->cardnumber, matchpoint => 'cardnumber' } ),
        { success => 1 }, 'oversized-dimension image is resized, not rejected'
    );

    my $stored     = Koha::Patron::Images->find( $patron->borrowernumber );
    my $stored_img = GD::Image->new( $stored->imagefile );
    my ( $w, $h )  = $stored_img->getBounds;
    ok( $w <= 200 && $h <= 300, "resized to within a real 200x300 (got ${w}x${h})" );

    my $patron2 = $builder->build_object( { class => 'Koha::Patrons', value => { cardnumber => 'PHOTOCARD2' } } );
    is_deeply(
        $plugin->_import_photo(
            { file => _small_png_fh(), identifier => $patron2->cardnumber, matchpoint => 'cardnumber', dry_run => 1 }
        ),
        { success => 1 }, 'dry_run reports success'
    );
    ok( !Koha::Patron::Images->find( $patron2->borrowernumber ), 'dry_run does not actually store an image' )
      or diag 'dry_run stored an image when it should not have';

    $schema->storage->txn_rollback;
};

sub _small_png_fh {
    my ( $width, $height ) = @_;
    my $img = GD::Image->new( $width // 10, $height // 10, 1 );
    my ( $fh, $path ) = File::Temp::tempfile( UNLINK => 1 );
    binmode $fh;
    print $fh $img->png;
    close $fh;
    open my $read_fh, '<', $path or die "Unable to reopen $path: $!";
    return $read_fh;
}

subtest '_import_photo_batch: zip extraction and matching' => sub {
    plan tests => 8;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );
    my $png    = GD::Image->new( 10, 10, 1 )->png;

    my $patron1 = $builder->build_object( { class => 'Koha::Patrons', value => { cardnumber => 'BATCHCARD1' } } );
    my $patron2 = $builder->build_object( { class => 'Koha::Patrons', value => { cardnumber => 'BATCHCARD2' } } );

    my $zip_path = _build_photo_zip(
        {
            'idlink.txt' => "BATCHCARD1,a.png\nBATCHCARD2,b.png\n",
            'a.png'      => $png,
            'b.png'      => $png,
        }
    );
    my $result = $plugin->_import_photo_batch( { file => $zip_path, matchpoint => 'cardnumber' } );
    is( scalar @{ $result->{imported} }, 2, 'manifest: two rows imported' );
    is( scalar @{ $result->{errors} },   0, 'manifest: no errors' );
    ok(
        Koha::Patron::Images->find( $patron1->borrowernumber ) && Koha::Patron::Images->find( $patron2->borrowernumber ),
        'manifest: both images stored'
    );
    unlink $zip_path;

    my $patron3 = $builder->build_object( { class => 'Koha::Patrons', value => { cardnumber => 'STEMCARD1' } } );
    $zip_path = _build_photo_zip( { 'STEMCARD1.png' => $png, 'notes.txt' => 'not an image' } );
    $result = $plugin->_import_photo_batch( { file => $zip_path, matchpoint => 'cardnumber' } );
    is( scalar @{ $result->{imported} }, 1, 'no manifest: filename-stem matched, one row imported' );
    is( $result->{imported}[0]{identifier}, 'STEMCARD1', 'no manifest: identifier is the filename stem' );
    unlink $zip_path;

    $zip_path = _build_photo_zip(
        {
            'idlink.txt' => "BATCHCARD1,a.png\nNOSUCHCARD,../../../../etc/passwd\n",
            'a.png'      => $png,
        }
    );
    $result = $plugin->_import_photo_batch( { file => $zip_path, matchpoint => 'cardnumber' } );
    is( scalar @{ $result->{imported} }, 1,             'zip-slip: the safe row still imports' );
    is( scalar @{ $result->{errors} },   1,              'zip-slip: the traversal row is rejected, not followed' );
    is( $result->{errors}[0]{error},     'UNSAFE_PATH',  'zip-slip: rejected specifically as an unsafe path' );
    unlink $zip_path;

    $schema->storage->txn_rollback;
};

subtest '_import_photo_batch: TOO_MANY_MEMBERS cap' => sub {
    plan tests => 2;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );

    my $zip = Archive::Zip->new;
    $zip->addString( 'x', "file$_.png" ) for ( 1 .. 1001 );
    my ( $fh, $zip_path ) = tempfile( SUFFIX => '.zip', UNLINK => 0 );
    close $fh;
    $zip->writeToFileNamed($zip_path) == Archive::Zip::AZ_OK or die 'Unable to write test zip';

    my $result = $plugin->_import_photo_batch( { file => $zip_path, matchpoint => 'cardnumber' } );
    is( scalar @{ $result->{errors} }, 1,                  'a single error is returned when the cap is exceeded' );
    is( $result->{errors}[0]{error},   'TOO_MANY_MEMBERS',  'the error code is TOO_MANY_MEMBERS' );

    unlink $zip_path;
    $schema->storage->txn_rollback;
};

subtest '_import_photo_batch: symlink members are skipped, not followed' => sub {
    plan tests => 2;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );

    # An attacker-controlled directory elsewhere on disk, standing in for
    # anywhere outside the batch's own extraction tempdir (e.g. /etc/cron.d
    # in the real-world exploit). If a symlink member pointing here is
    # followed on extraction, a later member named "evillink/evil.png"
    # would write attacker content into this directory instead of staying
    # contained inside the extraction tempdir.
    my $target_dir = tempdir( CLEANUP => 1 );

    my $zip = Archive::Zip->new;

    # A member whose externalFileAttributes mark it as a unix symlink
    # (0xA1FF0000, i.e. S_IFLNK|0777 << 16 - the same bit pattern
    # Archive::Zip::Member->isSymbolicLink checks for, and that ordinary
    # tools like `zip -y` produce), whose content is the symlink target.
    my $link_member = Archive::Zip::Member->newFromString( $target_dir, 'evillink' );
    $link_member->unixFileAttributes(0120777);    # S_IFLNK (0120000) | 0777
    $zip->addMember($link_member);

    # A regular member whose name would resolve through the symlink above
    # if it were followed during extraction.
    $zip->addString( 'attacker content', 'evillink/evil.png' );

    my ( $fh, $zip_path ) = tempfile( SUFFIX => '.zip', UNLINK => 0 );
    close $fh;
    $zip->writeToFileNamed($zip_path) == Archive::Zip::AZ_OK or die 'Unable to write test zip';

    my $result = $plugin->_import_photo_batch( { file => $zip_path, matchpoint => 'cardnumber' } );

    ok( defined $result, 'batch completes without dying on a zip containing a symlink member' );
    ok(
        !-e File::Spec->catfile( $target_dir, 'evil.png' ),
        'symlink member is skipped: nothing is written into the symlink target directory'
    );

    unlink $zip_path;
    $schema->storage->txn_rollback;
};

subtest '_run_photo_job: end-to-end via cronjob_nightly' => sub {
    plan tests => 6;

    $schema->storage->txn_begin;

    my $patron_loose = $builder->build_object( { class => 'Koha::Patrons', value => { cardnumber => 'LOOSECARD1' } } );
    my $patron_zip1   = $builder->build_object( { class => 'Koha::Patrons', value => { cardnumber => 'ZIPCARD1' } } );
    my $patron_zip2   = $builder->build_object( { class => 'Koha::Patrons', value => { cardnumber => 'ZIPCARD2' } } );

    my $remote_dir = tempdir( CLEANUP => 1 );
    my $png        = GD::Image->new( 10, 10, 1 )->png;

    open my $loose_fh, '>', "$remote_dir/LOOSECARD1.png" or die $!;
    binmode $loose_fh;
    print $loose_fh $png;
    close $loose_fh;

    open my $ignored_fh, '>', "$remote_dir/notes.txt" or die $!;
    print $ignored_fh 'irrelevant';
    close $ignored_fh;

    my $zip = Archive::Zip->new;
    $zip->addString( "ZIPCARD1,a.png\nZIPCARD2,b.png\n", 'idlink.txt' );
    $zip->addString( $png, 'a.png' );
    $zip->addString( $png, 'b.png' );
    $zip->writeToFileNamed("$remote_dir/photos.zip") == Archive::Zip::AZ_OK or die 'Unable to write test zip';

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
                            name              => 'Photo job',
                            type              => 'photo',
                            file_transport_id => $transport->id,
                            matchpoint        => 'cardnumber',
                        },
                    ]
                )
            ),
        }
    );

    $plugin->cronjob_nightly();

    ok( Koha::Patron::Images->find( $patron_loose->borrowernumber ), 'loose file matched by filename stem' );
    ok( Koha::Patron::Images->find( $patron_zip1->borrowernumber ),  'zip manifest row 1 imported' );
    ok( Koha::Patron::Images->find( $patron_zip2->borrowernumber ),  'zip manifest row 2 imported' );

    # Second run with unchanged source files: both dedup-skip, no re-processing.
    Koha::Patron::Images->find( $patron_loose->borrowernumber )->delete;
    $plugin->cronjob_nightly();
    ok( !Koha::Patron::Images->find( $patron_loose->borrowernumber ), 'unchanged loose file is dedup-skipped on second run' );

    # Changing the loose file's content causes it to be re-imported.
    my $bigger_png = GD::Image->new( 20, 20, 1 )->png;
    open my $changed_fh, '>', "$remote_dir/LOOSECARD1.png" or die $!;
    binmode $changed_fh;
    print $changed_fh $bigger_png;
    close $changed_fh;
    $plugin->cronjob_nightly();
    ok( Koha::Patron::Images->find( $patron_loose->borrowernumber ), 'changed loose file content is re-imported' );

    my $other_session = C4::Context->dbh->clone;
    my ($acquirable) =
      $other_session->selectrow_array( q{SELECT GET_LOCK(?, 0)}, undef, 'PatronsImporterAdvanced:Photo job' );
    is( $acquirable, 1, 'lock is free again after a photo job run' );
    $other_session->selectrow_array( q{SELECT RELEASE_LOCK(?)}, undef, 'PatronsImporterAdvanced:Photo job' );

    $schema->storage->txn_rollback;
};

subtest '_run_photo_job: rejects an unsafe filename from a transport listing' => sub {
    plan tests => 3;

    $schema->storage->txn_begin;

    my $patron = $builder->build_object( { class => 'Koha::Patrons', value => { cardnumber => 'SAFECARD1' } } );

    my $remote_dir = tempdir( CLEANUP => 1 );
    my $png        = GD::Image->new( 10, 10, 1 )->png;
    open my $safe_fh, '>', "$remote_dir/SAFECARD1.png" or die $!;
    binmode $safe_fh;
    print $safe_fh $png;
    close $safe_fh;

    my $transport = $builder->build_object(
        {
            class => 'Koha::File::Transports',
            value => {
                transport => 'local', auth_mode => 'noauth', download_directory => $remote_dir, upload_directory => '',
                host => '', port => 22, user_name => undef, password => undef, key_file => undef, passive => 1,
            },
        }
    );

    # A real local transport's directory listing can never actually contain
    # a path separator (it's built from real filesystem basenames), so a
    # malicious/compromised remote server's listing is simulated directly at
    # the transport layer here, rather than faked end-to-end.
    my $mock = Test::MockModule->new('Koha::File::Transport::Local');
    $mock->mock(
        '_list_files',
        sub {
            return [ { filename => '../../../../etc/evil.png' }, { filename => 'SAFECARD1.png' } ];
        }
    );

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced->new( { enable_plugins => 1 } );
    my $job    = {
        name              => 'Unsafe filename job',
        type              => 'photo',
        file_transport_id => $transport->id,
        matchpoint        => 'cardnumber',
    };

    my $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die $!;
        $plugin->_run_photo_job($job);
    }

    like(
        $output, qr/REJECTING UNSAFE FILENAME '\.\.\/\.\.\/\.\.\/\.\.\/etc\/evil\.png'/,
        'the traversal filename is rejected and logged, without attempting a download'
    );
    ok( Koha::Patron::Images->find( $patron->borrowernumber ), 'the safe entry in the same listing is still imported' );
    is( Koha::Patron::Images->search->count, 1, 'exactly one image exists: the unsafe entry was never processed' );

    $schema->storage->txn_rollback;
};

subtest '_run_photo_job: a dry_run does not poison dedup history for a later real run' => sub {
    plan tests => 2;

    $schema->storage->txn_begin;

    my $patron = $builder->build_object( { class => 'Koha::Patrons', value => { cardnumber => 'DRYCARD1' } } );

    my $remote_dir = tempdir( CLEANUP => 1 );
    my $png        = GD::Image->new( 10, 10, 1 )->png;
    open my $fh, '>', "$remote_dir/DRYCARD1.png" or die $!;
    binmode $fh;
    print $fh $png;
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
    my $job    = {
        name              => 'Dry run job',
        type              => 'photo',
        file_transport_id => $transport->id,
        matchpoint        => 'cardnumber',
        parameters        => { dry_run => 1 },
    };

    $plugin->_run_photo_job($job);
    ok( !Koha::Patron::Images->find( $patron->borrowernumber ), 'dry_run does not actually store an image' );

    $job->{parameters}{dry_run} = 0;
    $plugin->_run_photo_job($job);
    ok(
        Koha::Patron::Images->find( $patron->borrowernumber ),
        'a later real run on the very same unchanged file still imports, proving dry_run recorded no dedup history'
    );

    $schema->storage->txn_rollback;
};

subtest '_run_photo_job: a fully failed file is retried on the next run, not permanently skipped' => sub {
    plan tests => 3;

    $schema->storage->txn_begin;

    my $remote_dir = tempdir( CLEANUP => 1 );
    my $png        = GD::Image->new( 10, 10, 1 )->png;
    open my $fh, '>', "$remote_dir/NOMATCH1.png" or die $!;
    binmode $fh;
    print $fh $png;
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
    my $job    = {
        name              => 'Retry-on-failure job',
        type              => 'photo',
        file_transport_id => $transport->id,
        matchpoint        => 'cardnumber',
    };

    # First run: no patron matches NOMATCH1 yet, so the import fully fails
    # (zero imports, one PATRON_NOT_FOUND error) - this must NOT be recorded
    # as a successful dedup run.
    $plugin->_run_photo_job($job);
    is( Koha::Patron::Images->search->count, 0, 'first run: no matching patron, nothing imported' );

    # Now the matching patron shows up (e.g. via a paired record job) and
    # the exact same, byte-for-byte unchanged file is processed again - it
    # must be retried, not dedup-skipped, since the prior run never
    # succeeded.
    my $patron = $builder->build_object( { class => 'Koha::Patrons', value => { cardnumber => 'NOMATCH1' } } );
    $plugin->_run_photo_job($job);
    ok(
        Koha::Patron::Images->find( $patron->borrowernumber ),
        'second run on unchanged content is retried (not dedup-skipped) since the first run fully failed'
    );
    is( Koha::Patron::Images->search->count, 1, 'exactly one image exists after the retried run succeeds' );

    $schema->storage->txn_rollback;
};

sub _build_photo_zip {
    my ($files) = @_;

    my $zip = Archive::Zip->new;
    while ( my ( $name, $content ) = each %$files ) {
        $zip->addString( $content, $name );
    }
    my ( $fh, $path ) = tempfile( SUFFIX => '.zip', UNLINK => 0 );
    close $fh;
    $zip->writeToFileNamed($path) == Archive::Zip::AZ_OK or die 'Unable to write test zip';
    return $path;
}
