#!/usr/bin/perl

use Modern::Perl;

use Test::More tests => 6;
use Test::MockModule;

use File::Temp qw(tempdir);
use JSON       qw(encode_json);
use POSIX      qw(strftime);

use Koha::Database;
use Koha::File::Transports;

use t::lib::TestBuilder;

use Koha::Plugin::Com::OpenFifth::AutomateMarcImport;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

my $MARC_CONTENT = "00062nam a2200037 a 4500008004100000\x1e210101s2021    xx            000 0 eng d\x1e\x1d";

package MockSftpAttributes {

    sub new {
        my ( $class, %args ) = @_;
        return bless {%args}, $class;
    }
    sub size  { return $_[0]->{size} }
    sub mtime { return $_[0]->{mtime} }
    sub atime { return $_[0]->{atime} }
    sub perm  { return $_[0]->{perm} }
}

my @staged;
my $mock_plugin = Test::MockModule->new('Koha::Plugin::Com::OpenFifth::AutomateMarcImport');
$mock_plugin->mock(
    '_stage',
    sub {
        my ( $self, $path, $filename, $profile_id, $auto_commit ) = @_;
        push @staged, {
            path        => $path,
            filename    => $filename,
            profile_id  => $profile_id,
            auto_commit => $auto_commit,
            content     => slurp($path),
        };
        return 42;
    }
);

subtest 'local transport stages downloaded MARC files' => sub {
    plan tests => 6;

    $schema->storage->txn_begin;

    my $remote_dir = tempdir( CLEANUP => 1 );
    write_file( "$remote_dir/test.mrc",  $MARC_CONTENT );
    write_file( "$remote_dir/notes.txt", "not a marc file" );

    # A directory whose name happens to look like a MARC file: list_files()
    # now includes directories on every transport, so only an explicit
    # type check (not the file extension) can tell this apart from a real file.
    mkdir "$remote_dir/archive.mrc" or die "Cannot create archive.mrc dir: $!";

    my $transport = build_transport( 'local', $remote_dir );
    my $plugin    = build_plugin_with_setting($transport);

    @staged = ();
    $plugin->cronjob_nightly();

    is( scalar @staged,          1,             'exactly one file staged' );
    is( $staged[0]->{filename},  'test.mrc',    'MARC file staged, non-MARC file skipped' );
    is( $staged[0]->{profile_id}, 999,          'profile id passed through from setting' );
    is( $staged[0]->{content},   $MARC_CONTENT, 'downloaded content matches remote file' );
    ok( -f $plugin->{plugindir} . '/Archive/1/test.mrc', 'processed file archived per setting' );
    ok( !-f $staged[0]->{path}, 'temporary download removed after archiving' );

    $schema->storage->txn_rollback;
};

subtest 'sftp transport stages downloaded MARC files' => sub {
    plan tests => 5;

    $schema->storage->txn_begin;

    my $mock_sftp = mock_sftp_connection(
        [
            {
                filename => 'vendor.mrc',
                longname => '-rw-r--r-- 1 user group 62 Jan 01 12:00 vendor.mrc',
                a        => MockSftpAttributes->new(
                    size => length($MARC_CONTENT), mtime => time(), perm => oct('100644')
                ),
            },
            {
                filename => 'readme.txt',
                longname => '-rw-r--r-- 1 user group 10 Jan 01 12:00 readme.txt',
                a        => MockSftpAttributes->new( size => 10, mtime => time(), perm => oct('100644') ),
            },
            {
                # A directory whose name looks like a MARC file: only the
                # type derived from the SFTP Attributes' perm bits (not the
                # extension) can tell it apart from a real file now that
                # directories are included everywhere.
                filename => 'archive.mrc',
                longname => 'drwxr-xr-x 2 user group 4096 Jan 01 12:00 archive.mrc',
                a        => MockSftpAttributes->new( size => 4096, mtime => time(), perm => oct('040755') ),
            },
        ]
    );

    my $transport = build_transport( 'sftp', '/remote/downloads' );
    my $plugin    = build_plugin_with_setting($transport);

    @staged = ();
    $plugin->cronjob_nightly();

    is( scalar @staged,          1,             'exactly one file staged' );
    is( $staged[0]->{filename},  'vendor.mrc',  'MARC file staged, non-MARC file skipped' );
    is( $staged[0]->{profile_id}, 999,          'profile id passed through from setting' );
    is( $staged[0]->{content},   $MARC_CONTENT, 'downloaded content matches remote file' );
    ok( -f $plugin->{plugindir} . '/Archive/1/vendor.mrc', 'processed file archived per setting' );

    $schema->storage->txn_rollback;
};

