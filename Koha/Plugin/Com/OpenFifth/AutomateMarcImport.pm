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

our $VERSION         = '1.1.0';

our $metadata = {
    name            => 'Automate Marc Import',
    author          => 'Open Fifth',
    date_authored   => '2022-05-19',
    date_updated    => '2026-07-21',
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

            # Check if file has already been processed (MD5 deduplication)
            if (!$self->_should_process_file($filename, $setting_id)) {
                $self->{logger}->info("File '$filename' has already been processed (MD5 match), skipping");
                next;
            }

            # Check if file was already imported (database check)
            if ($self->_was_already_imported($filename)) {
                $self->{logger}->info("File '$filename' was already imported (found in import_batches), skipping");
                next;
            }

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

            my $batch_id = try {
                $self->_stage($localFile->full_path(), $filename, $profile_id, $auto_commit, $framework, $overlay_framework);
            } catch {
                $self->{logger}->error("Failed to stage file '$filename': $_");
                unlink $localFile->full_path() if -f $localFile->full_path();
                undef;
            };
            next unless defined $batch_id;

            my $action = $auto_commit ? "staged and imported" : "staged";
            $self->{logger}->info("Successfully $action file '$filename' using profile ID $profile_id (batch $batch_id)");
            $self->_archive_file($localFile->full_path(), $filename, $setting_id);
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
    my $lc_filename = lc( $filename );

    foreach my $setting_id ( @{$setting_ids} ) {
        my $setting_data = decode_json( $self->retrieve_data($setting_id) );

        if ( !defined $setting_data->{filenames} || $setting_data->{filenames} eq "" ) {
            $default_setting = $setting_data;
            next;
        }

        # Check if filename contains any of the line-delimited patterns
        foreach my $pattern ( split( /\r?\n/, $setting_data->{filenames} ) ) {
            $pattern =~ s/^\s+|\s+$//g;    # trim whitespace
            next if $pattern eq '';
            if ( index( $lc_filename, lc($pattern) ) != -1 ) {
                return $setting_data;
            }
        }
    }
    return $default_setting;
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

sub _should_process_file {
    my ( $self, $filename, $setting_id ) = @_;

    # Use per-setting archive path if setting_id is provided
    my $archive_path;
    if (defined $setting_id && $setting_id ne '') {
        $archive_path = $self->{plugindir} . "/Archive/$setting_id/$filename";
    } else {
        $archive_path = $self->{plugindir} . "/Archive/$filename";
    }

    # If file doesn't exist in archive, it's new and should be processed
    return 1 unless -f $archive_path;

    # File exists in archive - compare MD5 checksums
    # We'll check after download, so for now return 1
    # The actual MD5 check happens in _check_file_duplicate after download
    return 1;
}

sub _check_file_duplicate {
    my ( $self, $source_file, $filename, $setting_id ) = @_;

    # Use per-setting archive path if setting_id is provided
    my $archive_file;
    if (defined $setting_id && $setting_id ne '') {
        $archive_file = $self->{plugindir} . "/Archive/$setting_id/$filename";
    } else {
        $archive_file = $self->{plugindir} . "/Archive/$filename";
    }

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
    my ( $self, $source_file, $filename, $setting_id ) = @_;

    my $retention_count = $self->retrieve_data('archive_retention_count') // 10;

    # If retention count is 0, skip archiving entirely (just clean up)
    if ($retention_count == 0) {
        $self->{logger}->info("Archive retention count is 0, not archiving file '$filename'");
        if (-f $source_file) {
            unlink($source_file) or $self->{logger}->warn("Could not remove temporary file $source_file: $!");
        }
        return;
    }

    # Use per-setting archive path if setting_id is provided
    my $archive_path;
    if (defined $setting_id && $setting_id ne '') {
        $archive_path = $self->{plugindir} . "/Archive/$setting_id/$filename";
    } else {
        $archive_path = $self->{plugindir} . "/Archive/$filename";
    }

    # Check if this is actually a duplicate before archiving
    if ($self->_check_file_duplicate($source_file, $filename, $setting_id)) {
        $self->{logger}->info("File '$filename' is identical to archived version, not re-archiving");
    } else {
        # Copy file to archive
        if (copy($source_file, $archive_path)) {
            $self->{logger}->info("Archived file '$filename' to Archive/$setting_id/ directory");
        } else {
            $self->{logger}->error("Failed to archive file '$filename': $!");
        }
    }

    # Clean up the source file from plugin directory
    if (-f $source_file) {
        unlink($source_file) or $self->{logger}->warn("Could not remove temporary file $source_file: $!");
    }

    # Apply retention policy to the setting's archive directory
    if (defined $setting_id && $setting_id ne '') {
        $self->_apply_retention_policy($setting_id);
    }
}

sub _apply_retention_policy {
    my ( $self, $setting_id ) = @_;

    return unless defined $setting_id && $setting_id ne '';

    my $max_files = $self->retrieve_data('archive_retention_count') // 10;

    # If max_files is 0, retention is disabled (files are not archived)
    return if $max_files == 0;

    my $archive_dir = $self->{plugindir} . "/Archive/$setting_id";

    return unless -d $archive_dir;

    # Get list of files in the archive directory
    opendir(my $dh, $archive_dir) or do {
        $self->{logger}->warn("Cannot open archive directory $archive_dir: $!");
        return;
    };

    my @files;
    while (my $file = readdir($dh)) {
        next if $file =~ /^\./; # Skip . and ..
        my $full_path = "$archive_dir/$file";
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
