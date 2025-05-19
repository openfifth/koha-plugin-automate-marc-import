package Koha::Plugin::AutomateMarcImport;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

our $VERSION = "0.0";

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

# Your plugin code here

1;