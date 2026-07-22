#!/usr/bin/perl

use Modern::Perl;

use Test::More tests => 1;

use JSON qw(encode_json);
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

subtest '_get_import_history resolves setting names, orders, and filters' => sub {
    plan tests => 6;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::OpenFifth::AutomateMarcImport->new( { enable_plugins => 1 } );
    my $table  = $plugin->_log_table_name;
    my $dbh    = C4::Context->dbh;
    $dbh->do("DROP TABLE IF EXISTS $table");
    $plugin->install();

    $plugin->store_data( {
        selected_setting_ids => '1,',
        last_setting_id      => 1,
        1                    => encode_json( { id => 1, name => 'Vendor A', profile_id => 999, transport_id => 1, filenames => '', auto_commit => 0, framework => '', overlay_framework => '' } ),
    } );

    $plugin->_log_attempt( setting_id => 1, filename => 'a.mrc', file_hash => 'h1', outcome => 'success', batch_id => 10, error_message => undef );
    $plugin->_log_attempt( setting_id => 1, filename => 'b.mrc', file_hash => 'h2', outcome => 'failure', batch_id => undef, error_message => 'parse error' );
    $plugin->_log_attempt( setting_id => 99, filename => 'c.mrc', file_hash => 'h3', outcome => 'success', batch_id => 11, error_message => undef );    # setting 99 doesn't exist

    my @all = $plugin->_get_import_history();
    is( scalar @all, 3, 'all three rows returned with no filters' );
    is( $all[0]->{filename}, 'c.mrc', 'most recent row (by insertion order) is first' );
    is( $all[0]->{setting_name}, '(deleted setting #99)', 'a row referencing a since-deleted setting gets a fallback label' );
    is( $all[2]->{setting_name}, 'Vendor A', 'a row referencing an existing setting resolves its name' );

    my @successes = $plugin->_get_import_history( outcome => 'success' );
    is( scalar @successes, 2, 'outcome filter narrows to successes only' );

    my @setting_1 = $plugin->_get_import_history( setting_id => 1 );
    is( scalar @setting_1, 2, 'setting_id filter narrows to that setting only' );

    cleanup_plugin_data( $plugin, '1', 'selected_setting_ids', 'last_setting_id' );

    $dbh->do("DROP TABLE IF EXISTS $table");
    $schema->storage->txn_rollback;
};
