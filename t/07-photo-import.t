#!/usr/bin/perl

use Modern::Perl;

use Test::More tests => 1;

use Koha::Database;
use t::lib::TestBuilder;

use Koha::Plugin::Com::ByWaterSolutions::PatronsImporterAdvanced;

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
