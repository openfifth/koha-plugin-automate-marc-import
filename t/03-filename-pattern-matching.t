#!/usr/bin/perl

use Modern::Perl;

use Test::More tests => 4;
use Time::HiRes qw(time);

use JSON qw(encode_json);

use Koha::Database;

use t::lib::TestBuilder;

use Koha::Plugin::Com::OpenFifth::AutomateMarcImport;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

subtest 'filenames field is matched as a regex, not a plain substring' => sub {
    plan tests => 2;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::OpenFifth::AutomateMarcImport->new( { enable_plugins => 1 } );
    $plugin->store_data(
        {
            selected_setting_ids => '1,',
            last_setting_id      => 1,
            1                    => encode_json(
                {
                    id                => 1,
                    name              => 'Anchored setting',
                    profile_id        => 999,
                    transport_id      => 1,
                    filenames         => "^dispatch",
                    auto_commit       => 0,
                    framework         => '',
                    overlay_framework => '',
                }
            ),
        }
    );

    my $matched = $plugin->_get_setting_by_filename( ['1'], 'dispatch_daily' );
    is( $matched->{id}, 1, 'anchored pattern matches a filename starting with the anchored text' );

    my $unmatched = $plugin->_get_setting_by_filename( ['1'], 'weekly_dispatch' );
    is( $unmatched, undef, 'anchored pattern does not match when the text is not at the start' );

    $schema->storage->txn_rollback;
};

subtest 'matching is case-insensitive' => sub {
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
                    name              => 'Case-insensitive setting',
                    profile_id        => 999,
                    transport_id      => 1,
                    filenames         => "VENDOR",
                    auto_commit       => 0,
                    framework         => '',
                    overlay_framework => '',
                }
            ),
        }
    );

    my $matched = $plugin->_get_setting_by_filename( ['1'], 'vendor_export' );
    is( $matched->{id}, 1, 'pattern matches regardless of case' );

    $schema->storage->txn_rollback;
};

subtest 'regex metacharacters are honoured, not escaped' => sub {
    plan tests => 2;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::OpenFifth::AutomateMarcImport->new( { enable_plugins => 1 } );
    $plugin->store_data(
        {
            selected_setting_ids => '1,',
            last_setting_id      => 1,
            1                    => encode_json(
                {
                    id                => 1,
                    name              => 'Escaped dot setting',
                    profile_id        => 999,
                    transport_id      => 1,
                    filenames         => 'vendor\.marc',
                    auto_commit       => 0,
                    framework         => '',
                    overlay_framework => '',
                }
            ),
        }
    );

    my $literal_match = $plugin->_get_setting_by_filename( ['1'], 'vendor.marc' );
    is( $literal_match->{id}, 1, 'escaped dot matches the literal character' );

    my $non_match = $plugin->_get_setting_by_filename( ['1'], 'vendorXmarc' );
    is( $non_match, undef, 'escaped dot does not match an arbitrary character' );

    $schema->storage->txn_rollback;
};

subtest 'a catastrophically backtracking pattern is aborted rather than hanging the run' => sub {
    plan tests => 2;

    $schema->storage->txn_begin;

    my $plugin = Koha::Plugin::Com::OpenFifth::AutomateMarcImport->new( { enable_plugins => 1 } );
    $plugin->store_data(
        {
            selected_setting_ids => '1,',
            last_setting_id      => 1,
            1                    => encode_json(
                {
                    id                => 1,
                    name              => 'Evil regex setting',
                    profile_id        => 999,
                    transport_id      => 1,
                    filenames         => '^(a+)+$',
                    auto_commit       => 0,
                    framework         => '',
                    overlay_framework => '',
                }
            ),
        }
    );

    my $evil_filename = ( 'a' x 35 ) . '!';

    my $started = time();
    my $result  = $plugin->_get_setting_by_filename( ['1'], $evil_filename );
    my $elapsed = time() - $started;

    ok( $elapsed < 5, "matching aborted quickly instead of hanging (took ${elapsed}s)" );
    is( $result, undef, 'timed-out pattern is treated as no match, not a fatal error' );

    $schema->storage->txn_rollback;
};
