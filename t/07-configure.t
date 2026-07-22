#!/usr/bin/perl

use Modern::Perl;

use Test::More tests => 1;

use CGI;
use Koha::Database;

use t::lib::TestBuilder;

use Koha::Plugin::Com::OpenFifth::AutomateMarcImport;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

sub cleanup_plugin_data {
    my ( $plugin, @keys ) = @_;
    my $dbh = C4::Context->dbh;
    for my $key (@keys) {
        $dbh->do(
            "DELETE FROM plugin_data WHERE plugin_class = ? AND plugin_key = ?",
            undef, ref($plugin), $key
        );
    }
}

subtest 'configure() saves archive_failed_retention_count' => sub {
    plan tests => 2;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::OpenFifth::AutomateMarcImport->new( { enable_plugins => 1 } );
    $plugin->{cgi} = CGI->new( {
        save                            => 1,
        archive_retention_count         => 15,
        archive_failed_retention_count  => 5,
    } );

    eval { $plugin->configure(); };

    is( $plugin->retrieve_data('archive_retention_count'), 15, 'existing retention count still saves correctly' );
    is( $plugin->retrieve_data('archive_failed_retention_count'), 5, 'new failed-retention count saves correctly' );

    cleanup_plugin_data( $plugin, 'archive_retention_count', 'archive_failed_retention_count' );

    $schema->storage->txn_rollback;
};
