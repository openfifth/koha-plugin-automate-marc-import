#!/usr/bin/perl

use Modern::Perl;

use Test::More tests => 7;
use Test::MockModule;

use File::Temp qw(tempdir);
use JSON       qw(encode_json);

use C4::Context;
use Koha::Database;
use Koha::File::Transports;

use t::lib::TestBuilder;

use Koha::Plugin::Com::OpenFifth::AutomateMarcImport;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

Koha::Plugin::Com::OpenFifth::AutomateMarcImport->new( { enable_plugins => 1 } )->install();

my $MARC_CONTENT = "00062nam a2200037 a 4500008004100000\x1e210101s2021    xx            000 0 eng d\x1e\x1d";

my @staged;
my $mock_plugin = Test::MockModule->new('Koha::Plugin::Com::OpenFifth::AutomateMarcImport');
$mock_plugin->mock(
    '_stage',
    sub {
        my ( $self, $path, $filename ) = @_;
        push @staged, { path => $path, filename => $filename };
        return 42;
    }
);

subtest 'post_process_action delete removes the remote file after a successful import' => sub {
    plan tests => 2;

    $schema->storage->txn_begin;

    my $remote_dir = tempdir( CLEANUP => 1 );
    write_file( "$remote_dir/vendor.mrc", $MARC_CONTENT );

    my $transport = build_transport( 'local', $remote_dir );
    my $plugin    = build_plugin_with_setting( $transport, { post_process_action => 'delete' } );

    @staged = ();
    $plugin->cronjob_nightly();

    is( scalar @staged, 1, 'file was staged' );
    ok( !-f "$remote_dir/vendor.mrc", 'remote file was deleted after successful import' );

    $schema->storage->txn_rollback;
};

subtest 'post_process_action rename appends the configured suffix' => sub {
    plan tests => 4;

    $schema->storage->txn_begin;

    my $remote_dir = tempdir( CLEANUP => 1 );
    write_file( "$remote_dir/vendor.mrc", $MARC_CONTENT );

    my $transport = build_transport( 'local', $remote_dir );
    my $plugin    = build_plugin_with_setting(
        $transport,
        { post_process_action => 'rename', post_process_rename_suffix => '.processed' }
    );

    @staged = ();
    $plugin->cronjob_nightly();

    is( scalar @staged, 1, 'file was staged' );
    ok( !-f "$remote_dir/vendor.mrc", 'original filename no longer present' );
    ok( -f "$remote_dir/vendor.mrc.processed", 'renamed file present with custom suffix' );
    is( slurp("$remote_dir/vendor.mrc.processed"), $MARC_CONTENT, 'renamed file content unchanged' );

    $schema->storage->txn_rollback;
};

subtest 'post_process_action rename defaults to .done when no suffix is configured' => sub {
    plan tests => 2;

    $schema->storage->txn_begin;

    my $remote_dir = tempdir( CLEANUP => 1 );
    write_file( "$remote_dir/vendor.mrc", $MARC_CONTENT );

    my $transport = build_transport( 'local', $remote_dir );
    my $plugin    = build_plugin_with_setting( $transport, { post_process_action => 'rename' } );

    @staged = ();
    $plugin->cronjob_nightly();

    is( scalar @staged, 1, 'file was staged' );
    ok( -f "$remote_dir/vendor.mrc.done", 'default .done suffix applied' );

    $schema->storage->txn_rollback;
};

subtest 'post_process_action move relocates the file into an existing subdirectory' => sub {
    plan tests => 3;

    $schema->storage->txn_begin;

    my $remote_dir  = tempdir( CLEANUP => 1 );
    my $archive_dir = "$remote_dir/Processed";
    mkdir $archive_dir or die "Cannot create $archive_dir: $!";
    write_file( "$remote_dir/vendor.mrc", $MARC_CONTENT );

    my $transport = build_transport( 'local', $remote_dir );
    my $plugin    = build_plugin_with_setting(
        $transport,
        { post_process_action => 'move', post_process_move_directory => 'Processed' }
    );

    @staged = ();
    $plugin->cronjob_nightly();

    is( scalar @staged, 1, 'file was staged' );
    ok( !-f "$remote_dir/vendor.mrc", 'file no longer at its original location' );
    ok( -f "$archive_dir/vendor.mrc", 'file moved into the archive directory' );

    $schema->storage->txn_rollback;
};

