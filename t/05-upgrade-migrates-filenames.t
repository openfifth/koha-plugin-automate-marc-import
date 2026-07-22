#!/usr/bin/perl

use Modern::Perl;

use Test::More tests => 4;

use JSON qw(decode_json encode_json);

use Koha::Database;

use t::lib::TestBuilder;

use Koha::Plugin::Com::OpenFifth::AutomateMarcImport;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

subtest 'upgrade migrates a literal pattern to an equivalent escaped regex' => sub {
    plan tests => 4;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::OpenFifth::AutomateMarcImport->new( { enable_plugins => 1 } );
    $plugin->store_data(
        {
            selected_setting_ids => '1,',
            last_setting_id      => 1,
            1                    => encode_json(
                {
                    id                => 1,
                    name              => 'Legacy literal setting',
                    profile_id        => 999,
                    transport_id      => 1,
                    filenames         => 'vendor.marc',
                    auto_commit       => 0,
                    framework         => '',
                    overlay_framework => '',
                }
            ),
        }
    );

    # Koha::Plugins::Base->new() auto-runs upgrade() itself whenever the
    # dev DB's stored __INSTALLED_VERSION__ is behind $VERSION, which may
    # already have happened above before this setting existed. Force a known
    # "not yet migrated" starting point so this test is deterministic
    # regardless of that incidental state.
    $plugin->store_data( { filenames_migrated_to_regex => 0 } );
    $plugin->upgrade();

    my $stored = decode_json( $plugin->retrieve_data('1') );
    is( $stored->{filenames}, 'vendor\.marc', 'stored pattern is quotemeta-escaped' );

    my $still_matches = $plugin->_get_setting_by_filename( ['1'], 'newvendor.marcfile' );
    is( $still_matches->{id}, 1, 'migrated pattern still matches what the old substring search matched' );

    my $no_longer_over_matches = $plugin->_get_setting_by_filename( ['1'], 'vendorXmarc' );
    is( $no_longer_over_matches, undef, 'migrated pattern no longer treats the dot as "any character"' );

    ok( $plugin->retrieve_data('filenames_migrated_to_regex'), 'migration is marked as done' );

    $schema->storage->txn_rollback;
};

subtest 'upgrade is idempotent' => sub {
    plan tests => 1;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::OpenFifth::AutomateMarcImport->new( { enable_plugins => 1 } );
    $plugin->store_data(
        {
            selected_setting_ids => '1,',
            last_setting_id      => 1,
            1                    => encode_json(
                {
                    id                => 1,
                    name              => 'Legacy literal setting',
                    profile_id        => 999,
                    transport_id      => 1,
                    filenames         => 'vendor.marc',
                    auto_commit       => 0,
                    framework         => '',
                    overlay_framework => '',
                }
            ),
        }
    );

    $plugin->store_data( { filenames_migrated_to_regex => 0 } );    # force a known starting point (see subtest 1)
    $plugin->upgrade();
    $plugin->upgrade();    # calling again must not double-escape

    my $stored = decode_json( $plugin->retrieve_data('1') );
    is( $stored->{filenames}, 'vendor\.marc', 'pattern is not re-escaped on a second upgrade() call' );

    $schema->storage->txn_rollback;
};

subtest 'upgrade tolerates a malformed setting without dying' => sub {
    plan tests => 3;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::OpenFifth::AutomateMarcImport->new( { enable_plugins => 1 } );
    $plugin->store_data(
        {
            selected_setting_ids => '1,2,',
            last_setting_id      => 2,
            1                    => encode_json(
                {
                    id                => 1,
                    name              => 'Good setting',
                    profile_id        => 999,
                    transport_id      => 1,
                    filenames         => 'daily.update',
                    auto_commit       => 0,
                    framework         => '',
                    overlay_framework => '',
                }
            ),
            2 => 'this is not valid json{',
        }
    );

    $plugin->store_data( { filenames_migrated_to_regex => 0 } );    # force a known starting point (see subtest 1)
    my $survived = eval { $plugin->upgrade(); 1 };
    ok( $survived, 'upgrade() does not die when a setting blob is malformed' );

    my $stored = decode_json( $plugin->retrieve_data('1') );
    is( $stored->{filenames}, 'daily\.update', 'the well-formed setting is still migrated correctly' );

    is( $plugin->retrieve_data('2'), 'this is not valid json{', 'the malformed setting is left untouched rather than corrupted further' );

    $schema->storage->txn_rollback;
};

subtest 'upgrade leaves a blank/default filenames field untouched' => sub {
    plan tests => 1;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::OpenFifth::AutomateMarcImport->new( { enable_plugins => 1 } );
    $plugin->store_data(
        {
            selected_setting_ids => '1,',
            last_setting_id      => 1,
            1                    => encode_json(
                {
                    id                => 1,
                    name              => 'Default setting',
                    profile_id        => 999,
                    transport_id      => 1,
                    filenames         => '',
                    auto_commit       => 0,
                    framework         => '',
                    overlay_framework => '',
                }
            ),
        }
    );

    $plugin->store_data( { filenames_migrated_to_regex => 0 } );    # force a known starting point (see subtest 1)
    $plugin->upgrade();

    my $stored = decode_json( $plugin->retrieve_data('1') );
    is( $stored->{filenames}, '', 'blank filenames field remains blank' );

    $schema->storage->txn_rollback;
};
