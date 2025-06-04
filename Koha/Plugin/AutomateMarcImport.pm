package Koha::Plugin::AutomateMarcImport;

use Modern::Perl;

use base qw(Koha::Plugins::Base);
use Koha::File::Transports;
use C4::Context;

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

1;