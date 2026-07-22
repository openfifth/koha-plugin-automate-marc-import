package Koha::Plugin::Com::OpenFifth::AutomateMarcImport;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

# Core Perl modules
use Digest::MD5;
use File::Basename qw(dirname fileparse);
use File::Copy qw(copy);
use File::Listing qw(parse_dir);
use File::Path qw(make_path);
use JSON qw( encode_json decode_json );
use Scalar::Util qw(looks_like_number);
use Try::Tiny qw(catch try);

# Koha modules
use C4::Context;
use C4::ImportBatch
    qw( RecordsFromISO2709File RecordsFromMARCXMLFile BatchStageMarcRecords BatchCommitRecords SetImportBatchMatcher SetImportBatchOverlayAction SetImportBatchNoMatchAction SetImportBatchItemAction BatchFindDuplicates GetAllImportBatches );
use C4::MarcModificationTemplates qw( GetModificationTemplates );
use C4::Matcher;
use Koha::BiblioFrameworks;
use Koha::Database;
use Koha::File::Transports;
use Koha::ImportBatches;
use Koha::ImportBatchProfiles;
use Koha::Logger;
use Koha::UploadedFile;

our $VERSION         = '1.4.0';

our $metadata = {
    name            => 'Automate Marc Import',
    author          => 'Open Fifth',
    date_authored   => '2022-05-19',
    date_updated    => '2026-07-22',
    minimum_version => '25.11.00.000',
    maximum_version => undef,
    version         => $VERSION,
    description     => 'A Koha plugin to automate the import and staging of MARC files by enabling nightly retrieval via SFTP from vendor sites. Features include MD5-based file deduplication, automatic archiving of processed files, MARC modification template support, and optional auto-commit for automated importing.',
};

# IMPLEMENTED PLUGIN HOOKS

sub new {
    my ( $class, $args ) = @_;

    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    my $self = $class->SUPER::new($args);
    $self->{cgi} = CGI->new();
    $self->{logger} = Koha::Logger->get;
    $self->_set_plugin_dir();
    $self->_detect_transport_column_name();

    return $self;
}

