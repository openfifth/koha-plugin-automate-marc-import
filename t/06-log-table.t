#!/usr/bin/perl

use Modern::Perl;

use Test::More tests => 2;

use Koha::Database;

use t::lib::TestBuilder;

use Koha::Plugin::Com::OpenFifth::AutomateMarcImport;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

subtest '_log_table_name returns the qualified, memoized table name' => sub {
    plan tests => 2;

    my $plugin = Koha::Plugin::Com::OpenFifth::AutomateMarcImport->new( { enable_plugins => 1 } );

    is(
        $plugin->_log_table_name,
        'koha_plugin_com_openfifth_automatemarcimport_log',
        'table name is qualified by the plugin class and lowercased'
    );

    is(
        $plugin->_log_table_name,
        $plugin->{log_table},
        'the result is memoized on the plugin object'
    );
};

subtest 'install() creates the log table idempotently' => sub {
    plan tests => 3;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::OpenFifth::AutomateMarcImport->new( { enable_plugins => 1 } );
    my $table  = $plugin->_log_table_name;

    my $dbh = C4::Context->dbh;
    $dbh->do("DROP TABLE IF EXISTS $table");

    ok( $plugin->install(), 'install() returns true' );

    my ($exists) = $dbh->selectrow_array(
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ?",
        undef, $table
    );
    ok( $exists, 'the qualified table now exists' );

    ok( $plugin->install(), 'calling install() again does not die (CREATE TABLE IF NOT EXISTS)' );

    $dbh->do("DROP TABLE IF EXISTS $table");

    $schema->storage->txn_rollback;
};
