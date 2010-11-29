package Mojolicious::Routes;

use strict;
use warnings;

use base 'Mojo::Base';

use Mojo::Exception;
use Mojo::Loader;
use Mojo::URL;
use Mojo::Util 'camelize';
use Mojolicious::Routes::Match;
use Mojolicious::Routes::Pattern;
use Scalar::Util 'weaken';

__PACKAGE__->attr([qw/block inline parent partial/]);
__PACKAGE__->attr([qw/children conditions/] => sub { [] });
__PACKAGE__->attr(controller_base_class => 'Mojolicious::Controller');
__PACKAGE__->attr(dictionary => sub { {} });
__PACKAGE__->attr(hidden => sub { [qw/new app attr render req res stash tx/] }
);
__PACKAGE__->attr('namespace');
__PACKAGE__->attr(pattern => sub { Mojolicious::Routes::Pattern->new });

# Yet thanks to my trusty safety sphere,
# I sublibed with only tribial brain dablage.
sub new {
    my $self = shift->SUPER::new();

    # Parse
    $self->parse(@_);

    # Method condition
    $self->add_condition(
        method => sub {
            my ($r, $c, $captures, $methods) = @_;

            # Methods
            return unless $methods && ref $methods eq 'ARRAY';

            # Match
            my $m = lc $c->req->method;
            $m = 'get' if $m eq 'head';
            for my $method (@$methods) {
                return 1 if $method eq $m;
            }

            # Nothing
            return;
        }
    );

    # WebSocket condition
    $self->add_condition(
        websocket => sub {
            my ($r, $c, $captures) = @_;

            # WebSocket
            return 1 if $c->tx->is_websocket;

            # Not a WebSocket
            return;
        }
    );

    return $self;
}

sub add_child {
    my ($self, $route) = @_;

    # We are the parent
    $route->parent($self);
    weaken $route->{parent};

    # Add to tree
    push @{$self->children}, $route;

    return $self;
}

sub add_condition {
    my ($self, $name, $condition) = @_;

    # Add
    $self->dictionary->{$name} = $condition;

    return $self;
}

sub any { shift->_generate_route(ref $_[0] ? shift : [], @_) }

# Hey. What kind of party is this? There's no booze and only one hooker.
sub auto_render {
    my ($self, $c) = @_;

    # Transaction
    my $tx = $c->tx;

    # Rendering
    my $success = eval {

        # Render
        $c->render unless $c->stash->{'mojo.rendered'} || $tx->is_websocket;

        # Success
        1;
    };

    # Renderer error
    $c->render_exception($@) if !$success && $@;

    # Rendered
    return;
}

sub bridge { shift->route(@_)->inline(1) }

sub detour {
    my $self = shift;

    # Partial
    $self->partial('path');

    # Defaults
    $self->to(@_);

    return $self;
}

sub dispatch {
    my ($self, $c) = @_;

    # Response
    my $res = $c->res;

    # Already rendered
    return if $res->code;

    # Path
    my $path = $c->stash->{path};
    $path = "/$path" if defined $path && $path !~ /^\//;

    # Match
    my $m = Mojolicious::Routes::Match->new($c, $path);
    $m->match($self);
    $c->match($m);

    # No match
    return 1 unless $m && @{$m->stack};

    # Status
    unless ($res->code) {

        # Websocket handshake
        $res->code(101) if !$res->code && $c->tx->is_websocket;

        # Error or 200
        my ($error, $code) = $c->req->error;
        $res->code($code) if $code;
    }

    # Walk the stack
    return 1 if $self->_walk_stack($c);

    # Render
    return $self->auto_render($c);
}

sub get { shift->_generate_route('get', @_) }

sub hide { push @{shift->hidden}, @_ }

sub is_endpoint {
    my $self = shift;
    return   if $self->inline;
    return 1 if $self->block;
    return   if @{$self->children};
    return 1;
}

sub is_websocket {
    my $self = shift;
    return 1 if $self->{_websocket};
    if (my $parent = $self->parent) { return $parent->is_websocket }
    return;
}

# Dr. Zoidberg, can you note the time and declare the patient legally dead?
# Can I! That’s my specialty!
sub name {
    my ($self, $name) = @_;

    # New name
    if (defined $name) {

        # Generate
        if ($name eq '*') {
            $name = $self->pattern->pattern;
            $name =~ s/\W+//g;
        }
        $self->{_name} = $name;

        return $self;
    }

    return $self->{_name};
}

sub over {
    my $self = shift;

    # Shortcut
    return $self unless @_;

    # Conditions
    my $conditions = ref $_[0] eq 'ARRAY' ? $_[0] : [@_];
    push @{$self->conditions}, @$conditions;

    return $self;
}