sub tool {
    my ( $self, $args  ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template( { file => 'tool.tt' } );

    # save setting OR
    if ( defined $cgi->param('op') && $cgi->param('op') eq 'cud-save') {
        my $save_result = $self->_save_setting( $cgi );
        # handle successful setting creation OR
        if ($save_result->{success}) {
            my $redirect_url = "/cgi-bin/koha/plugins/run.pl?class=" . $cgi->param('class') . "&method=tool";
            print $cgi->redirect($redirect_url);
            return;
        } else {
            # Display error message to user
            my $selected_setting_id = $cgi->param('selected_setting_id');
            my $op = defined $selected_setting_id && $selected_setting_id ne '' ? 'edit_form' : 'add_form';

            # Build lookup data for templates and matchers (for JavaScript use)
            my ($template_list, $matcher_list) = $self->_get_template_and_matcher_lists();

            $template->param(
                error_message => $save_result->{error},
                op => $op,
                selected_setting_id => $selected_setting_id,
                # Pre-populate form with submitted values
                name => $cgi->param('name'),
                description => $cgi->param('description'),
                selected_transport_id => $cgi->param('selected_transport_id'),
                profile_id => $cgi->param('profile_id'),
                filenames => $cgi->param('filenames'),
                auto_commit => $cgi->param('auto_commit'),
                framework => $cgi->param('framework'),
                overlay_framework => $cgi->param('overlay_framework'),
                download_directory => $cgi->param('download_directory'),
                available_profiles => Koha::ImportBatchProfiles->search(),
                available_transport => Koha::File::Transports->search(),
                available_frameworks => Koha::BiblioFrameworks->search({}, { order_by => ['frameworktext'] }),
                marc_modification_templates => $template_list,
                record_matchers => $matcher_list,
            );
            $self->output_html( $template->output() );
            return;
        }
    }

    # ..delete setting OR
    if ( defined $cgi->param('op') && $cgi->param('op') eq 'cud-delete') {
        $self->_delete_setting( $cgi );
        my $redirect_url = "/cgi-bin/koha/plugins/run.pl?class=" . $cgi->param('class') . "&method=tool";
        print $cgi->redirect($redirect_url);
        return;
    }

    # ..edit setting OR
    if ( defined $cgi->param('op') && $cgi->param('op') eq 'edit') {
        my $selected_setting_id = $cgi->param('selected_setting_id');
        my $setting_data = decode_json($self->retrieve_data( $selected_setting_id ));

        # Build lookup data for templates and matchers (for JavaScript use)
        my ($template_list, $matcher_list) = $self->_get_template_and_matcher_lists();

        $template->param(
            op => 'edit_form',
            selected_setting_id => $selected_setting_id,
            name => $setting_data->{name},
            description => $setting_data->{description},
            selected_transport_id => $setting_data->{transport_id},
            profile_id => $setting_data->{profile_id},
            filenames => $setting_data->{filenames},
            auto_commit => $setting_data->{auto_commit},
            framework => $setting_data->{framework},
            overlay_framework => $setting_data->{overlay_framework},
            download_directory => $setting_data->{download_directory},
            available_profiles => Koha::ImportBatchProfiles->search(),
            available_transport => Koha::File::Transports->search(),
            available_frameworks => Koha::BiblioFrameworks->search({}, { order_by => ['frameworktext'] }),
            marc_modification_templates => $template_list,
            record_matchers => $matcher_list,
        );
        $self->output_html( $template->output() );
        return;
    }

    # ..display settings list (default action)
    my @automate_marc_import_plugin_settings = $self->_get_settings_for_display();
    if ($cgi->param('op')) {
        $template->param(op => $cgi->param('op'))
    }

    # Build lookup data for templates and matchers (for JavaScript use in add_form)
    my ($template_list, $matcher_list) = $self->_get_template_and_matcher_lists();

    $template->param(
        available_profiles => Koha::ImportBatchProfiles->search(),
        available_transport => Koha::File::Transports->search(),
        available_frameworks => Koha::BiblioFrameworks->search({}, { order_by => ['frameworktext'] }),
        automate_marc_import_plugin_settings => \@automate_marc_import_plugin_settings,
        automate_marc_import_plugin_settings_count => scalar @automate_marc_import_plugin_settings,
        marc_modification_templates => $template_list,
        record_matchers => $matcher_list,
    );
    $self->output_html( $template->output() );
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    my $template = $self->get_template({ file => 'configure.tt' });

    if ($cgi->param('save')) {
        my $retention_count = $cgi->param('archive_retention_count');

        # Validate: must be non-negative integer, max 100
        if (defined $retention_count && $retention_count =~ /^\d+$/ && $retention_count >= 0 && $retention_count <= 100) {
            $self->store_data({ archive_retention_count => int($retention_count) });
            $template->param(success_message => 'Configuration saved successfully.');
        } else {
            $template->param(error_message => 'Retention count must be a number between 0 and 100.');
        }
    }

    $template->param(
        archive_retention_count => $self->retrieve_data('archive_retention_count') // 10
    );

    $self->output_html($template->output());
}

sub cronjob_nightly {
    my ( $self ) = @_;

    # Ensure required directories exist
    $self->_ensure_plugin_directories();

    foreach my $group ( $self->_get_transport_directory_groups() ) {
        my $transport_id = $group->{transport_id};
        my $directory    = $group->{directory};
        my $setting_ids  = $group->{setting_ids};

        my $transport = Koha::File::Transports->find($transport_id);
        if (!$transport) {
            $self->{logger}->error("Transport with ID $transport_id not found, skipping");
            next;
        }

        my $transport_name = $transport->name || "Transport $transport_id";

        # Check a download directory is configured (transport default or setting override)
        if ($directory eq '') {
            $self->{logger}->error("Transport '$transport_name' does not have a download directory set, skipping");
            next;
        }

        unless ( $self->_call_transport( $transport, 'connect' ) ) {
            $self->{logger}->error("Failed to connect to transport '$transport_name': " . $self->_transport_error($transport));
            next;
        }
        $self->{logger}->info("Connected to transport '$transport_name'");

        unless ( $self->_call_transport( $transport, 'change_directory', $directory ) ) {
            $self->{logger}->error("Failed to change to download directory '$directory' for transport '$transport_name': " . $self->_transport_error($transport));
            next;
        }

        my $file_list = $self->_call_transport( $transport, 'list_files' );
        unless ($file_list) {
            $self->{logger}->error("Failed to list files for transport '$transport_name': " . $self->_transport_error($transport));
            next;
        }

        next unless @{$file_list};

        foreach my $filehash (@{$file_list}) {

            # Directories are now included in list_files() results across all
            # transport backends; only real files are ever importable.
            if ( ( $filehash->{type} // '' ) eq 'directory' ) {
                next;
            }

            my $filename = $self->_file_entry_name($filehash);

            # Check if file has a supported MARC extension
            if (!$self->_is_supported_marc_file($filename)) {
                next;
            }
            if (!$self->_was_modified_since_last_fetch( $filehash )) {
                next;
            }

            # Get setting data early so we can use setting_id for archive paths
            my @split_filename = split(/\./, $filename );
            my $setting_data = $self->_get_setting_by_filename($setting_ids, $split_filename[0]);
            my $setting_id = $setting_data->{id};
            my $profile_id = $setting_data->{profile_id};
            my $auto_commit = $setting_data->{auto_commit} // 0;
            my $framework = $setting_data->{framework} // '';
            my $overlay_framework = $setting_data->{overlay_framework} // '';

            # Ensure per-setting archive directory exists
            $self->_ensure_plugin_directories($setting_id);

            # Use MD5 hash of filename for unique local storage path
            my $file_hashvalue = Digest::MD5::md5_hex($filename);
            my $localFile = Koha::UploadedFile->new({
                hashvalue          => $file_hashvalue,
                filename           => $filename,
                dir                => $self->{plugindir},
                filesize           => $self->_file_entry_size($filehash),
                owner              => undef,
                uploadcategorycode => undef,
                public             => undef,
                permanent          => undef,
            });

            $self->_make_directory( dirname( $localFile->full_path() ) );

            unless ( $self->_call_transport( $transport, 'download_file', $filename, $localFile->full_path() ) ) {
                $self->{logger}->error("Failed to download file '$filename' from transport '$transport_name': " . $self->_transport_error($transport));
                next;
            }
            $self->{logger}->info("Downloaded file '$filename' from transport '$transport_name'");

            my $content_hash = $self->_hash_file( $localFile->full_path() );

            # Only successful imports are deduplicated by content hash — a
            # filename whose last attempt failed is always retried, even with
            # identical content, so a permanently-broken file keeps being
            # logged rather than silently swallowed after the first failure.
            if ( defined $content_hash ) {
                my $last_success_hash = $self->_get_last_successful_hash( $setting_id, $filename );
                if ( defined $last_success_hash && $last_success_hash eq $content_hash ) {
                    $self->{logger}->info("File '$filename' is unchanged since its last successful import, skipping");
                    unlink $localFile->full_path() if -f $localFile->full_path();
                    next;
                }
            }
            my $file_hash_for_log = $content_hash // '';

            my $batch_id = try {
                $self->_stage($localFile->full_path(), $filename, $profile_id, $auto_commit, $framework, $overlay_framework);
            } catch {
                $self->{logger}->error("Failed to stage file '$filename': $_");
                $self->_log_attempt(
                    setting_id    => $setting_id,
                    filename      => $filename,
                    file_hash     => $file_hash_for_log,
                    outcome       => 'failure',
                    batch_id      => undef,
                    error_message => "$_",
                );
                $self->_archive_file( $localFile->full_path(), $filename, $setting_id, 'failure' );
                undef;
            };
            next unless defined $batch_id;

            my $action = $auto_commit ? "staged and imported" : "staged";
            $self->{logger}->info("Successfully $action file '$filename' using profile ID $profile_id (batch $batch_id)");
            $self->_log_attempt(
                setting_id    => $setting_id,
                filename      => $filename,
                file_hash     => $file_hash_for_log,
                outcome       => 'success',
                batch_id      => $batch_id,
                error_message => undef,
            );
            $self->_archive_file($localFile->full_path(), $filename, $setting_id, 'success');
        }
    }
}

sub upgrade {
    my ( $self ) = @_;

    # Koha calls upgrade() on every version bump where plugin_version >
    # database_version (see Koha::Plugins::Base), not just the one this was
    # written for — guard with our own marker so a later, unrelated version
    # bump can't run this migration again and double-escape already-migrated
    # patterns.
    unless ( $self->retrieve_data('filenames_migrated_to_regex') ) {
        $self->_migrate_filenames_to_regex();
        $self->store_data( { filenames_migrated_to_regex => 1 } );
    }

    unless ( $self->retrieve_data('archive_layout_migrated') ) {
        $self->_migrate_archive_layout();
        $self->store_data( { archive_layout_migrated => 1 } );
    }

    return 1;
}

# Framework quirk: this plugin has never had an install() method before. Koha
# only calls install() when its own __INSTALLED__ marker has never been set,
# which — for every site already running this plugin — is true today, since
# install() never existed to set it. The very next version bump therefore
# runs this install() instead of the normal upgrade() path, once, for every
# existing install. That's harmless: the existing upgrade() only performs the
# filename-regex migration from the previous release, which will already
# have completed and been separately marked done (filenames_migrated_to_regex)
# for any site that's already on that version. After this one-time
# transition, __INSTALLED__ is set and future version bumps go through
# upgrade() as normal.
sub install {
    my ( $self ) = @_;

    my $table = $self->_log_table_name;
    my $dbh   = C4::Context->dbh;

    $dbh->do(qq{
        CREATE TABLE IF NOT EXISTS $table (
            id             INT(11) NOT NULL AUTO_INCREMENT,
            setting_id     INT(11) NOT NULL,
            filename       VARCHAR(255) NOT NULL,
            file_hash      VARCHAR(32) NOT NULL,
            outcome        VARCHAR(10) NOT NULL,
            batch_id       INT(11) DEFAULT NULL,
            error_message  TEXT DEFAULT NULL,
            processed_on   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (id),
            KEY setting_filename_outcome (setting_id, filename, outcome, processed_on)
        )
    });

    return 1;
}

# Returns the fully-qualified name for this plugin's own log table (e.g.
# koha_plugin_com_openfifth_automatemarcimport_log), avoiding any naming
# collision with another plugin's tables. Memoized since it's derived from
# the (unchanging) plugin class name.
sub _log_table_name {
    my ( $self ) = @_;

    $self->{log_table} //= $self->get_qualified_table_name('log');
    return $self->{log_table};
}

# Computes the MD5 hex digest of a local file. Returns undef (logging a
# warning) if the file can't be opened, rather than dying — this is called
# on a file we just downloaded ourselves, so a failure here is unusual and
# the caller falls back to treating the file as unhashable rather than
# aborting the whole run.
sub _hash_file {
    my ( $self, $path ) = @_;

    open my $fh, '<', $path or do {
        $self->{logger}->warn("Cannot open $path for MD5 hashing: $!");
        return undef;
    };
    binmode $fh;
    my $digest = Digest::MD5->new->addfile($fh)->hexdigest;
    close $fh;

    return $digest;
}

sub _log_attempt {
    my ( $self, %args ) = @_;

    my $table = $self->_log_table_name;
    my $dbh   = C4::Context->dbh;

    $dbh->do(
        "INSERT INTO $table (setting_id, filename, file_hash, outcome, batch_id, error_message, processed_on) VALUES (?, ?, ?, ?, ?, ?, NOW())",
        undef,
        $args{setting_id}, $args{filename}, $args{file_hash}, $args{outcome}, $args{batch_id}, $args{error_message}
    );

    return 1;
}

sub _get_last_successful_hash {
    my ( $self, $setting_id, $filename ) = @_;

    my $table = $self->_log_table_name;
    my $dbh   = C4::Context->dbh;

    my ($hash) = $dbh->selectrow_array(
        "SELECT file_hash FROM $table WHERE setting_id = ? AND filename = ? AND outcome = 'success' ORDER BY processed_on DESC LIMIT 1",
        undef, $setting_id, $filename
    );

    return $hash;
}

# One-time migration (see upgrade()): filenames used to be matched as plain
# substrings, now they're matched as regexes. quotemeta() every existing
# line so a stored pattern keeps matching exactly the same filenames it did
# under the old substring behaviour, with no admin action required.
sub _migrate_filenames_to_regex {
    my ( $self ) = @_;

    foreach my $setting_id ( split( ',', $self->retrieve_data('selected_setting_ids') // '' ) ) {
        next if $setting_id eq '';

        eval {
            my $setting_data = decode_json( $self->retrieve_data($setting_id) );
            my $filenames = $setting_data->{filenames};

            if ( defined $filenames && $filenames ne '' ) {
                $setting_data->{filenames} =
                    join( "\n", map { quotemeta($_) } split( /\r?\n/, $filenames ) );
                $self->store_data( { $setting_id => encode_json($setting_data) } );
            }
        };
        if ($@) {
            $self->{logger}->warn("Failed to migrate filenames pattern for setting $setting_id during upgrade: $@");
        }
    }

    return 1;
}

# One-time migration (see upgrade()): archived files used to sit flat at
# Archive/{setting_id}/{filename} (only successes were ever archived). Move
# any such loose files into the new Archive/{setting_id}/Success/ layout so
# they aren't orphaned by the Success/Failed restructure.
sub _migrate_archive_layout {
    my ( $self ) = @_;

    return unless $self->{plugindir};
    my $archive_base = $self->{plugindir} . "/Archive";
    return unless -d $archive_base;

    opendir( my $dh, $archive_base ) or do {
        $self->{logger}->warn("Cannot open $archive_base during archive layout migration: $!");
        return;
    };
    my @setting_dirs = grep { !/^\./ && -d "$archive_base/$_" } readdir($dh);
    closedir($dh);

    foreach my $setting_id (@setting_dirs) {
        my $setting_dir = "$archive_base/$setting_id";

        eval {
            opendir( my $sdh, $setting_dir ) or die "Cannot open $setting_dir: $!";
            my @loose_files = grep { -f "$setting_dir/$_" } readdir($sdh);
            closedir($sdh);

            for my $file (@loose_files) {
                my $success_dir = "$setting_dir/Success";
                $self->_make_directory($success_dir);
                my $destination = "$success_dir/$file";
                next if -f $destination;
                rename( "$setting_dir/$file", $destination )
                    or $self->{logger}->warn("Could not move $setting_dir/$file to $destination during archive layout migration: $!");
            }
        };
        if ($@) {
            $self->{logger}->warn("Failed to migrate archive layout for setting $setting_id: $@");
        }
    }

    return 1;
}

sub intranet_js {
    my ( $self ) = @_;
    if ($self->can('page') && $self->page != '/cgi-bin/koha/mainpage.pl') {
        return;
    }

    my $num_import_batches = Koha::ImportBatches->search({ import_status => 'staged', batch_type => 'batch' })->count;
    if ($num_import_batches == 0) {
        return;
    }

    my $message = "";
    my $link_text = "";
    if ($num_import_batches == 1) {
        $message = "There's a staged MARC file waiting to be reviewed and commited. ";
        $link_text = "Click here to view it. ";
    } else {
        $message = "There are $num_import_batches staged MARC files waiting to be reviewed and commited. ";
        $link_text = "Click here to view them. ";
    }

    return  "
        <script>
            if (window.location.href.includes('mainpage.pl')) {
                const container = document.querySelector('.biglinks-list').parentElement.parentElement
                const msgContainer = document.createElement('div')
                const linkToManageMarcImports = document.createElement('a')

                msgContainer.textContent = \"$message\"
                msgContainer.setAttribute('class', 'alert alert-info')
                linkToManageMarcImports.setAttribute('href','/cgi-bin/koha/tools/manage-marc-import.pl')
                linkToManageMarcImports.textContent = \"$link_text\"

                msgContainer.append(linkToManageMarcImports)
                container.append(msgContainer)
            }
        </script>
    ";
}

# SERVICES

# Remove the relevant setting_id from the selected_setting_ids row in plugin_data (does not delete the setting row itself)
sub _delete_setting {
    my ( $self, $cgi ) = @_;
    my $selected_transport_id = $cgi->param('selected_transport_id');
    my $selected_setting_id = $cgi->param('selected_setting_id');
    
    my $updated_settings_ids;
    foreach my $settings_id (split( /,/, $self->retrieve_data('selected_setting_ids') )) {
        if ($settings_id != $selected_setting_id) {
            $updated_settings_ids .=  $settings_id;
            $updated_settings_ids .= ',';   
        }
    }
    $self->store_data({
        selected_setting_ids => $updated_settings_ids,
    });
    # FIXME: also store a list of archived settings ids?
}
 
sub _get_transport_directory_groups {
    my ( $self ) = @_;

    my %groups;    # "$transport_id\0$directory" => { transport_id, directory, setting_ids => [] }
    my %transport_cache;

    foreach my $setting_id ( split( ',', $self->retrieve_data('selected_setting_ids') // '' ) ) {
        next if $setting_id eq '';
        my $setting_data = decode_json( $self->retrieve_data($setting_id) );
        my $transport_id = $setting_data->{transport_id};
        next unless defined $transport_id;

        my $directory = $setting_data->{download_directory};
        $directory = '' unless defined $directory;

        if ( $directory eq '' ) {
            my $transport = $transport_cache{$transport_id} //= Koha::File::Transports->find($transport_id);
            next unless $transport;
            $directory = $transport->download_directory // '';
        }

        my $key = "$transport_id\0$directory";
        $groups{$key} //= {
            transport_id => $transport_id,
            directory    => $directory,
            setting_ids  => [],
        };
        push @{ $groups{$key}{setting_ids} }, $setting_id;
    }

    return values %groups;
}

sub _call_transport {
    my ( $self, $transport, $method, @args ) = @_;

    return try {
        $transport->$method(@args);
    } catch {
        $transport->add_message( { message => $method, type => 'error', payload => { error => "$_" } } );
        undef;
    };
}

sub _transport_error {
    my ( $self, $transport ) = @_;

    my ($last_error) = grep { $_->type eq 'error' } reverse @{ $transport->object_messages };
    return 'unknown error' unless $last_error;

    my $payload = $last_error->payload // {};
    return $payload->{error} // $last_error->message;
}

sub _parse_longname {
    my ( $self, $filehash ) = @_;

    return unless $filehash->{longname};

    my ($entry) = @{ parse_dir( $filehash->{longname} ) };
    return $entry;
}

sub _file_entry_name {
    my ( $self, $filehash ) = @_;

    my $entry = $self->_parse_longname($filehash);
    return $entry ? $entry->[0] : $filehash->{filename};
}

sub _file_entry_size {
    my ( $self, $filehash ) = @_;

    return $filehash->{size} if defined $filehash->{size};
    return 0;
}

sub _file_entry_mtime {
    my ( $self, $filehash ) = @_;

    return $filehash->{mtime} if defined $filehash->{mtime};

    my $entry = $self->_parse_longname($filehash);
    return $entry ? $entry->[3] : undef;
}

sub _get_profile_id_by_filename {
    my ( $self, $transport_id, $filename ) = @_;

    my @setting_ids = grep {
        my $setting_data = decode_json( $self->retrieve_data($_) );
        $setting_data->{transport_id} == $transport_id;
    } split( ',', $self->retrieve_data('selected_setting_ids') // '' );

    my $setting_data = $self->_get_setting_by_filename( \@setting_ids, $filename );
    return $setting_data->{profile_id};
}

sub _get_setting_by_filename {
    my ( $self, $setting_ids, $filename ) = @_;

    my $default_setting;

    foreach my $setting_id ( @{$setting_ids} ) {
        my $setting_data = decode_json( $self->retrieve_data($setting_id) );

        if ( !defined $setting_data->{filenames} || $setting_data->{filenames} eq "" ) {
            $default_setting = $setting_data;
            next;
        }

        # Check if filename matches any of the line-delimited regex patterns
        foreach my $pattern ( split( /\r?\n/, $setting_data->{filenames} ) ) {
            $pattern =~ s/^\s+|\s+$//g;    # trim whitespace
            next if $pattern eq '';
            if ( $self->_filename_matches_pattern( $filename, $pattern ) ) {
                return $setting_data;
            }
        }
    }
    return $default_setting;
}

# Matches $filename against the regex $pattern, case-insensitively. Wrapped in
# an alarm-based timeout so a pathological pattern (catastrophic backtracking)
# can't hang the single-threaded nightly cron run for every configured vendor.
sub _filename_matches_pattern {
    my ( $self, $filename, $pattern ) = @_;

    my $matched;
    eval {
        local $SIG{ALRM} = sub { die "regex_timeout\n" };
        alarm(2);
        $matched = ( $filename =~ /$pattern/i ) ? 1 : 0;
        alarm(0);
    };
    if ($@) {
        alarm(0);
        my $reason = $@ eq "regex_timeout\n" ? 'timed out (possible catastrophic backtracking)' : "error: $@";
        $self->{logger}->warn("Filename pattern matching $reason: pattern='$pattern'");
        return 0;
    }
    return $matched;
}

sub _get_settings_for_display {
    my ( $self ) = @_;
    my  @automate_marc_import_plugin_settings;

    # Build lookup hashes for template and matcher names
    my %template_names;
    my @templates = GetModificationTemplates();
    foreach my $tmpl (@templates) {
        $template_names{$tmpl->{template_id}} = $tmpl->{name};
    }

    my %matcher_names;
    my @matchers = C4::Matcher::GetMatcherList();
    foreach my $m (@matchers) {
        $matcher_names{$m->{matcher_id}} = $m->{code};
    }

    foreach my $setting ( split( /,/, $self->retrieve_data('selected_setting_ids')) ) {
        my $setting_data = decode_json($self->retrieve_data($setting));
        my $transport = Koha::File::Transports->find({ $self->{transport_column_name} => $setting_data->{transport_id} });
        my $profile = Koha::ImportBatchProfiles->find({ id => $setting_data->{profile_id} });

        my $template_id = $profile->get_column('template_id');
        my $matcher_id = $profile->get_column('matcher_id');

        # formats the data so it can be easily rendered in the settings table on the plugin's configuration page
        my %setting = (
            id => $setting_data->{id},
            name => $setting_data->{name} // '',
            description => $setting_data->{description} // '',
            transport_id => $transport->get_column($self->{transport_column_name}),
            transport_name => $transport->get_column('name'),
            download_directory => $setting_data->{download_directory} // '',
            transport_download_directory => $transport->get_column('download_directory') // '',
            profile_name => $profile->get_column('name'),
            profile_comment => $profile->get_column('comments'),
            profile_record_type => $profile->get_column('record_type'),
            profile_character_encoding => $profile->get_column('encoding'),
            profile_format => $profile->get_column('format'),
            profile_parse_items => $profile->get_column('parse_items'),
            profile_marc_modification_template_id => $template_id,
            profile_marc_modification_template_name => $template_id ? ($template_names{$template_id} // '') : '',
            profile_record_matching_rule => $matcher_id,
            profile_record_matching_rule_name => $matcher_id ? ($matcher_names{$matcher_id} // '') : '',
            profile_nomatch_action => $profile->get_column('nomatch_action'),
            profile_overlay_action => $profile->get_column('overlay_action'),
            profile_item_action => $profile->get_column('item_action'),
            filenames => $setting_data->{filenames},
            auto_commit => $setting_data->{auto_commit} // 0,
        );
        push @automate_marc_import_plugin_settings, \%setting;
    }
    return  @automate_marc_import_plugin_settings;
}

sub _get_template_and_matcher_lists {
    my ( $self ) = @_;

    # Build template list for JavaScript
    my @template_list;
    my @templates = GetModificationTemplates();
    foreach my $tmpl (@templates) {
        push @template_list, {
            template_id => $tmpl->{template_id},
            name => $tmpl->{name},
        };
    }

    # Build matcher list for JavaScript
    my @matcher_list;
    my @matchers = C4::Matcher::GetMatcherList();
    foreach my $m (@matchers) {
        push @matcher_list, {
            matcher_id => $m->{matcher_id},
            code => $m->{code},
        };
    }

    return (\@template_list, \@matcher_list);
}

sub _validate_cgi_params {
    my ( $self, $cgi ) = @_;

    # Get parameters
    my $name = $cgi->param('name') // '';
    my $description = $cgi->param('description') // '';
    my $transport_id = $cgi->param('selected_transport_id');
    my $profile_id = $cgi->param('profile_id');
    my $filenames = $cgi->param('filenames') // '';
    my $auto_commit = $cgi->param('auto_commit') // 0;
    my $framework = $cgi->param('framework') // '';
    my $overlay_framework = $cgi->param('overlay_framework') // '';
    my $download_directory = $cgi->param('download_directory') // '';

    # Validate name (required, max 100 chars)
    $name =~ s/^\s+|\s+$//g;  # trim whitespace
    if ($name eq '') {
        return { valid => 0, error => "Name is required" };
    }
    if (length($name) > 100) {
        return { valid => 0, error => "Name must be 100 characters or less" };
    }

    # Sanitize description (optional, max 500 chars)
    $description =~ s/^\s+|\s+$//g;  # trim whitespace
    if (length($description) > 500) {
        return { valid => 0, error => "Description must be 500 characters or less" };
    }

    # Check required fields are present
    if (!defined $transport_id || $transport_id eq '') {
        return { valid => 0, error => "Transport selection is required" };
    }

    if (!defined $profile_id || $profile_id eq '') {
        return { valid => 0, error => "Profile selection is required" };
    }

    # Validate transport_id is a positive integer
    if (!looks_like_number($transport_id) || $transport_id <= 0) {
        return { valid => 0, error => "Invalid transport selection" };
    }

    # Validate profile_id is a positive integer
    if (!looks_like_number($profile_id) || $profile_id <= 0) {
        return { valid => 0, error => "Invalid profile selection" };
    }

    # Verify transport exists
    my $transport = Koha::File::Transports->find($transport_id);
    if (!$transport) {
        return { valid => 0, error => "Transport with ID $transport_id does not exist" };
    }

    # Verify profile exists
    my $profile = Koha::ImportBatchProfiles->find($profile_id);
    if (!$profile) {
        return { valid => 0, error => "Profile with ID $profile_id does not exist" };
    }

    # Sanitize filenames
    my $sanitized_filenames = $self->_sanitize_filenames($filenames);

    # Validate each line is a safe, compilable regex
    my $filenames_error = $self->_validate_filename_patterns($sanitized_filenames);
    if ($filenames_error) {
        return { valid => 0, error => $filenames_error };
    }

    # Sanitize download directory override (light-touch: it's a real remote path)
    my $sanitized_download_directory = $self->_sanitize_download_directory($download_directory);

    # Validate auto_commit is boolean
    $auto_commit = $auto_commit ? 1 : 0;

    # Validate framework codes (optional, alphanumeric, max 10 chars)
    if ($framework ne '' && $framework !~ /^[A-Za-z0-9]{1,10}$/) {
        return { valid => 0, error => "Invalid framework code" };
    }

    # Validate overlay_framework (optional, alphanumeric or '_USE_ORIG_', max 10 chars)
    if ($overlay_framework ne '' && $overlay_framework ne '_USE_ORIG_' && $overlay_framework !~ /^[A-Za-z0-9]{1,10}$/) {
        return { valid => 0, error => "Invalid overlay framework code" };
    }

    return {
        valid => 1,
        data => {
            name => $name,
            description => $description,
            transport_id => int($transport_id),
            profile_id => int($profile_id),
            filenames => $sanitized_filenames,
            auto_commit => $auto_commit,
            framework => $framework,
            overlay_framework => $overlay_framework,
            download_directory => $sanitized_download_directory,
        }
    };
}

sub _sanitize_filenames {
    my ( $self, $filenames ) = @_;

    return '' unless defined $filenames;

    # This field holds line-delimited regexes, matched case-insensitively at
    # runtime (see _filename_matches_pattern), so case and syntax characters
    # like \ / : [ ] are meaningful and must not be touched here. Only strip
    # null bytes/control characters, same light touch as _sanitize_download_directory.
    $filenames =~ s/[\0\x00-\x1f\x7f-\x9f]//g;

    # Limit length to prevent DoS
    if (length($filenames) > 1000) {
        $filenames = substr($filenames, 0, 1000);
    }

    # Trim whitespace
    $filenames =~ s/^\s+|\s+$//g;

    return $filenames;
}

# Rejects lines that don't compile as a regex, and explicitly blocks Perl's
# embedded-code-in-regex constructs ((?{ ... }) / (??{ ... })) regardless of
# taint mode, since Koha's web scripts don't reliably run under -T.
sub _validate_filename_patterns {
    my ( $self, $filenames ) = @_;

    return undef unless defined $filenames && $filenames ne '';

    foreach my $pattern ( split( /\r?\n/, $filenames ) ) {
        $pattern =~ s/^\s+|\s+$//g;
        next if $pattern eq '';

        if ( $pattern =~ /\(\?\??\{/ ) {
            return "Filename pattern '$pattern' is not allowed: embedded code blocks are not permitted";
        }

        my $compiles = eval { qr/$pattern/; 1 };
        if ( !$compiles ) {
            my $reason = $@;
            $reason =~ s/\s+at\s+\S+\s+line\s+\d+\.?\s*$//s;
            return "Filename pattern '$pattern' is not a valid regular expression: $reason";
        }
    }

    return undef;
}

sub _sanitize_download_directory {
    my ( $self, $directory ) = @_;

    return '' unless defined $directory;

    # Remove null bytes and control characters. Unlike _sanitize_filenames,
    # this is a real remote path, so slashes/colons/case are preserved.
    $directory =~ s/[\0\x00-\x1f\x7f-\x9f]//g;

    # Trim leading/trailing whitespace
    $directory =~ s/^\s+|\s+$//g;

    # Limit length to prevent unbounded storage
    if (length($directory) > 500) {
        $directory = substr($directory, 0, 500);
    }

    return $directory;
}

sub _save_setting {
    my ( $self, $cgi ) = @_;

    # Validate input parameters
    my $validation_result = $self->_validate_cgi_params($cgi);
    if (!$validation_result->{valid}) {
        $self->{logger}->error("Input validation failed: " . $validation_result->{error});
        return { success => 0, error => $validation_result->{error} };
    }

    my $selected_setting_id = $cgi->param('selected_setting_id');
    my $is_edit = defined $selected_setting_id && $selected_setting_id ne '';

    my $setting_id_list = $self->retrieve_data('selected_setting_ids') ? $self->retrieve_data('selected_setting_ids') : "";
    my $setting_id;

    if ($is_edit) {
        # Use existing setting ID for edits
        $setting_id = $selected_setting_id;
    } else {
        # Generate new setting ID for new settings
        $setting_id = $self->_set_setting_id();

        # add the new setting's id to the selected_setting_ids list so the setting may be easily retrieved later
        my $updated_settings_id_list = $setting_id_list;
        $updated_settings_id_list .=  "$setting_id",
        $updated_settings_id_list .= ',';
        $setting_id_list = $updated_settings_id_list;
    }

    # Use validated and sanitized data
    my %setting = (
        id => $setting_id,
        name => $validation_result->{data}->{name},
        description => $validation_result->{data}->{description},
        transport_id => $validation_result->{data}->{transport_id},
        profile_id => $validation_result->{data}->{profile_id},
        filenames => $validation_result->{data}->{filenames},
        auto_commit => $validation_result->{data}->{auto_commit},
        framework => $validation_result->{data}->{framework},
        overlay_framework => $validation_result->{data}->{overlay_framework},
        download_directory => $validation_result->{data}->{download_directory},
    );

    eval {
        my $data_to_store = {
            $setting_id => encode_json(\%setting),
        };

        # Only update selected_setting_ids and last_setting_id for new settings
        if (!$is_edit) {
            $data_to_store->{selected_setting_ids} = $setting_id_list;
            $data_to_store->{last_setting_id} = $setting_id;
        }

        $self->store_data($data_to_store);
    };
    
    if ($@) {
        $self->{logger}->error("Failed to save setting: $@");
        return { success => 0, error => "Failed to save setting. Please try again." };
    }
    
    $self->{logger}->info("Successfully saved new setting with ID: $setting_id");
    return { success => 1 };
}

sub _set_plugin_dir {
    my ( $self ) = @_;
    if ($self->{plugindir}) {
        return;
    }
    my $pluginsdir = C4::Context->config("pluginsdir");
    if (ref($pluginsdir) eq 'ARRAY') {
        $pluginsdir = $pluginsdir->[0];
    }
    $self->{plugindir} = $pluginsdir . "/Koha/Plugin/Com/OpenFifth/AutomateMarcImport";
}

sub _detect_transport_column_name {
    my ( $self ) = @_;

    # Default to file_transport_id (newer Koha versions)
    $self->{transport_column_name} = 'file_transport_id';

    # Try to detect the actual column name used in this Koha installation
    eval {
        # Check if the result class has the file_transport_id column
        my @columns = Koha::File::Transports->columns;
        if (grep { $_ eq 'id' } @columns) {
            # Older version uses 'id' as primary key
            $self->{transport_column_name} = 'id';
        } elsif (grep { $_ eq 'transport_id' } @columns) {
            # Backported version might use 'transport_id'
            $self->{transport_column_name} = 'transport_id';
        }
        # Otherwise keep the default 'file_transport_id'
    };

    if ($@) {
        $self->{logger}->warn("Failed to detect transport column name, using default 'file_transport_id': $@");
    } else {
        $self->{logger}->info("Detected transport column name: " . $self->{transport_column_name});
    }
}

# generates a unique identifier to assign to newly created settings
sub _set_setting_id {
    my ( $self ) = @_;
    my $last_setting_id = $self->retrieve_data('last_setting_id') ? $self->retrieve_data('last_setting_id') : 0;
    my $setting_id = $last_setting_id + 1;
    return $setting_id;
}

sub _stage {
    my ( $self, $input_file_path, $display_filename, $profile_id, $auto_commit, $framework, $overlay_framework) = @_;
    $auto_commit //= 0; # Default to false if not specified
    $framework //= '';
    my $profile = Koha::ImportBatchProfiles->find($profile_id);

    if ( $profile_id && !$profile ) {
        die "Profile with id $profile_id not found";
    }

    my $batch_comment = $profile->comments;
    my $record_type = $profile->record_type;
    my $encoding = $profile->encoding;
    my $format = $profile->format;
    my $marc_mod_template_id = $profile->template_id;
    my $parse_items = $profile->parse_items;
    my $matcher_id = $profile->matcher_id;
    my $nomatch_action = $profile->nomatch_action // 'create_new';
    my $overlay_action = $profile->overlay_action // 'replace';
    my $item_action = $profile->item_action // 'always_add';

    if ( !$input_file_path ) {
        $self->{logger}->error("Cannot open input file $input_file_path: $!");
        return;
    }

    # Use modern Koha database transaction pattern
    my $schema = Koha::Database->new()->schema();
    
    my $batch_id;
    try {
        $batch_id = $schema->storage->txn_do(sub {
            
            # Parse MARC records from file
            my ( $errors, $marc_records );
            if ( $format eq 'ISO2709' ) {
                ( $errors, $marc_records ) =
                    C4::ImportBatch::RecordsFromISO2709File( $input_file_path, $record_type, $encoding);
            } elsif ( $format eq 'MARCXML' ) {
                ( $errors, $marc_records ) =
                    C4::ImportBatch::RecordsFromMARCXMLFile( $input_file_path, $encoding);
            } else {
                die "Unsupported file format: $format";
            }

            # Log any parsing errors
            if ($errors && @{$errors}) {
                foreach my $error (@{$errors}) {
                    $self->{logger}->error("MARC parsing error: $error");
                }
            }

            my $num_input_records = ($marc_records) ? scalar(@$marc_records) : 0;
            if ($num_input_records == 0) {
                die "No valid MARC records found in file";
            }

            $self->{logger}->info("Staging $num_input_records MARC records from file");

            # Stage MARC records in batch
            my ( $batch_id, $num_valid_records, $num_items, @import_errors ) = BatchStageMarcRecords(
                $record_type,                        $encoding,
                $marc_records,                       $display_filename,
                $marc_mod_template_id,               $batch_comment,
                '',                                  $parse_items,
                0,                                   100,
                \&_log_progress
            );

            # Log staging errors if any
            my $num_invalid_records = scalar(@import_errors);
            if ($num_invalid_records > 0) {
                $self->{logger}->warn("$num_invalid_records records had import errors during staging");
                foreach my $import_error (@import_errors) {
                    $self->{logger}->error("Import error: $import_error");
                }
            }

            if (!$batch_id) {
                die "Failed to create import batch";
            }

            # Associate the import profile with the batch
            if ($profile_id) {
                my $ibatch = Koha::ImportBatches->find($batch_id);
                $ibatch->set({ profile_id => $profile_id })->store;
            }

            # Set up record matching and overlay actions
            my $num_with_matches = $self->_search_for_matches($record_type, $overlay_action, $nomatch_action, $item_action, $batch_id, $matcher_id);

            $self->{logger}->info("Successfully staged batch $batch_id: $num_valid_records valid records, $num_with_matches potential matches");

            # Commit the batch if auto_commit is enabled
            if ($auto_commit) {
                $self->{logger}->info("Auto-commit enabled, committing batch $batch_id");
                $self->_commit_batch($batch_id, $framework, $overlay_framework);
            }

            return $batch_id;
        });

    } catch {
        $self->{logger}->error("Failed to stage MARC file '$input_file_path': $_");
        die "Staging transaction failed: $_";
    };

    return $batch_id;
}

sub _search_for_matches {
    my ( $self, $record_type, $overlay_action, $nomatch_action, $item_action, $batch_id, $matcher_id ) = @_;

    SetImportBatchOverlayAction( $batch_id, $overlay_action );
    SetImportBatchNoMatchAction( $batch_id, $nomatch_action );
    SetImportBatchItemAction( $batch_id, $item_action );

    if ( $matcher_id ) {
        my $matcher = C4::Matcher->fetch( $matcher_id );
        if ( defined $matcher ) {
            SetImportBatchMatcher( $batch_id, $matcher_id );
            return BatchFindDuplicates( $batch_id, $matcher, 10, 100, \&_log_progress );
        } else {
            $self->{logger}->warn("Matcher ID $matcher_id not found, skipping matching");
            return 0;
        }
    } else {
        # No matcher configured, skip matching
        return 0;
    }
}

sub _is_supported_marc_file {
    my ( $self, $filename ) = @_;
    
    return 0 unless defined $filename && $filename ne '';
    
    # Use File::Basename to properly extract the extension
    my ($name, $path, $extension) = fileparse($filename, qr/\.[^.]*/);
    
    return 0 unless defined $extension;
    
    # Convert to lowercase for case-insensitive comparison
    $extension = lc($extension);
    
    # Define supported MARC file extensions
    my @supported_extensions = ('.mrc', '.mrcx', '.xml', '.marcxml');
    
    # Check if extension is in our supported list
    return grep { $_ eq $extension } @supported_extensions;
}

sub _was_modified_since_last_fetch {
    my ( $self, $filehash ) = @_;

    my $last_run_time = time() - 8640000;
    my $last_mod_time = $self->_file_entry_mtime($filehash);
    return 1 unless defined $last_mod_time;

    return $last_mod_time > $last_run_time;
}

#FIXME: do we need a logger subroutine to pass to BatchStageMarcRecords? If not: remove, and update _stage()
sub _log_progress {
    my $num_input_records = shift;
    my $logger = Koha::Logger->get;
    $logger->trace("processed $num_input_records records");
}

sub _ensure_plugin_directories {
    my ( $self, $setting_id ) = @_;

    # Always ensure base Archive directory exists
    my $archive_base = $self->{plugindir} . "/Archive";
    $self->_make_directory($archive_base);

    # If setting_id is provided, ensure per-setting archive directory exists
    if (defined $setting_id && $setting_id ne '') {
        $self->_make_directory("$archive_base/$setting_id");
    }
}

sub _make_directory {
    my ( $self, $directory ) = @_;

    return if -d $directory;

    make_path( $directory, { error => \my $errors } );
    return unless @{$errors};

    my ( undef, $message ) = %{ $errors->[0] };
    $self->{logger}->warn("Could not create directory $directory: $message");
}

sub _archive_file {
    my ( $self, $source_file, $filename, $setting_id, $outcome ) = @_;

    my $subdir        = $outcome eq 'success' ? 'Success' : 'Failed';
    my $retention_key = $outcome eq 'success' ? 'archive_retention_count' : 'archive_failed_retention_count';
    my $retention_count = $self->retrieve_data($retention_key) // 10;

    if ($retention_count == 0) {
        $self->{logger}->info("Archive retention count is 0, not archiving $outcome file '$filename'");
        if (-f $source_file) {
            unlink($source_file) or $self->{logger}->warn("Could not remove temporary file $source_file: $!");
        }
        return;
    }

    my $archive_dir = $self->{plugindir} . "/Archive/$setting_id/$subdir";
    $self->_make_directory($archive_dir);
    my $archive_path = "$archive_dir/$filename";

    if (copy($source_file, $archive_path)) {
        $self->{logger}->info("Archived $outcome file '$filename' to Archive/$setting_id/$subdir/");
    } else {
        $self->{logger}->error("Failed to archive $outcome file '$filename': $!");
    }

    if (-f $source_file) {
        unlink($source_file) or $self->{logger}->warn("Could not remove temporary file $source_file: $!");
    }

    $self->_apply_retention_policy( $archive_dir, $retention_count );

    # A filename that previously failed and has now succeeded: the Failed/
    # archive should only ever reflect names that are *currently* failing —
    # history lives in the log table, not the file archive.
    if ( $outcome eq 'success' ) {
        my $stale_failed = $self->{plugindir} . "/Archive/$setting_id/Failed/$filename";
        if ( -f $stale_failed ) {
            unlink($stale_failed) or $self->{logger}->warn("Could not remove stale failed archive $stale_failed: $!");
        }
    }
}

sub _apply_retention_policy {
    my ( $self, $directory, $max_files ) = @_;

    return if $max_files == 0;
    return unless -d $directory;

    opendir(my $dh, $directory) or do {
        $self->{logger}->warn("Cannot open archive directory $directory: $!");
        return;
    };

    my @files;
    while (my $file = readdir($dh)) {
        next if $file =~ /^\./; # Skip . and ..
        my $full_path = "$directory/$file";
        next unless -f $full_path; # Skip directories
        push @files, {
            path => $full_path,
            mtime => (stat($full_path))[9]
        };
    }
    closedir($dh);

    # Sort by modification time (newest first)
    @files = sort { $b->{mtime} <=> $a->{mtime} } @files;

    # Delete files beyond the retention limit
    if (scalar(@files) > $max_files) {
        my @files_to_delete = splice(@files, $max_files);
        foreach my $file (@files_to_delete) {
            if (unlink($file->{path})) {
                $self->{logger}->info("Retention policy: deleted old archive file $file->{path}");
            } else {
                $self->{logger}->warn("Retention policy: failed to delete $file->{path}: $!");
            }
        }
    }
}

sub _commit_batch {
    my ( $self, $batch_id, $framework, $overlay_framework ) = @_;

    return unless $batch_id;

    $framework //= '';
    # Convert '_USE_ORIG_' to undef (tells Koha to keep original framework)
    $overlay_framework = undef if defined $overlay_framework && $overlay_framework eq '_USE_ORIG_';

    try {
        $self->{logger}->info("Committing batch $batch_id with framework='$framework', overlay_framework='" . ($overlay_framework // '_USE_ORIG_') . "'");

        # Use BatchCommitRecords to commit the batch
        my ( $num_added, $num_updated, $num_items_added, $num_items_replaced, $num_items_errored, $num_ignored ) =
            BatchCommitRecords({
                batch_id => $batch_id,
                framework => $framework,
                overlay_framework => $overlay_framework,
            });

        $self->{logger}->info(
            "Batch $batch_id committed: " .
            "$num_added records added, " .
            "$num_updated records updated, " .
            "$num_items_added items added, " .
            "$num_items_replaced items replaced, " .
            "$num_items_errored items errored, " .
            "$num_ignored records ignored"
        );

        return 1;

    } catch {
        $self->{logger}->error("Failed to commit batch $batch_id: $_");
        die "Batch commit failed: $_";
    };
}

1;
