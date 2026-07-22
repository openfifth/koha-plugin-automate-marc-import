#!/usr/bin/perl

use Modern::Perl;

use Test::More tests => 2;

use CGI;
use Koha::Database;
use Koha::File::Transports;
use Koha::ImportBatchProfiles;

use t::lib::TestBuilder;

use Koha::Plugin::Com::OpenFifth::AutomateMarcImport;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

sub build_cgi_for_filenames {
    my ( $transport_id, $profile_id, $filenames ) = @_;
    return CGI->new(
        {
            name                  => 'Vendor',
            description           => '',
            selected_transport_id => $transport_id,
            profile_id            => $profile_id,
            filenames             => $filenames,
            auto_commit           => 0,
            framework             => '',
            overlay_framework     => '',
        }
    );
}

subtest '_sanitize_filenames preserves regex syntax' => sub {
    plan tests => 5;

    my $plugin = Koha::Plugin::Com::OpenFifth::AutomateMarcImport->new( { enable_plugins => 1 } );

    is(
        $plugin->_sanitize_filenames("vendor\\.marc"),
        'vendor\.marc',
        'backslash escapes are preserved (needed for regex escaping)'
    );

    is(
        $plugin->_sanitize_filenames('[A-Z]{3}\d+'),
        '[A-Z]{3}\d+',
        'case and character-class syntax is preserved, not lowercased'
    );

    is(
        $plugin->_sanitize_filenames("weekly/dispatch"),
        'weekly/dispatch',
        'forward slash is preserved'
    );

    is(
        $plugin->_sanitize_filenames("bad\x01\x02chars"),
        'badchars',
        'control characters are still stripped'
    );

    is(
        $plugin->_sanitize_filenames( 'x' x 1500 ),
        'x' x 1000,
        'length is still capped at 1000 characters'
    );
};

subtest 'saving a setting rejects invalid or dangerous regex patterns' => sub {
    plan tests => 4;

    $schema->storage->txn_begin;

    my $transport = $builder->build_object( { class => 'Koha::File::Transports', value => { transport => 'sftp', host => 'localhost', port => 22, user_name => 'testuser', password => undef, key_file => undef, download_directory => '/incoming', upload_directory => '', passive => 1 } } );
    my $profile = $builder->build_object( { class => 'Koha::ImportBatchProfiles', value => { name => 'Test profile for validation test' } } );

    my $plugin       = Koha::Plugin::Com::OpenFifth::AutomateMarcImport->new( { enable_plugins => 1 } );
    my $transport_id = $transport->get_column( $plugin->{transport_column_name} );

    my $uncompilable = build_cgi_for_filenames( $transport_id, $profile->id, "dispatch\n(unbalanced" );
    my $result1      = $plugin->_save_setting($uncompilable);
    ok( !$result1->{success}, 'a line that does not compile as a regex is rejected' );
    like( $result1->{error}, qr/pattern/i, 'error message mentions the invalid pattern' );

    my $embedded_code = build_cgi_for_filenames( $transport_id, $profile->id, 'dispatch(?{ system("id") })' );
    my $result2        = $plugin->_save_setting($embedded_code);
    ok( !$result2->{success}, 'a pattern containing an embedded code block is rejected' );

    my $valid   = build_cgi_for_filenames( $transport_id, $profile->id, "^dispatch\nvendor\\.marc" );
    my $result3 = $plugin->_save_setting($valid);
    ok( $result3->{success}, 'valid regex patterns are accepted' );

    $schema->storage->txn_rollback;
};