sub parse {
    my $self = shift;

    # Pattern does the real work
    $self->pattern->parse(@_);

    return $self;
}

sub post { shift->_generate_route('post', @_) }

sub render {
    my ($self, $path, $values) = @_;

    # Path prefix
    my $prefix = $self->pattern->render($values);
    $path = $prefix . $path unless $prefix eq '/';

    # Make sure there is always a root
    $path = '/' if !$path && !$self->parent;

    # Format
    if ((my $format = $values->{format}) && !$self->parent) {
        $path .= ".$format" unless $path =~ /\.[^\/]+$/;
    }

    # Parent
    $path = $self->parent->render($path, $values) if $self->parent;

    return $path;
}

# Morbo forget how you spell that letter that looks like a man wearing a hat.
# Hello, tiny man. I will destroy you!
sub route {
    my $self = shift;

    # New route
    my $route = $self->new(@_);
    $self->add_child($route);

    return $route;
}

sub to {
    my $self = shift;

    # Shortcut
    return $self unless @_;

    # Single argument
    my ($shortcut, $defaults);
    if (@_ == 1) {

        # Hash
        $defaults = shift if ref $_[0] eq 'HASH';
        $shortcut = shift if $_[0];
    }

    # Multiple arguments
    else {

        # Odd
        if (@_ % 2) {
            $shortcut = shift;
            $defaults = {@_};
        }

        # Even
        else {

            # Shortcut and defaults
            if (ref $_[1] eq 'HASH') {
                $shortcut = shift;
                $defaults = shift;
            }

            # Just defaults
            else { $defaults = {@_} }
        }
    }

    # Shortcut
    if ($shortcut) {

        # App
        if (ref $shortcut || $shortcut =~ /^[\w\:]+$/) {
            $defaults->{app} = $shortcut;
        }

        # Controller and action
        elsif ($shortcut =~ /^([\w\-]+)?\#(\w+)?$/) {
            $defaults->{controller} = $1 if defined $1;
            $defaults->{action}     = $2 if defined $2;
        }
    }

    # Pattern
    my $pattern = $self->pattern;

    # Defaults
    my $old = $pattern->defaults;
    $pattern->defaults({%$old, %$defaults}) if $defaults;

    return $self;
}

sub to_string {
    my $self = shift;
    my $pattern = $self->parent ? $self->parent->to_string : '';
    $pattern .= $self->pattern->pattern if $self->pattern->pattern;
    return $pattern;
}

sub under { shift->_generate_route('under', @_) }

sub via {
    my $self = shift;

    # Methods
    my $methods = ref $_[0] ? $_[0] : [@_];

    # Shortcut
    return $self unless @$methods;

    # Condition
    push @{$self->conditions}, method => [map { lc $_ } @$methods];

    return $self;
}

sub waypoint { shift->route(@_)->block(1) }

sub websocket {
    my $self = shift;

    # Route
    my $route = $self->any(@_);

    # Condition
    push @{$route->conditions}, websocket => 1;
    $route->{_websocket} = 1;

    return $route;
}

sub _dispatch_callback {
    my ($self, $c, $staging) = @_;

    # Debug
    $c->app->log->debug(qq/Dispatching callback./);

    # Dispatch
    my $continue;
    my $cb      = $c->match->captures->{cb};
    my $success = eval {

        # Callback
        $continue = $cb->($c);

        # Success
        1;
    };

    # Callback error
    if (!$success && $@) {
        my $e = Mojo::Exception->new($@);
        $c->app->log->error($e);
        return $e;
    }

    # Success!
    return 1 unless $staging;
    return 1 if $continue;

    return;
}

