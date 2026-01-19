package Koha::Plugin::AutomateMarcImport;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

# Core Perl modules
use Digest::MD5;
use File::Basename qw(fileparse);
use File::Copy qw(copy);
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

our $VERSION = '1.0.15';

our $metadata = {
    name            => 'Automate Marc Import',
    author          => 'Open Fifth',
    date_authored   => '2022-05-19',
    date_updated    => '2026-01-19',
    minimum_version => '24.11.00.000', #TODO: update this to relevant Koha version once knows (dependency not yet upstreamed)
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

sub configure {
    my ( $self, $args  ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template( { file => 'configure.tt' } );

    # save setting OR
    if ( defined $cgi->param('op') && $cgi->param('op') eq 'save') {
        my $save_result = $self->_save_setting( $cgi );
        # handle successful setting creation OR
        if ($save_result->{success}) {
            my $redirect_url = "/cgi-bin/koha/plugins/run.pl?class=" . $cgi->param('class') . "&method=configure";
            print $cgi->redirect($redirect_url);
            return;
        } else {
            # Display error message to user
            my $selected_setting_id = $cgi->param('selected_setting_id');
            my $op = defined $selected_setting_id && $selected_setting_id ne '' ? 'edit_form' : 'add_form';
            $template->param(
                error_message => $save_result->{error},
                op => $op,
                selected_setting_id => $selected_setting_id,
                # Pre-populate form with submitted values
                selected_transport_id => $cgi->param('selected_transport_id'),
                profile_id => $cgi->param('profile_id'),
                filenames => $cgi->param('filenames'),
                auto_commit => $cgi->param('auto_commit'),
                framework => $cgi->param('framework'),
                overlay_framework => $cgi->param('overlay_framework'),
                available_profiles => Koha::ImportBatchProfiles->search(),
                available_transport => Koha::File::Transports->search(),
                available_frameworks => Koha::BiblioFrameworks->search({}, { order_by => ['frameworktext'] }),
            );
            $self->output_html( $template->output() );
            return;
        }
    }

    # ..delete setting OR
    if ( defined $cgi->param('op') && $cgi->param('op') eq 'delete') {
        $self->_delete_setting( $cgi );
        my $redirect_url = "/cgi-bin/koha/plugins/run.pl?class=" . $cgi->param('class') . "&method=configure";
        print $cgi->redirect($redirect_url);
        return;
    }

    # ..edit setting OR
    if ( defined $cgi->param('op') && $cgi->param('op') eq 'edit') {
        my $selected_setting_id = $cgi->param('selected_setting_id');
        my $setting_data = decode_json($self->retrieve_data( $selected_setting_id ));

        $template->param(
            op => 'edit_form',
            selected_setting_id => $selected_setting_id,
            selected_transport_id => $setting_data->{transport_id},
            profile_id => $setting_data->{profile_id},
            filenames => $setting_data->{filenames},
            auto_commit => $setting_data->{auto_commit},
            framework => $setting_data->{framework},
            overlay_framework => $setting_data->{overlay_framework},
            available_profiles => Koha::ImportBatchProfiles->search(),
            available_transport => Koha::File::Transports->search(),
            available_frameworks => Koha::BiblioFrameworks->search({}, { order_by => ['frameworktext'] }),
        );
        $self->output_html( $template->output() );
        return;
    }

    # ..display settings list (default action)
    my @automate_marc_import_plugin_settings = $self->_get_settings_for_display();
    if ($cgi->param('op')) {
        $template->param(op => $cgi->param('op'))
    }
    $template->param(
        available_profiles => Koha::ImportBatchProfiles->search(),
        available_transport => Koha::File::Transports->search(),
        available_frameworks => Koha::BiblioFrameworks->search({}, { order_by => ['frameworktext'] }),
        automate_marc_import_plugin_settings => \@automate_marc_import_plugin_settings,
        automate_marc_import_plugin_settings_count => scalar @automate_marc_import_plugin_settings
    );
    $self->output_html( $template->output() );
}

sub cronjob_nightly {
    my ( $self ) = @_;

    # Ensure required directories exist
    $self->_ensure_plugin_directories();

    foreach my $transport_id ( $self->_get_selected_transport_ids() ) {
        my $transport = Koha::File::Transports->find($transport_id);
        if (!$transport) {
            $self->{logger}->error("Transport with ID $transport_id not found, skipping");
            next;
        }

        my $transport_name = $transport->name || "Transport $transport_id";

        # Check download directory is configured
        if (!defined $transport->download_directory || $transport->download_directory eq '') {
            $self->{logger}->error("Transport '$transport_name' does not have a download directory set, skipping");
            next;
        }

        # Try to connect to transport
        try {
            $transport->connect();
            $self->{logger}->info("Connected to transport '$transport_name'");
        } catch {
            $self->{logger}->error("Failed to connect to transport '$transport_name': $_");
            next; # Skip this transport and continue with next
        };

        # Try to change to download directory
        try {
            $transport->change_directory($transport->download_directory);
        } catch {
            $self->{logger}->error("Failed to change to download directory for transport '$transport_name': $_");
            next; # Skip this transport and continue with next
        };

        # Try to list files
        my $file_list;
        try {
            $file_list = $transport->list_files();
        } catch {
            $self->{logger}->error("Failed to list files for transport '$transport_name': $_");
            next; # Skip this transport and continue with next
        };

        next unless $file_list && @{$file_list};

        foreach my $filehash (@{$file_list}) {
            my $filename = $filehash->{filename};
            
            # Check if file has a supported MARC extension
            if (!$self->_is_supported_marc_file($filename)) {
                next;
            }     
            if (!$self->_was_modified_since_last_fetch( $filehash )) {
                next;
            }

            # Check if file has already been processed (MD5 deduplication)
            if (!$self->_should_process_file($filename)) {
                $self->{logger}->info("File '$filename' has already been processed (MD5 match), skipping");
                next;
            }

            # Check if file was already imported (database check)
            if ($self->_was_already_imported($filename)) {
                $self->{logger}->info("File '$filename' was already imported (found in import_batches), skipping");
                next;
            }

            # Use MD5 hash of filename for unique local storage path
            my $file_hashvalue = Digest::MD5::md5_hex($filehash->{filename});
            my $localFile = Koha::UploadedFile->new({
                hashvalue          => $file_hashvalue,
                filename           => $filehash->{filename},
                dir                => $self->{plugindir},
                filesize           => $filehash->{a}->size,
                owner              => undef,
                uploadcategorycode => undef,
                public             => undef,
                permanent          => undef,
            });

            # Try to download file
            try {
                $transport->download_file($filehash->{filename}, $localFile->full_path());
                $self->{logger}->info("Downloaded file '$filename' from transport '$transport_name'");
            } catch {
                $self->{logger}->error("Failed to download file '$filename' from transport '$transport_name': $_");
                next; # Skip this file and continue with next
            };

            my @split_filename = split(/\./, $filename );
            my $setting_data = $self->_get_setting_by_filename($transport_id, $split_filename[0]);
            my $profile_id = $setting_data->{profile_id};
            my $auto_commit = $setting_data->{auto_commit} // 0;
            my $framework = $setting_data->{framework} // '';
            my $overlay_framework = $setting_data->{overlay_framework} // '';

            # Try to stage file (and optionally import)
            my $batch_id;
            try {
                $batch_id = $self->_stage($localFile->full_path(), $filename, $profile_id, $auto_commit, $framework, $overlay_framework);

                my $action = $auto_commit ? "staged and imported" : "staged";
                $self->{logger}->info("Successfully $action file '$filename' using profile ID $profile_id (batch $batch_id)");

                # Archive the processed file
                $self->_archive_file($localFile->full_path(), $filename);

            } catch {
                $self->{logger}->error("Failed to stage file '$filename': $_");
                # Clean up downloaded file on staging failure
                if (-f $localFile->full_path()) {
                    unlink($localFile->full_path());
                }
                next; # Continue with next file
            };
        }
    }
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
 
sub _get_selected_transport_ids {
    my ( $self ) = @_;
    my @selected_transport_ids;

    foreach my $setting_id (split(',', $self->retrieve_data( 'selected_setting_ids' ))) {
        my $setting_data = decode_json($self->retrieve_data( $setting_id ));
        # skip duplicates
        if ( grep  { $_ == $setting_data->{transport_id}} @selected_transport_ids ) {
            next;
        }
        push @selected_transport_ids, $setting_data->{transport_id};
    }
    return @selected_transport_ids;
}

sub _get_profile_id_by_filename {
    my ( $self, $transport_id, $filename ) = @_;

    my $setting_data = $self->_get_setting_by_filename($transport_id, $filename);
    return $setting_data->{profile_id};
}

sub _get_setting_by_filename {
    my ( $self, $transport_id, $filename ) = @_;

    my $default_setting_for_transport;
    my $lc_filename = lc( $filename );

    foreach my $setting_id (split(',', $self->retrieve_data( 'selected_setting_ids' ))) {
        my $setting_data = decode_json($self->retrieve_data( $setting_id ));
        if ( $transport_id != $setting_data->{transport_id} ) {
            next;
        }

        if ( !defined $setting_data->{filenames} || $setting_data->{filenames} eq  "") {
            $default_setting_for_transport = $setting_data;
            next;
        }

        # Check if filename contains any of the line-delimited patterns
        foreach my $pattern (split(/\r?\n/, $setting_data->{filenames})) {
            $pattern =~ s/^\s+|\s+$//g;  # trim whitespace
            next if $pattern eq '';
            if ( index($lc_filename, lc($pattern)) != -1 ) {
                return $setting_data;
            }
        }
    }
    return $default_setting_for_transport;
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
        my $transport = Koha::File::Transports->search({ $self->{transport_column_name} => $setting_data->{transport_id} });
        my $profile = Koha::ImportBatchProfiles->search({ id => $setting_data->{profile_id} });

        my $template_id = $profile->get_column('template_id');
        my $matcher_id = $profile->get_column('matcher_id');

        # formats the data so it can be easily rendered in the settings table on the plugin's configuration page
        my %setting = (
            id => $setting_data->{id},
            transport_id => $transport->get_column($self->{transport_column_name}),
            transport_name => $transport->get_column('name'),
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

sub _validate_cgi_params {
    my ( $self, $cgi ) = @_;

    # Get parameters
    my $transport_id = $cgi->param('selected_transport_id');
    my $profile_id = $cgi->param('profile_id');
    my $filenames = $cgi->param('filenames') // '';
    my $auto_commit = $cgi->param('auto_commit') // 0;
    my $framework = $cgi->param('framework') // '';
    my $overlay_framework = $cgi->param('overlay_framework') // '';

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
            transport_id => int($transport_id),
            profile_id => int($profile_id),
            filenames => $sanitized_filenames,
            auto_commit => $auto_commit,
            framework => $framework,
            overlay_framework => $overlay_framework,
        }
    };
}

sub _sanitize_filenames {
    my ( $self, $filenames ) = @_;
    
    return '' unless defined $filenames;
    
    # Convert to lowercase
    $filenames = lc($filenames);
    
    # Remove dangerous characters (path separators, null bytes, control chars)
    $filenames =~ s/[\/\\:\0\x00-\x1f\x7f-\x9f]//g;
    
    # Limit length to prevent DoS
    if (length($filenames) > 1000) {
        $filenames = substr($filenames, 0, 1000);
    }
    
    # Trim whitespace
    $filenames =~ s/^\s+|\s+$//g;
    
    return $filenames;
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
        transport_id => $validation_result->{data}->{transport_id},
        profile_id => $validation_result->{data}->{profile_id},
        filenames => $validation_result->{data}->{filenames},
        auto_commit => $validation_result->{data}->{auto_commit},
        framework => $validation_result->{data}->{framework},
        overlay_framework => $validation_result->{data}->{overlay_framework},
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
    $self->{plugindir} = $pluginsdir . "/Koha/Plugin/AutomateMarcImport";
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
    $overlay_framework //= '';
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
    my $nomatch_action = $profile->nomatch_action;
    my $overlay_action = $profile->overlay_action;
    my $item_action = $profile->item_action;

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
    my $matcher = C4::Matcher->fetch( $matcher_id );
    if ( defined $matcher ) {
        SetImportBatchMatcher( $batch_id, $matcher_id );
    } elsif ( $record_type eq 'biblio' ) {
        $matcher = C4::Matcher->new($record_type);
        $matcher->add_simple_matchpoint( 'isbn', 1000, '020', 'a', -1, 0, '' );
        $matcher->add_simple_required_check(
            '245', 'a', -1, 0, '',
            '245', 'a', -1, 0, ''
        );
    }
    SetImportBatchOverlayAction( $batch_id, $overlay_action ? 'ignore' : 'replace' );
    SetImportBatchNoMatchAction( $batch_id, $nomatch_action ? 'ignore' : 'create_new' );
    SetImportBatchItemAction( $batch_id, $item_action );
    return BatchFindDuplicates( $batch_id, $matcher, 10, 100, $self->_log_progress );
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
    # FIXME: record and then retrieve the time when we last fetched from the transport instead?
    # my $last_run_time = time() - 86400;
    my $last_run_time = time() - 8640000;
    my $last_mod_time = defined $filehash->{a}->mtime ? $filehash->{a}->mtime : $filehash->{a}->atime;
    return ($last_mod_time > $last_run_time);
}

sub _was_already_imported {
    my ( $self, $filename ) = @_;

    my $dbh = C4::Context->dbh;

    # Check if file was imported in the last 6 months
    my $sql = q|
        SELECT COUNT(*) FROM import_batches
        WHERE file_name = ?
        AND upload_timestamp > DATE_SUB(CURRENT_DATE(), INTERVAL 6 MONTH)
    |;

    my $count = $dbh->selectrow_array($sql, undef, $filename);

    return $count > 0;
}

#FIXME: do we need a logger subroutine to pass to BatchStageMarcRecords? If not: remove, and update _stage()
sub _log_progress {
    my $num_input_records = shift;
    my $logger = Koha::Logger->get;
    $logger->trace("processed $num_input_records records");
}

sub _ensure_plugin_directories {
    my ( $self ) = @_;

    my @required_dirs = ('Archive');

    foreach my $dir (@required_dirs) {
        my $full_path = $self->{plugindir} . "/$dir";
        if (!-d $full_path) {
            mkdir($full_path, 0755) or $self->{logger}->warn("Could not create directory $full_path: $!");
        }
    }
}

sub _should_process_file {
    my ( $self, $filename ) = @_;

    my $archive_path = $self->{plugindir} . "/Archive/$filename";

    # If file doesn't exist in archive, it's new and should be processed
    return 1 unless -f $archive_path;

    # File exists in archive - compare MD5 checksums
    # We'll check after download, so for now return 1
    # The actual MD5 check happens in _check_file_duplicate after download
    return 1;
}

sub _check_file_duplicate {
    my ( $self, $source_file, $filename ) = @_;

    my $archive_file = $self->{plugindir} . "/Archive/$filename";

    # If file doesn't exist in archive, it's not a duplicate
    return 0 unless -f $archive_file;

    # Calculate MD5 of archive file
    open my $archive_fh, '<', $archive_file or do {
        $self->{logger}->warn("Cannot open archive file $archive_file for MD5 check: $!");
        return 0;
    };
    binmode $archive_fh;
    my $archive_digest = Digest::MD5->new->addfile($archive_fh)->hexdigest;
    close $archive_fh;

    # Calculate MD5 of source file
    open my $source_fh, '<', $source_file or do {
        $self->{logger}->warn("Cannot open source file $source_file for MD5 check: $!");
        return 0;
    };
    binmode $source_fh;
    my $source_digest = Digest::MD5->new->addfile($source_fh)->hexdigest;
    close $source_fh;

    # Return 1 if files are identical (is duplicate), 0 if different
    return $archive_digest eq $source_digest;
}

sub _archive_file {
    my ( $self, $source_file, $filename ) = @_;

    my $archive_path = $self->{plugindir} . "/Archive/$filename";

    # Check if this is actually a duplicate before archiving
    if ($self->_check_file_duplicate($source_file, $filename)) {
        $self->{logger}->info("File '$filename' is identical to archived version, not re-archiving");
    } else {
        # Copy file to archive
        if (copy($source_file, $archive_path)) {
            $self->{logger}->info("Archived file '$filename' to Archive directory");
        } else {
            $self->{logger}->error("Failed to archive file '$filename': $!");
        }
    }

    # Clean up the source file from plugin directory
    if (-f $source_file) {
        unlink($source_file) or $self->{logger}->warn("Could not remove temporary file $source_file: $!");
    }
}

sub _commit_batch {
    my ( $self, $batch_id, $framework, $overlay_framework ) = @_;

    return unless $batch_id;

    $framework //= '';
    # Convert '_USE_ORIG_' to undef (tells Koha to keep original framework)
    $overlay_framework = undef if defined $overlay_framework && $overlay_framework eq '_USE_ORIG_';
    $overlay_framework //= '';

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