subtest 'post_process_action move logs a warning but does not fail the import when the target directory is missing' => sub {
    plan tests => 3;

    $schema->storage->txn_begin;

    my $remote_dir = tempdir( CLEANUP => 1 );
    write_file( "$remote_dir/vendor.mrc", $MARC_CONTENT );

    my $transport = build_transport( 'local', $remote_dir );
    my $plugin    = build_plugin_with_setting(
        $transport,
        { post_process_action => 'move', post_process_move_directory => 'DoesNotExist' }
    );

    @staged = ();
    my $lived = eval { $plugin->cronjob_nightly(); 1 };

    ok( $lived, 'cronjob survives a move to a non-existent directory' );
    ok( -f "$remote_dir/vendor.mrc", 'file remains at its original location' );

    my $table = $plugin->_log_table_name;
    my ($success_count) = C4::Context->dbh->selectrow_array("SELECT COUNT(*) FROM $table WHERE outcome = 'success'");
    is( $success_count, 1, 'the import itself is still logged as a success despite the failed cleanup' );

    $schema->storage->txn_rollback;
};

subtest 'post_process_action none (or unset, for existing settings) leaves the remote file untouched' => sub {
    plan tests => 2;

    $schema->storage->txn_begin;

    my $remote_dir = tempdir( CLEANUP => 1 );
    write_file( "$remote_dir/vendor.mrc", $MARC_CONTENT );

    my $transport = build_transport( 'local', $remote_dir );
    my $plugin    = build_plugin_with_setting($transport);    # no post_process_action key at all

    @staged = ();
    $plugin->cronjob_nightly();

    is( scalar @staged, 1, 'file was staged' );
    ok( -f "$remote_dir/vendor.mrc", 'remote file untouched when no action is configured' );

    $schema->storage->txn_rollback;
};

subtest 'the configured action is never triggered on a failed import' => sub {
    plan tests => 2;

    $schema->storage->txn_begin;

    my $remote_dir = tempdir( CLEANUP => 1 );
    write_file( "$remote_dir/broken.mrc", $MARC_CONTENT );

    my $transport = build_transport( 'local', $remote_dir );
    my $plugin    = build_plugin_with_setting( $transport, { post_process_action => 'delete' } );

    $mock_plugin->mock( '_stage', sub { die "simulated staging failure\n" } );

    @staged = ();
    $plugin->cronjob_nightly();

    is( scalar @staged, 0, 'nothing staged when _stage dies' );
    ok(
        -f "$remote_dir/broken.mrc",
        'remote file left untouched after a failed import despite a delete action being configured'
    );

    # Restore the working mock for any subtests that might run after this one.
    $mock_plugin->mock(
        '_stage',
        sub {
            my ( $self, $path, $filename ) = @_;
            push @staged, { path => $path, filename => $filename };
            return 42;
        }
    );

    $schema->storage->txn_rollback;
};

sub build_transport {
    my ( $type, $download_directory ) = @_;

    return $builder->build_object(
        {
            class => 'Koha::File::Transports',
            value => {
                transport          => $type,
                host               => 'localhost',
                port               => 22,
                user_name          => 'testuser',
                password           => undef,
                key_file           => undef,
                download_directory => $download_directory,
                upload_directory   => '',
                passive             => 1,
            },
        }
    );
}

sub build_plugin_with_setting {
    my ( $transport, $overrides ) = @_;
    $overrides //= {};

    my $plugin = Koha::Plugin::Com::OpenFifth::AutomateMarcImport->new( { enable_plugins => 1 } );
    $plugin->{plugindir} = tempdir( CLEANUP => 1 );

    my $transport_id = $transport->get_column( $plugin->{transport_column_name} );
    $plugin->store_data(
        {
            selected_setting_ids => '1,',
            last_setting_id      => 1,
            1                    => encode_json(
                {
                    id                => 1,
                    name              => 'Test setting',
                    description       => '',
                    transport_id      => $transport_id,
                    profile_id        => 999,
                    filenames         => '',
                    auto_commit       => 0,
                    framework         => '',
                    overlay_framework => '',
                    %{$overrides},
                }
            ),
        }
    );

    return $plugin;
}

sub write_file {
    my ( $path, $content ) = @_;

    open my $fh, '>', $path or die "Cannot write $path: $!";
    binmode $fh;
    print $fh $content;
    close $fh;
}

sub slurp {
    my ($path) = @_;

    open my $fh, '<', $path or return;
    binmode $fh;
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}