sub _dispatch_controller {
    my ($self, $c, $staging) = @_;

    # Application
    my $app = $c->match->captures->{app};

    # Class
    $app ||= $self->_generate_class($c);
    return 1 unless $app;

    # Method
    my $method = $self->_generate_method($c);

    # Debug
    my $dispatch = ref $app || $app;
    $dispatch .= "->$method" if $method;
    $c->app->log->debug("Dispatching $dispatch.");

    # Load class
    unless (ref $app && $self->{_loaded}->{$app}) {

        # Load
        if (my $e = Mojo::Loader->load($app)) {

            # Doesn't exist
            unless (ref $e) {
                $c->app->log->debug("$app does not exist, maybe a typo?");
                return;
            }

            # Error
            $c->app->log->error($e);
            return $e;
        }

        # Loaded
        $self->{_loaded}->{$app}++;
    }

    # Dispatch
    my $continue;
    my $success = eval {

        # Instantiate
        $app = $app->new($c) unless ref $app;

        # Action
        if ($method && $app->isa($self->controller_base_class)) {

            # Call action
            $continue = $app->$method if $app->can($method);

            # Merge stash
            my $new = $app->stash;
            @{$c->stash}{keys %$new} = values %$new;
        }

        # Handler
        elsif ($app->isa('Mojo')) {

            # Connect routes
            if ($app->can('routes')) {
                my $r = $app->routes;
                unless ($r->parent) {
                    $r->parent($c->match->endpoint);
                    weaken $r->{parent};
                }
            }

            # Handler
            $app->handler($c);
        }

        # Success
        1;
    };

    # Controller error
    if (!$success && $@) {
        my $e = Mojo::Exception->new($@);
        $c->app->log->error($e);
        return $e;
    }

    # Success!
    return 1 unless $staging;
    return 1 if $continue;

    return;
}

sub _generate_class {
    my ($self, $c) = @_;

    # Field
    my $field = $c->match->captures;

    # Class
    my $class = $field->{class};
    my $controller = $field->{controller} || '';
    unless ($class) {
        $class = $controller;
        camelize $class;
    }

    # Namespace
    my $namespace = $field->{namespace};
    $namespace = $self->namespace unless defined $namespace;
    $class = length $class ? "${namespace}::$class" : $namespace
      if length $namespace;

    # Invalid
    return unless $class =~ /^[a-zA-Z0-9_:]+$/;

    return $class;
}

sub _generate_method {
    my ($self, $c) = @_;

    # Field
    my $field = $c->match->captures;

    # Prepare hidden
    unless ($self->{_hidden}) {
        $self->{_hidden} = {};
        $self->{_hidden}->{$_}++ for @{$self->hidden};
    }

    my $method = $field->{method};
    $method ||= $field->{action};

    # Shortcut
    return unless $method;

    # Shortcut for hidden methods
    if ($self->{_hidden}->{$method} || index($method, '_') == 0) {
        $c->app->log->debug(qq/Action "$method" is not allowed./);
        return;
    }

    # Invalid
    unless ($method =~ /^[a-zA-Z0-9_:]+$/) {
        $c->app->log->debug(qq/Action "$method" is invalid./);
        return;
    }

    return $method;
}

sub _generate_route {
    my ($self, $methods, @args) = @_;

    my ($cb, $constraints, $defaults, $name, $pattern);
    my $conditions = [];

    # Route information
    while (defined(my $arg = shift @args)) {

        # First scalar is the pattern
        if (!ref $arg && !$pattern) { $pattern = $arg }

        # Scalar
        elsif (!ref $arg && @args) {
            push @$conditions, $arg, shift @args;
        }

        # Last scalar is the route name
        elsif (!ref $arg) { $name = $arg }

        # Callback
        elsif (ref $arg eq 'CODE') { $cb = $arg }

        # Constraints
        elsif (ref $arg eq 'ARRAY') { $constraints = $arg }

        # Defaults
        elsif (ref $arg eq 'HASH') { $defaults = $arg }
    }

    # Defaults
    $constraints ||= [];

    # Defaults
    $defaults ||= {};
    $defaults->{cb} = $cb if $cb;

    # Name
    $name ||= '';

    # Create bridge
    return $self->bridge($pattern, {@$constraints})->over($conditions)
      ->to($defaults)->name($name)
      if !ref $methods && $methods eq 'under';

    # Create route
    my $route =
      $self->route($pattern, {@$constraints})->over($conditions)
      ->via($methods)->to($defaults)->name($name);

    return $route;
}

sub _walk_stack {
    my ($self, $c) = @_;

    # Stack
    my $stack = $c->match->stack;

    # Walk the stack
    my $staging = @$stack;
    for my $field (@$stack) {
        $staging--;

        # Stash
        my $stash = $c->stash;

        # Captures
        my $captures = $stash->{'mojo.captures'} ||= {};
        $stash->{'mojo.captures'} = {%$captures, %$field};

        # Merge in captures
        @{$c->stash}{keys %$field} = values %$field;

        # Captures
        $c->match->captures($field);

        # Dispatch
        my $e =
            $field->{cb}
          ? $self->_dispatch_callback($c, $staging)
          : $self->_dispatch_controller($c, $staging);

        # Exception
        if (ref $e) {
            $c->render_exception($e);
            return 1;
        }

        # Break the chain
        return 1 if $staging && !$e;
    }

    # Done
    return;
}

1;
__END__

=head1 NAME