subtest 'ftp transport stages downloaded MARC files' => sub {
    plan tests => 5;

    $schema->storage->txn_begin;

    my $listing_date = strftime( '%Y%m%d%H%M%S', gmtime( time() - 3600 ) );
    my $mock_ftp     = mock_ftp_connection(
        [
            "type=file;size=62;modify=$listing_date;UNIX.mode=0644; supplier.mrc",
            "type=file;size=10;modify=$listing_date;UNIX.mode=0644; readme.txt",

            # A directory whose name looks like a MARC file: only the type
            # fact (not the extension) can tell it apart from a real file
            # now that directories are included everywhere.
            "type=dir;modify=$listing_date; archive.mrc",
        ]
    );

    my $transport = build_transport( 'ftp', '/remote/downloads' );
    my $plugin    = build_plugin_with_setting($transport);

    @staged = ();
    $plugin->cronjob_nightly();

    is( scalar @staged,          1,              'exactly one file staged' );
    is( $staged[0]->{filename},  'supplier.mrc', 'MARC file staged, non-MARC file skipped' );
    is( $staged[0]->{profile_id}, 999,           'profile id passed through from setting' );
    is( $staged[0]->{content},   $MARC_CONTENT,  'downloaded content matches remote file' );
    ok( -f $plugin->{plugindir} . '/Archive/1/supplier.mrc', 'processed file archived per setting' );

    $schema->storage->txn_rollback;
};

subtest 'sftp connection failure skips transport without dying' => sub {
    plan tests => 2;

    $schema->storage->txn_begin;

    my $mock_sftp = mock_sftp_connection( [], error => 'Connection refused' );

    my $transport = build_transport( 'sftp', '/remote/downloads' );
    my $plugin    = build_plugin_with_setting($transport);

    @staged = ();
    my $lived = eval { $plugin->cronjob_nightly(); 1 };

    ok( $lived, 'cronjob survives a failed connection' );
    is( scalar @staged, 0, 'nothing staged when connection fails' );

    $schema->storage->txn_rollback;
};

subtest 'transport that dies on connect skips transport without dying' => sub {
    plan tests => 2;

    $schema->storage->txn_begin;

    # Koha 25.11's SFTP _abort_operation dies (missing JSON import in core),
    # so transport methods can throw as well as return undef
    my $mock_transport = Test::MockModule->new('Koha::File::Transport::SFTP');
    $mock_transport->mock( 'connect', sub { die "Undefined subroutine ...::encode_json" } );

    my $transport = build_transport( 'sftp', '/remote/downloads' );
    my $plugin    = build_plugin_with_setting($transport);

    @staged = ();
    my $lived = eval { $plugin->cronjob_nightly(); 1 };

    ok( $lived, 'cronjob survives a transport method that throws' );
    is( scalar @staged, 0, 'nothing staged when connect throws' );

    $schema->storage->txn_rollback;
};

