package Koha::Plugin::AutomateMarcImport;

use Modern::Perl;

use base qw(Koha::Plugins::Base);
use Koha::File::Transports;
use Koha::UploadedFile;
use C4::Context;
use Koha::Logger;

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
        my $selected_transport_servers = join(',', sort {$a <=> $b } $cgi->multi_param('transport_servers'));
        $self->store_data( { selected_transport_servers => $selected_transport_servers } );
        $self->go_home();
        return;
    }

    my $template = $self->get_template( { file => 'configure.tt' } );
    my $available_transport_servers = Koha::File::Transports->search();

    $template->param(
        available_transport_servers => $available_transport_servers,
        selected_transport_servers => $self->retrieve_data('selected_transport_servers')
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
            if (substr($filename, -4) ne ".mrc" && substr($filename, -4) ne ".xml") {
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
        }
    }
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

1;