Mojolicious::Routes - Always Find Your Destination With Routes

=head1 SYNOPSIS

    use Mojolicious::Routes;

    # New routes tree
    my $r = Mojolicious::Routes->new;

    # Normal route matching "/articles" with parameters "controller" and
    # "action"
    $r->route('/articles')->to(controller => 'article', action => 'list');

    # Route with a placeholder matching everything but "/" and "."
    $r->route('/:controller')->to(action => 'list');

    # Route with a placeholder and regex constraint
    $r->route('/articles/:id', id => qr/\d+/)
      ->to(controller => 'article', action => 'view');

    # Route with an optional parameter "year"
    $r->route('/archive/:year')
      ->to(controller => 'archive', action => 'list', year => undef);

    # Nested route for two actions sharing the same "controller" parameter
    my $books = $r->route('/books/:id')->to(controller => 'book');
    $books->route('/edit')->to(action => 'edit');
    $books->route('/delete')->to(action => 'delete');

    # Bridges can be used to chain multiple routes
    $r->bridge->to(controller => 'foo', action =>'auth')
      ->route('/blog')->to(action => 'list');

    # Waypoints are similar to bridges and nested routes but can also match
    # if they are not the actual endpoint of the whole route
    my $b = $r->waypoint('/books')->to(controller => 'books', action => 'list');
    $b->route('/:id', id => qr/\d+/)->to(action => 'view');

    # Simplified Mojolicious::Lite style route generation is also possible
    $r->get('/')->to(controller => 'blog', action => 'welcome');
    my $blog = $r->under('/blog');
    $blog->post('/list')->to('blog#list');
    $blog->get(sub { shift->render(text => 'Go away!') });

=head1 DESCRIPTION

L<Mojolicious::Routes> is a very powerful implementation of the famous routes
pattern and the core of the L<Mojolicious> web framework.
See L<Mojolicious::Guide::Routing> for more.

=head1 ATTRIBUTES

L<Mojolicious::Routes> implements the following attributes.

=head2 C<block>

    my $block = $r->block;
    $r        = $r->block(1);

Allow this route to match even if it's not an endpoint, used for waypoints.

=head2 C<children>

    my $children = $r->children;
    $r           = $r->children([Mojolicious::Routes->new]);

The children of this routes object, used for nesting routes.

=head2 C<conditions>

    my $conditions  = $r->conditions;
    $r              = $r->conditions([foo => qr/\w+/]);

Contains condition parameters for this route, used for C<over>.

=head2 C<controller_base_class>

    my $base = $r->controller_base_class;
    $r       = $r->controller_base_class('Mojolicious::Controller');

Base class used to identify controllers, defaults to
L<Mojolicious::Controller>.

=head2 C<dictionary>

    my $dictionary = $r->dictionary;
    $r             = $r->dictionary({foo => sub { ... }});

Contains all available conditions for this route.
There are currently two conditions built in, C<method> and C<websocket>.

=head2 C<hidden>

    my $hidden = $r->hidden;
    $r         = $r->hidden([qw/new attr tx render req res stash/]);

Controller methods and attributes that are hidden from routes.

=head2 C<inline>

    my $inline = $r->inline;
    $r         = $r->inline(1);

Allow C<bridge> semantics for this route.

=head2 C<namespace>

    my $namespace = $r->namespace;
    $r            = $r->namespace('Foo::Bar::Controller');

Namespace to search for controllers.

=head2 C<parent>

    my $parent = $r->parent;
    $r         = $r->parent(Mojolicious::Routes->new);

The parent of this route, used for nesting routes.

=head2 C<partial>

    my $partial = $r->partial;
    $r          = $r->partial('path');

Route has no specific end, remaining characters will be captured with the
partial name.
Note that this attribute is EXPERIMENTAL and might change without warning!

=head2 C<pattern>

    my $pattern = $r->pattern;
    $r          = $r->pattern(Mojolicious::Routes::Pattern->new);

Pattern for this route, by default a L<Mojolicious::Routes::Pattern> object
and used for matching.

=head1 METHODS

L<Mojolicious::Routes> inherits all methods from L<Mojo::Base> and implements
the following ones.

=head2 C<new>

    my $r = Mojolicious::Routes->new;
    my $r = Mojolicious::Routes->new('/:controller/:action');

Construct a new route object.

=head2 C<add_child>

    $r = $r->add_child(Mojolicious::Route->new);

Add a new child to this route.

=head2 C<add_condition>

    $r = $r->add_condition(foo => sub { ... });

Add a new condition for this route.

