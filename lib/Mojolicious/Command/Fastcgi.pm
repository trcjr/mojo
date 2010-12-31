package Mojolicious::Command::Fastcgi;

use strict;
use warnings;

use base 'Mojo::Command';

use Mojo::Server::FastCGI;

__PACKAGE__->attr(description => <<'EOF');
Start application with FastCGI.
EOF
__PACKAGE__->attr(usage => <<"EOF");
usage: $0 fastcgi
EOF

# Oh boy! Sleep! That's when I'm a Viking!
sub run {
    my $self    = shift;
    my $fastcgi = Mojo::Server::FastCGI->new;

    # Run
    $fastcgi->run;

    return $self;
}

1;
__END__

=head1 NAME

Mojolicious::Command::Fastcgi - FastCGI Command

=head1 SYNOPSIS

    use Mojolicious::Command::Fastcgi;

    my $fastcgi = Mojolicious::Command::Fastcgi->new;
    $fastcgi->run;

=head1 DESCRIPTION

L<Mojolicious::Command::Fastcgi> is a command interface to
L<Mojo::Server::FastCGI>.

=head1 ATTRIBUTES

L<Mojolicious::Command::FastCGI> inherits all attributes from
L<Mojo::Command> and implements the following new ones.

=head2 C<description>

    my $description = $fastcgi->description;
    $fastcgi        = $fastcgi->description('Foo!');

Short description of this command, used for the command list.

=head2 C<usage>

    my $usage = $fastcgi->usage;
    $fastcgi  = $fastcgi->usage('Foo!');

Usage information for this command, used for the help screen.

=head1 METHODS

L<Mojolicious::Command::Fastcgi> inherits all methods from L<Mojo::Command>
and implements the following new ones.

=head2 C<run>

    $fastcgi = $fastcgi->run;

Run this command.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
