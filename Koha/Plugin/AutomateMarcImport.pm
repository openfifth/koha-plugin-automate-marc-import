package Koha::Plugin::AutomateMarcImport;

use Modern::Perl;

use base qw(Koha::Plugins::Base);
use Koha::File::Transports;
use Koha::UploadedFile;
use C4::Context;
use Koha::Logger;
use Koha::ImportBatches;
use C4::ImportBatch
    qw( RecordsFromISO2709File RecordsFromMARCXMLFile BatchStageMarcRecords SetImportBatchMatcher SetImportBatchOverlayAction SetImportBatchNoMatchAction SetImportBatchItemAction BatchFindDuplicates GetAllImportBatches );
use C4::Matcher;

our $VERSION = "0.0.1";

our $metadata = {
    name            => 'Automate Marc Import',
    author          => 'Open Fifth',
    date_authored   => '2022-05-19',
    date_updated    => '2022-05-19',
    minimum_version => '24.11.00.000', #WIP: will be changed to effectively whichever version first contains the SFTP work once it gets upstreamed
    maximum_version => undef,
    version         => $VERSION,
    description     => 'A Koha plugin to automate the import and staging of MARC files by enabling nightly retrieval via SFTP from vendor sites',
};

sub new {
    my ( $class, $args ) = @_;

    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    my $self = $class->SUPER::new($args);
    $self->{cgi} = CGI->new();
    $self->{logger} = Koha::Logger->get;
    $self->_set_plugin_dir();

    return $self;
}

sub configure {
    my ( $self, $args  ) = @_;
    my $cgi = $self->{'cgi'};

    if ( $cgi->param('save') ) {
        $self->store_data( { 
            item_action => scalar $cgi->param('item_action'),
            nomatch_action => scalar $cgi->param('nomatch_action'),
            overlay_action => scalar $cgi->param('overlay_action'),
            parse_items => scalar $cgi->param('parse_items'),
            selected_matcher => scalar $cgi->param('matcher'),
            selected_transport_servers => join(',', sort {$a <=> $b } $cgi->multi_param('transport_servers')),
            # format => scalar $cgi->param('format'), # determined programmatically
        });
        $self->go_home();
        return;
    }

    my $template = $self->get_template( { file => 'configure.tt' } );
    my @available_matchers = C4::Matcher::GetMatcherList();

    $template->param(
        available_matchers => \@available_matchers,
        available_transport_servers => Koha::File::Transports->search(),
        item_action => $self->retrieve_data('item_action'),
        nomatch_action => $self->retrieve_data('nomatch_action'),
        overlay_action => $self->retrieve_data('overlay_action'),
        parse_items => $self->retrieve_data('parse_items'),
        selected_matcher => $self->retrieve_data('selected_matcher'),
        selected_transport_servers => $self->retrieve_data('selected_transport_servers'),
        # format => $self->retrieve_data('format'), # determined programmatically
    );

    $self->output_html( $template->output() );
}

sub cronjob_nightly {
    my ( $self ) = @_;
    foreach my $transportId (split(',', $self->retrieve_data('selected_transport_servers'))) {
        my $transport = Koha::File::Transports->find($transportId);
        if (!defined $transport->download_directory) {
            $self->{logger}->error($transport->name . " does not have a download directory set and therefore could not be used.");
            next;
        }
        $transport->connect();
        $transport->change_directory($transport->download_directory);
        my $file_list = $transport->list_files();

        my $unique_id = 1;
        foreach my $filehash (@{$file_list}) {
            my $filename = $filehash->{filename};
            my $fileformat = $self->_identify_format($filename);
            if (!defined $fileformat) {
                $self->{logger}->error("Unsupported file format.");
                next;
            }
            my $localFile = Koha::UploadedFile->new({
                hashvalue          => $unique_id, # subject to change
                filename           => $filehash->{filename},
                dir                => $self->{plugindir},
                filesize           => $filehash->{a}->size,
                owner              => undef,
                uploadcategorycode => undef,
                public             => undef,
                permanent          => undef,
            });
            $unique_id += 1;
            $transport->download_file($filehash->{filename}, $localFile->full_path());
            $self->_stage($localFile->full_path(), $fileformat);
        }
    }
}

sub intranet_js {
    my ( $self ) = @_;
    if ($self->can('page') && $self->page != '/cgi-bin/koha/mainpage.pl') {
        return;
    }

    my $num_import_batches = Koha::ImportBatches->search({ import_status => 'staged' })->count;
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
            if (window.location.href.includes('admin-home.pl')) {
                const container = document.querySelector("main")
                const msgContainer = document.createElement("div")
                const linkToManageMarcImports = document.createElement("a")

                msgContainer.textContent = \"$message\"
                msgContainer.setAttribute('class', 'alert alert-info')
                linkToManageMarcImports.setAttribute('href','/cgi-bin/koha/tools/manage-marc-import.pl')
                linkToManageMarcImports.textContent = \"$link_text\"

                msgContainer.append(linkToManageMarcImports)
                container.prepend(msgContainer)
            }
        </script>
    |;
}

