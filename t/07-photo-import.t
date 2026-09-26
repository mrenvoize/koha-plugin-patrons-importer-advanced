#!/usr/bin/perl

use Modern::Perl;

use Test::More tests => 2;

use Koha::Database;
use t::lib::TestBuilder;

use GD;
use File::Temp;

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