=head2 C<any>

    my $any = $route->any('/:foo' => sub {...});
    my $any = $route->any([qw/get post/] => '/:foo' => sub {...});

Generate route matching any of the listed HTTP request methods or all.
See also the L<Mojolicious::Lite> tutorial for more argument variations.
Note that this method is EXPERIMENTAL and might change without warning!

=head2 C<auto_render>

    $r->auto_render(Mojolicious::Controller->new);

Automatic rendering.

=head2 C<bridge>

    my $bridge = $r->bridge;
    my $bridge = $r->bridge('/:controller/:action');

Add a new bridge to this route as a nested child.

=head2 C<detour>

    $r = $r->detour(action => 'foo');
    $r = $r->detour({action => 'foo'});
    $r = $r->detour('controller#action');
    $r = $r->detour('controller#action', foo => 'bar');
    $r = $r->detour('controller#action', {foo => 'bar'});
    $r = $r->detour($app);
    $r = $r->detour($app, foo => 'bar');
    $r = $r->detour($app, {foo => 'bar'});
    $r = $r->detour('MyApp');
    $r = $r->detour('MyApp', foo => 'bar');
    $r = $r->detour('MyApp', {foo => 'bar'});

Set default parameters for this route and allow partial matching to simplify
application embedding.
Note that this method is EXPERIMENTAL and might change without warning!

=head2 C<dispatch>

    my $e = $r->dispatch(Mojolicious::Controller->new);

Match routes and dispatch.

=head2 C<get>

    my $get = $route->get('/:foo' => sub {...});

Generate route matching only C<GET> requests.
See also the L<Mojolicious::Lite> tutorial for more argument variations.
Note that this method is EXPERIMENTAL and might change without warning!

=head2 C<hide>

    $r = $r->hide('new');

Hide controller method or attribute from routes.

=head2 C<is_endpoint>

    my $is_endpoint = $r->is_endpoint;

Returns true if this route qualifies as an endpoint.

=head2 C<is_websocket>

    my $is_websocket = $r->is_websocket;

Returns true if this route leads to a WebSocket.

=head2 C<name>

    my $name = $r->name;
    $r       = $r->name('foo');
    $r       = $r->name('*');

The name of this route, the special value C<*> will generate a name based on
the route pattern.
Note that the name C<current> is reserved for refering to the current route.

=head2 C<over>

    $r = $r->over(foo => qr/\w+/);

Apply condition parameters to this route.

=head2 C<parse>

    $r = $r->parse('/:controller/:action');

Parse a pattern.

=head2 C<post>

    my $post = $route->post('/:foo' => sub {...});

Generate route matching only C<POST> requests.
See also the L<Mojolicious::Lite> tutorial for more argument variations.
Note that this method is EXPERIMENTAL and might change without warning!

=head2 C<render>

    my $path = $r->render($path);
    my $path = $r->render($path, {foo => 'bar'});

Render route with parameters into a path.

=head2 C<route>

    my $route = $r->route('/:c/:a', a => qr/\w+/);

Add a new nested child to this route.

=head2 C<to>

    my $to  = $r->to;
    $r = $r->to(action => 'foo');
    $r = $r->to({action => 'foo'});
    $r = $r->to('controller#action');
    $r = $r->to('controller#action', foo => 'bar');
    $r = $r->to('controller#action', {foo => 'bar'});
    $r = $r->to($app);
    $r = $r->to($app, foo => 'bar');
    $r = $r->to($app, {foo => 'bar'});
    $r = $r->to('MyApp');
    $r = $r->to('MyApp', foo => 'bar');
    $r = $r->to('MyApp', {foo => 'bar'});

Set default parameters for this route.

=head2 C<to_string>

    my $string = $r->to_string;

Stringifies the whole route.

=head2 C<under>

    my $under = $route->under(sub {...});
    my $under = $route->under('/:foo');

Generate bridges.
See also the L<Mojolicious::Lite> tutorial for more argument variations.
Note that this method is EXPERIMENTAL and might change without warning!

=head2 C<via>

    $r = $r->via('get');
    $r = $r->via(qw/get post/);
    $r = $r->via([qw/get post/]);

Apply C<method> constraint to this route.

=head2 C<waypoint>

    my $route = $r->waypoint('/:c/:a', a => qr/\w+/);

Add a waypoint to this route as nested child.

=head2 C<websocket>

    my $websocket = $route->websocket('/:foo' => sub {...});

Generate route matching only C<WebSocket> handshakes.
See also the L<Mojolicious::Lite> tutorial for more argument variations.
Note that this method is EXPERIMENTAL and might change without warning!

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicious.org>.

=cut
