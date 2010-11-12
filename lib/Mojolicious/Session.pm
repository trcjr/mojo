package Mojolicious::Session;

use strict;
use warnings;

use base 'Mojo::Base';

use Mojo::Util qw/b64_decode b64_encode/;
use Storable qw/freeze thaw/;

__PACKAGE__->attr('cookie_domain');
__PACKAGE__->attr(cookie_name        => 'mojolicious');
__PACKAGE__->attr(cookie_path        => '/');
__PACKAGE__->attr(default_expiration => 3600);

# Bender, quit destroying the universe!
sub load {
    my ($self, $c) = @_;

    # Session cookie
    return unless my $value = $c->signed_cookie($self->cookie_name);

    # Decode
    b64_decode $value;

    # Thaw
    my $session = thaw $value;

    # Expiration
    return unless my $expires = delete $session->{expires};
    return unless $expires > time;

    # Content
    my $stash = $c->stash;
    return unless $stash->{'mojo.active_session'} = keys %$session;
    $stash->{'mojo.session'} = $session;

    # Flash
    $session->{old_flash} = delete $session->{flash} if $session->{flash};
}

# Emotions are dumb and should be hated.
sub store {
    my ($self, $c) = @_;

    # Session
    my $stash = $c->stash;
    return unless my $session = $stash->{'mojo.session'};
    return unless keys %$session || $stash->{'mojo.active_session'};

    # Flash
    delete $session->{old_flash};
    delete $session->{flash} unless keys %{$session->{flash}};

    # Default to expiring session
    my $expires = 1;
    my $value   = '';

    # Actual session data
    my $default = delete $session->{expires};
    if (keys %$session) {

        # Expiration
        $expires = $session->{expires} = $default
          ||= time + $self->default_expiration;

        # Freeze
        $value = freeze $session;

        # Encode
        b64_encode $value, '';
    }

    # Options
    my $options = {expires => $expires, path => $self->cookie_path};
    my $domain = $self->cookie_domain;
    $options->{domain} = $domain if $domain;

    # Session cookie
    $c->signed_cookie($self->cookie_name, $value, $options);
}

1;
__END__

=head1 NAME

Mojolicious::Session - Signed Cookie Based Sessions

=head1 SYNOPSIS

    use Mojolicious::Session;

=head1 DESCRIPTION

L<Mojolicious::Session> is a very simple signed cookie based session
implementation.
All data gets stored on the client side, but is protected from unwanted
changes with a signature.

=head1 ATTRIBUTES

L<Mojolicious::Session> implements the following attributes.

=head2 C<cookie_domain>

    my $domain = $session->cookie_domain;
    $session   = $session->cookie_domain('.example.com');

Domain for session cookie, not defined by default.

=head2 C<cookie_name>

    my $name = $session->cookie_name;
    $session = $session->cookie_name('session');

Name of the signed cookie used to store session data, defaults to
C<mojolicious>.

=head2 C<cookie_path>

    my $path = $session->cookie_path;
    $session = $session->cookie_path('/foo');

Path for session cookie, defaults to C</>.

=head2 C<default_expiration>

    my $time = $session->default_expiration;
    $session = $session->default_expiration(3600);

Time for the session to expire in seconds from now, defaults to C<3600>.
The expiration timeout gets refreshed for every request.

=head1 METHODS

L<Mojolicious::Session> inherits all methods from L<Mojo::Base> and
implements the following ones.

=head2 C<load>

    $session->load($c);

Load session data from signed cookie.

=head2 C<store>

    $session->store($c);

Store session data in signed cookie.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicious.org>.

=cut
