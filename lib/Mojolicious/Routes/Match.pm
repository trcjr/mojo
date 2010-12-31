package Mojolicious::Routes::Match;

use strict;
use warnings;

use base 'Mojo::Base';

use Carp 'croak';
use Mojo::Util qw/decode url_unescape/;
use Mojo::URL;
use Scalar::Util 'weaken';

__PACKAGE__->attr(captures => sub { {} });
__PACKAGE__->attr([qw/endpoint root/]);
__PACKAGE__->attr(stack => sub { [] });

# I'm Bender, baby, please insert liquor!
sub new {
    my $self = shift->SUPER::new();
    my $c    = shift;

    # Controller
    $self->{_controller} = $c;
    weaken $self->{_controller};

    # Path
    unless ($self->{_path} = shift) {
        $self->{_path} = $c->req->url->path->to_string;
        url_unescape $self->{_path};
        decode 'UTF8', $self->{_path};
    }

    return $self;
}

# Life can be hilariously cruel.
sub match {
    my ($self, $r) = @_;

    # Shortcut
    return unless $r;

    # Dictionary
    my $dictionary = $self->{_dictionary} ||= $r->dictionary;

    # Root
    $self->root($r) unless $self->root;

    # Path
    my $path = $self->{_path};

    # Pattern
    my $pattern = $r->pattern;

    # Match
    my $captures = $pattern->shape_match(\$path);

    # No match
    return unless $captures;

    # Merge captures
    $captures = {%{$self->captures}, %$captures};
    $self->captures($captures);

    # Conditions
    my $conditions = $r->conditions;
    for (my $i = 0; $i < @$conditions; $i += 2) {
        my $name      = $conditions->[$i];
        my $value     = $conditions->[$i + 1];
        my $condition = $dictionary->{$name};

        # No condition
        return unless $condition;

        # Match
        return
          if !$condition->($r, $self->{_controller}, $captures, $value);
    }

    # Partial
    if (my $partial = $r->partial) {
        $captures->{$partial} = $path;
        $path = '';
    }
    $self->{_path} = $path;

    # Format
    if ($r->is_endpoint && !$pattern->format) {
        if ($path =~ /^\.([^\/]+)$/) {
            $captures->{format} = $1;
            $self->{_path}      = '';
        }
    }
    $captures->{format} ||= $pattern->format if $pattern->format;

    # Update stack
    if ($r->inline || ($r->is_endpoint && $self->_is_path_empty)) {
        push @{$self->stack}, {%$captures};
        delete $captures->{cb};
        delete $captures->{app};
    }

    # Waypoint match
    if ($r->block && $self->_is_path_empty) {
        $self->endpoint($r);
        return $self;
    }

    # Match children
    my $snapshot = [@{$self->stack}];
    for my $child (@{$r->children}) {

        # Match
        $self->match($child);

        # Endpoint found
        return $self if $self->endpoint;

        # Reset path
        $self->{_path} = $path;

        # Reset stack
        if ($r->parent) { $self->stack([@$snapshot]) }
        else {
            $self->captures({});
            $self->stack([]);
        }
    }

    $self->endpoint($r) if $r->is_endpoint && $self->_is_path_empty;

    return $self;
}

sub url_for {
    my $self     = shift;
    my $endpoint = $self->endpoint;
    my $values   = {};
    my $name     = undef;

    # Single argument
    if (@_ == 1) {

        # Hash
        $values = shift if ref $_[0] eq 'HASH';

        # Name
        $name = $_[0] if $_[0];
    }

    # Multiple arguments
    elsif (@_ > 1) {

        # Odd
        if (@_ % 2) {
            $name   = shift;
            $values = {@_};
        }

        # Even
        else {

            # Name and hashref
            if (ref $_[1] eq 'HASH') {
                $name   = shift;
                $values = shift;
            }

            # Just values
            else { $values = {@_} }

        }
    }

    # Captures
    my $captures = $self->captures;

    # Named
    if ($name) {

        # Current route
        if ($name eq 'current') { $name = undef }

        # Find
        else {
            $captures = {};
            return unless $endpoint = $self->_find_route($name);
        }
    }

    # Merge values
    $values = {%$captures, format => undef, %$values};

    # URL
    my $url = Mojo::URL->new;

    # No endpoint
    return $url unless $endpoint;

    # Base
    $url->base($self->{_controller}->req->url->base->clone);
    my $base = $url->base;
    $url->base->userinfo(undef);

    # Render
    my $path = $endpoint->render($url->path->to_string, $values);
    $url->path->parse($path);

    # Fix scheme
    if ($endpoint->is_websocket) {
        $base->scheme(($base->scheme || '') eq 'https' ? 'wss' : 'ws');
    }

    # Fix paths
    unshift @{$url->path->parts}, @{$base->path->parts};
    $base->path->parts([]);

    return $url;
}

sub _find_route {
    my ($self, $name) = @_;

    # Find endpoint
    my @children = ($self->root);
    while (my $child = shift @children) {

        # Match
        return $child if ($child->name || '') eq $name;

        # Append
        push @children, @{$child->children};
    }

    # Not found
    return;
}

sub _is_path_empty {
    my $self = shift;
    return 1 if !length $self->{_path} || $self->{_path} eq '/';
    return;
}

1;
__END__

=head1 NAME

Mojolicious::Routes::Match - Routes Visitor

=head1 SYNOPSIS

    use Mojolicious::Routes::Match;

=head1 DESCRIPTION

L<Mojolicious::Routes::Match> is a visitor for L<Mojolicious::Routes>
structures.

=head1 ATTRIBUTES

L<Mojolicious::Routes::Match> implements the following attributes.

=head2 C<captures>

    my $captures = $m->captures;
    $m           = $m->captures({foo => 'bar'});

Captured parameters.

=head2 C<endpoint>

    my $endpoint = $m->endpoint;
    $m           = $m->endpoint(Mojolicious::Routes->new);

The routes endpoint that actually matched.

=head2 C<root>

    my $root = $m->root;
    $m       = $m->root($routes);

The root of the routes tree.

=head2 C<stack>

    my $stack = $m->stack;
    $m        = $m->stack([{foo => 'bar'}]);

Captured parameters with nesting history.

=head1 METHODS

L<Mojolicious::Routes::Match> inherits all methods from L<Mojo::Base> and
implements the following ones.

=head2 C<new>

    my $m = Mojolicious::Routes::Match->new(Mojolicious:Controller->new);

Construct a new match object.

=head2 C<match>

    $m->match(Mojolicious::Routes->new);

Match against a routes tree.

=head2 C<url_for>

    my $url = $m->url_for;
    my $url = $m->url_for(foo => 'bar');
    my $url = $m->url_for({foo => 'bar'});
    my $url = $m->url_for('named');
    my $url = $m->url_for('named', foo => 'bar');
    my $url = $m->url_for('named', {foo => 'bar'});

Render matching route with parameters into a L<Mojo::URL> object.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
