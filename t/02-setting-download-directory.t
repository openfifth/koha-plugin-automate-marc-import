#!/usr/bin/perl

use Modern::Perl;

use Test::More tests => 2;

use JSON qw(decode_json);
use CGI;

use Koha::Database;
use Koha::File::Transports;
use Koha::ImportBatchProfiles;

use t::lib::TestBuilder;

use Koha::Plugin::Com::OpenFifth::AutomateMarcImport;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

subtest 'download_directory is sanitized and stored on save' => sub {
    plan tests => 3;

    $schema->storage->txn_begin;

    my $transport = $builder->build_object({
        class => 'Koha::File::Transports',
        value => {
            transport           => 'sftp',
            host                => 'localhost',
            port                => 22,
            user_name           => 'testuser',
            password            => undef,
            key_file            => undef,
            download_directory  => '/default/incoming',
            upload_directory    => '',
            passive             => 1,
        },
    });
    my $profile = $builder->build_object({
        class => 'Koha::ImportBatchProfiles',
        value => { name => 'Test profile for download dir test' },
    });

    my $plugin = Koha::Plugin::Com::OpenFifth::AutomateMarcImport->new( { enable_plugins => 1 } );
    my $transport_id = $transport->get_column( $plugin->{transport_column_name} );

    my $cgi = CGI->new({
        name                  => 'Vendor A',
        description           => '',
        selected_transport_id => $transport_id,
        profile_id            => $profile->id,
        filenames             => '',
        auto_commit           => 0,
        framework             => '',
        overlay_framework     => '',
        download_directory    => "  /vendor/incoming\x01\r\n  ",
    });

    my $result = $plugin->_save_setting($cgi);
    ok( $result->{success}, 'setting saved successfully' );

    my $setting_id = $plugin->retrieve_data('last_setting_id');
    my $stored     = decode_json( $plugin->retrieve_data($setting_id) );

    is( $stored->{download_directory}, '/vendor/incoming', 'control characters stripped, whitespace trimmed' );

    my $long_cgi = CGI->new({
        name                  => 'Vendor B',
        description           => '',
        selected_transport_id => $transport_id,
        profile_id            => $profile->id,
        filenames             => '',
        auto_commit           => 0,
        framework             => '',
        overlay_framework     => '',
        download_directory    => ( 'x' x 600 ),
    });
    $plugin->_save_setting($long_cgi);
    my $long_setting_id = $plugin->retrieve_data('last_setting_id');
    my $long_stored     = decode_json( $plugin->retrieve_data($long_setting_id) );

    is( length( $long_stored->{download_directory} ), 500, 'download_directory is capped at 500 characters' );

    $schema->storage->txn_rollback;
};

subtest 'download_directory defaults to empty string when omitted' => sub {
    plan tests => 1;

    $schema->storage->txn_begin;

    my $transport = $builder->build_object({
        class => 'Koha::File::Transports',
        value => {
            transport           => 'sftp',
            host                => 'localhost',
            port                => 22,
            user_name           => 'testuser',
            password            => undef,
            key_file            => undef,
            download_directory  => '/default/incoming',
            upload_directory    => '',
            passive             => 1,
        },
    });
    my $profile = $builder->build_object({
        class => 'Koha::ImportBatchProfiles',
        value => { name => 'Test profile without override' },
    });

    my $plugin = Koha::Plugin::Com::OpenFifth::AutomateMarcImport->new( { enable_plugins => 1 } );
    my $transport_id = $transport->get_column( $plugin->{transport_column_name} );

    my $cgi = CGI->new({
        name                  => 'Vendor C',
        description           => '',
        selected_transport_id => $transport_id,
        profile_id            => $profile->id,
        filenames             => '',
        auto_commit           => 0,
        framework             => '',
        overlay_framework     => '',
    });

    $plugin->_save_setting($cgi);
    my $setting_id = $plugin->retrieve_data('last_setting_id');
    my $stored     = decode_json( $plugin->retrieve_data($setting_id) );

    is( $stored->{download_directory}, '', 'download_directory defaults to empty string' );

    $schema->storage->txn_rollback;
};