sub _identify_format {
    my ( $self, $filename ) = @_;
    if (substr($filename, -4) eq ".xml") {
        return 'MARCXML';
    }
    if (substr($filename, -4) eq ".mrc") {
        return 'ISO2709';
    }
    return undef;
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

sub _stage {
    my ( $self, $input_file_path, $format ) = @_;
    my $record_type = "biblio";
    my $encoding      = "UTF-8";
    my $add_items     = 0;
    my $batch_comment = "test comment";

    # TODO: Two profiles in "stage-marc-import": pass the marc modification template depending on file name: one for hard copy and one for ebook
    my $marc_mod_template_id = undef;

    # add server-level config options for the following ?
    my $matcher_id = $self->retrieve_data('selected_matcher');
    my $overlay_action = $self->retrieve_data('overlay_action');
    my $nomatch_action = $self->retrieve_data('nomatch_action');
    my $item_action = $self->retrieve_data('item_action');;

    # my $authorities   = 0;
    # my $marc_mod_template    = '';

    if ( !$input_file_path ) {
        $self->{logger}->trace("$0: cannot open input file $input_file_path: $!\n");
        return;
    }

    my $dbh = C4::Context->dbh;
    $dbh->{AutoCommit} = 0;

    my ( $errors, $marc_records );
    if ( $format eq 'ISO2709' ) {;
        ( $errors, $marc_records ) =
            C4::ImportBatch::RecordsFromISO2709File( $input_file_path, $record_type, $encoding);
    } elsif ( $format eq 'MARCXML' ) {
        ( $errors, $marc_records ) =
            C4::ImportBatch::RecordsFromMARCXMLFile( $input_file_path, $encoding);
    }

    #WIP: would something akin to this make sense?
    while (my $error = shift @{$errors}) {
        $self->{logger}->error($error);
    }

    my $num_input_records = ($marc_records) ? scalar(@$marc_records) : 0;

    $self->{logger}->trace("MARC records staging process started");
    my ( $batch_id, $num_valid_records, $num_items, @import_errors ) = BatchStageMarcRecords(
        $record_type,                        $encoding,
        $marc_records,                       $input_file_path,
        $marc_mod_template_id,               $batch_comment,
        '',                                  $add_items,
        0,                                 100,
        \&_log_progress # TODO: figure this out
    );
    $self->{logger}->trace("finished staging MARC records");
    my $num_invalid_records = scalar(@import_errors);
    my $num_with_matches = $self->_search_for_matches($record_type, $overlay_action, $nomatch_action, $item_action, $batch_id, $matcher_id);
    $self->_log_summary($num_with_matches, $record_type, $num_input_records, $num_valid_records, $num_invalid_records, $input_file_path, $num_items, $batch_id);
    $dbh->commit();
}

sub _search_for_matches {
    my ( $self, $record_type, $overlay_action, $nomatch_action, $item_action, $batch_id, $matcher_id ) = @_;
    my $num_with_matches = 0;
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
    # set default record overlay behavior
    SetImportBatchOverlayAction( $batch_id, $overlay_action ? 'ignore' : 'replace' );
    SetImportBatchNoMatchAction( $batch_id, $nomatch_action ? 'ignore' : 'create_new' );
    SetImportBatchItemAction( $batch_id, $item_action );
    $self->{logger}->trace("Started looking for matches with records already in database\n");
    $num_with_matches = BatchFindDuplicates( $batch_id, $matcher, 10, 100, $self->_log_progress );
    $self->{logger}->trace("Finished looking for matches\n");
    return $num_with_matches;
}

sub _log_progress {
    my $num_input_records = shift;
    my $logger = Koha::Logger->get;
    $logger->trace("processed $num_input_records records");
}

#WIP: good or horrible idea ? Again, reflects what stage_file.pl would've printed.
sub _log_summary {
    my ( $self, $num_with_matches, $record_type, $num_input_records, $num_valid_records, $num_invalid_records, $input_file_path, $num_items, $batch_id) = @_;

    # TODO: refactor - see how similar processes get logged - this is based off of what gets printed when running stage_file.pl
    $self->{logger}->trace("MARC record staging report");
    $self->{logger}->trace("------------------------------------");
    $self->{logger}->trace("Input file:                 $input_file_path");
    $self->{logger}->trace("Record type:                $record_type");
    $self->{logger}->trace("Number of input records:    $num_input_records");
    $self->{logger}->trace("Number of valid records:    $num_valid_records");
    $self->{logger}->trace("Number of invalid records:  $num_invalid_records");

    $self->{logger}->trace("Number of records matched:  $num_with_matches\n");

    if ( $record_type eq 'biblio' ) {
        $self->{logger}->trace("Number of items parsed:  $num_items\n");
    }
    $self->{logger}->trace("\n");
    $self->{logger}->trace("Batch number assigned:  $batch_id\n");
    $self->{logger}->trace("\n");
}

1;