subtest 'settings with different directory overrides on the same transport are fetched separately' => sub {
    plan tests => 5;

    $schema->storage->txn_begin;

    my $base_dir = tempdir( CLEANUP => 1 );
    my $dir_a    = "$base_dir/vendor_a";
    my $dir_b    = "$base_dir/vendor_b";
    mkdir $dir_a or die "Cannot create $dir_a: $!";
    mkdir $dir_b or die "Cannot create $dir_b: $!";
    write_file( "$dir_a/alpha.mrc", $MARC_CONTENT );
    write_file( "$dir_b/beta.mrc",  $MARC_CONTENT );

    # The transport's own directory is $dir_a; the second setting overrides to $dir_b
    my $transport = build_transport( 'local', $dir_a );
    my $plugin    = build_plugin_with_two_settings(
        $transport,
        { id => 1, profile_id => 111, download_directory => '' },        # uses the transport's own directory
        { id => 2, profile_id => 222, download_directory => $dir_b },    # overrides to a different directory
    );

    @staged = ();
    $plugin->cronjob_nightly();

    is( scalar @staged, 2, 'both directories were visited and both files staged' );

    my ($alpha) = grep { $_->{filename} eq 'alpha.mrc' } @staged;
    my ($beta)  = grep { $_->{filename} eq 'beta.mrc' } @staged;

    ok( $alpha, 'file from the transport-default directory was staged' );
    is( $alpha->{profile_id}, 111, 'default-directory file matched the setting with no override' );

    ok( $beta, 'file from the overridden directory was staged' );
    is( $beta->{profile_id}, 222, 'overridden-directory file matched the setting that owns that directory' );

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
                passive            => 1,
            },
        }
    );
}

sub build_plugin_with_setting {
    my ($transport) = @_;

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
                }
            ),
        }
    );

    return $plugin;
}

sub build_plugin_with_two_settings {
    my ( $transport, @settings ) = @_;

    my $plugin = Koha::Plugin::Com::OpenFifth::AutomateMarcImport->new( { enable_plugins => 1 } );
    $plugin->{plugindir} = tempdir( CLEANUP => 1 );

    my $transport_id = $transport->get_column( $plugin->{transport_column_name} );

    my $data_to_store = {
        selected_setting_ids => join( ',', map { $_->{id} } @settings ) . ',',
        last_setting_id      => $settings[-1]->{id},
    };

    foreach my $setting (@settings) {
        $data_to_store->{ $setting->{id} } = encode_json(
            {
                id                 => $setting->{id},
                name               => "Test setting $setting->{id}",
                description        => '',
                transport_id       => $transport_id,
                profile_id         => $setting->{profile_id},
                filenames          => '',
                auto_commit        => 0,
                framework          => '',
                overlay_framework  => '',
                download_directory => $setting->{download_directory},
            }
        );
    }

    $plugin->store_data($data_to_store);

    return $plugin;
}

sub mock_sftp_connection {
    my ( $listing, %opts ) = @_;

    my $mock = Test::MockModule->new('Net::SFTP::Foreign');
    $mock->mock( 'new',    sub { my $class = shift; return bless {}, $class } );
    $mock->mock( 'error',  sub { return $opts{error} } );
    $mock->mock( 'status', sub { return 0 } );
    $mock->mock( 'cwd',    sub { return '/' } );
    $mock->mock( 'setcwd', sub { return 1 } );
    $mock->mock( 'ls',     sub { return $listing } );
    $mock->mock(
        'get',
        sub {
            my ( $self, $remote, $local ) = @_;
            write_file( $local, $MARC_CONTENT );
            return 1;
        }
    );
    $mock->mock( 'abort',      sub { return 1 } );
    $mock->mock( 'disconnect', sub { return 1 } );
    $mock->mock( 'DESTROY',    sub { } );

    return $mock;
}

sub mock_ftp_connection {
    my ($listing) = @_;

    my $mock = Test::MockModule->new('Net::FTP');
    $mock->mock( 'new',       sub { my $class = shift; return bless {}, $class } );
    $mock->mock( 'login',     sub { return 1 } );
    $mock->mock( 'cwd',       sub { return 1 } );
    $mock->mock( 'pwd',       sub { return '/' } );
    $mock->mock( '_list_cmd', sub { my ( $s, $cmd ) = @_; return $cmd eq 'MLSD' ? $listing : undef; } );
    $mock->mock( 'message',   sub { return '' } );
    $mock->mock( 'status',    sub { return 0 } );
    $mock->mock( 'quit',      sub { return 1 } );
    $mock->mock( 'abort',     sub { return 1 } );
    $mock->mock(
        'get',
        sub {
            my ( $self, $remote, $local ) = @_;
            write_file( $local, $MARC_CONTENT );
            return $local;
        }
    );
    $mock->mock( 'DESTROY', sub { } );

    return $mock;
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
