#!/usr/bin/perl

use Modern::Perl;

use Test::More tests => 6;

use File::Temp qw(tempdir);

use C4::Context;
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

subtest '_hash_file computes an MD5 digest, and returns undef for a missing file' => sub {
    plan tests => 2;

    my $plugin = Koha::Plugin::Com::OpenFifth::AutomateMarcImport->new( { enable_plugins => 1 } );

    my $tmp = File::Temp->new;
    print $tmp "hello world";
    close $tmp;

    is( $plugin->_hash_file( $tmp->filename ), '5eb63bbbe01eeed093cb22bb8f5acdc3', 'MD5 matches known digest for "hello world"' );
    is( $plugin->_hash_file( '/no/such/file' ), undef, 'undef returned when the file cannot be opened' );
};

subtest '_log_attempt inserts a row, _get_last_successful_hash reads it back' => sub {
    plan tests => 4;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::OpenFifth::AutomateMarcImport->new( { enable_plugins => 1 } );
    my $table  = $plugin->_log_table_name;
    my $dbh    = C4::Context->dbh;
    $dbh->do("DROP TABLE IF EXISTS $table");
    $plugin->install();

    is( $plugin->_get_last_successful_hash( 1, 'vendor.mrc' ), undef, 'no rows yet: undef' );

    $plugin->_log_attempt(
        setting_id => 1, filename => 'vendor.mrc', file_hash => 'aaa111',
        outcome => 'success', batch_id => 42, error_message => undef,
    );
    is( $plugin->_get_last_successful_hash( 1, 'vendor.mrc' ), 'aaa111', 'most recent successful hash is returned' );

    $plugin->_log_attempt(
        setting_id => 1, filename => 'vendor.mrc', file_hash => 'bbb222',
        outcome => 'failure', batch_id => undef, error_message => 'boom',
    );
    is( $plugin->_get_last_successful_hash( 1, 'vendor.mrc' ), 'aaa111', 'a later failure row does not change the last *successful* hash' );

    $plugin->_log_attempt(
        setting_id => 1, filename => 'vendor.mrc', file_hash => 'ccc333',
        outcome => 'success', batch_id => 43, error_message => undef,
    );
    is( $plugin->_get_last_successful_hash( 1, 'vendor.mrc' ), 'ccc333', 'a later successful hash supersedes the earlier one' );

    $dbh->do("DROP TABLE IF EXISTS $table");
    $schema->storage->txn_rollback;
};

subtest '_archive_file splits successes and failures into separate directories' => sub {
    plan tests => 4;

    my $plugin = Koha::Plugin::Com::OpenFifth::AutomateMarcImport->new( { enable_plugins => 1 } );
    $plugin->{plugindir} = File::Temp::tempdir( CLEANUP => 1 );
    $plugin->store_data( { archive_retention_count => 10, archive_failed_retention_count => 10 } );

    my $success_src = File::Temp->new;
    print $success_src "success content";
    close $success_src;

    $plugin->_archive_file( $success_src->filename, 'ok.mrc', 42, 'success' );
    ok( -f $plugin->{plugindir} . '/Archive/42/Success/ok.mrc', 'successful file archived under Success/' );

    my $failure_src = File::Temp->new;
    print $failure_src "failure content";
    close $failure_src;

    $plugin->_archive_file( $failure_src->filename, 'bad.mrc', 42, 'failure' );
    ok( -f $plugin->{plugindir} . '/Archive/42/Failed/bad.mrc', 'failed file archived under Failed/' );

    # A filename that previously failed and now succeeds: the stale Failed/ copy is removed.
    my $retry_fail_src = File::Temp->new;
    print $retry_fail_src "still broken";
    close $retry_fail_src;
    $plugin->_archive_file( $retry_fail_src->filename, 'flaky.mrc', 42, 'failure' );
    ok( -f $plugin->{plugindir} . '/Archive/42/Failed/flaky.mrc', 'flaky.mrc failure archived first' );

    my $retry_success_src = File::Temp->new;
    print $retry_success_src "fixed now";
    close $retry_success_src;
    $plugin->_archive_file( $retry_success_src->filename, 'flaky.mrc', 42, 'success' );
    ok( !-f $plugin->{plugindir} . '/Archive/42/Failed/flaky.mrc', 'stale Failed/ copy removed once flaky.mrc succeeds' );
};

subtest '_apply_retention_policy prunes each directory independently' => sub {
    plan tests => 2;

    my $plugin = Koha::Plugin::Com::OpenFifth::AutomateMarcImport->new( { enable_plugins => 1 } );
    my $dir    = File::Temp::tempdir( CLEANUP => 1 );

    for my $i ( 1 .. 5 ) {
        write_test_file( "$dir/file$i.mrc", "content $i" );
        sleep 1 if $i < 5;    # ensure distinct mtimes for oldest-first eviction
    }

    $plugin->_apply_retention_policy( $dir, 3 );

    opendir( my $dh, $dir ) or die $!;
    my @remaining = grep { !/^\./ } readdir($dh);
    closedir($dh);

    is( scalar(@remaining), 3, 'only 3 files remain after applying a retention count of 3' );
    ok( ( grep { $_ eq 'file5.mrc' } @remaining ), 'the newest file survives retention pruning' );
};

sub write_test_file {
    my ( $path, $content ) = @_;
    open my $fh, '>', $path or die "Cannot write $path: $!";
    print $fh $content;
    close $fh;
};
