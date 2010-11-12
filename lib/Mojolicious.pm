package Mojolicious;

use strict;
use warnings;

use base 'Mojo';

use Carp 'croak';
use Mojolicious::Commands;
use Mojolicious::Plugins;
use Mojolicious::Renderer;
use Mojolicious::Routes;
use Mojolicious::Session;
use Mojolicious::Static;
use Mojolicious::Types;

__PACKAGE__->attr(controller_class => 'Mojolicious::Controller');
__PACKAGE__->attr(mode => sub { ($ENV{MOJO_MODE} || 'development') });
__PACKAGE__->attr(plugins  => sub { Mojolicious::Plugins->new });
__PACKAGE__->attr(renderer => sub { Mojolicious::Renderer->new });
__PACKAGE__->attr(routes   => sub { Mojolicious::Routes->new });
__PACKAGE__->attr(
    secret => sub {
        my $self = shift;

        # Warn developers about unsecure default
        $self->log->debug('Your secret passphrase needs to be changed!!!');

        # Application name
        return ref $self;
    }
);
__PACKAGE__->attr(session => sub { Mojolicious::Session->new });
__PACKAGE__->attr(static  => sub { Mojolicious::Static->new });
__PACKAGE__->attr(types   => sub { Mojolicious::Types->new });

our $CODENAME = 'Hot Beverage';
our $VERSION  = '0.999938';

our $AUTOLOAD;

# These old doomsday devices are dangerously unstable.
# I'll rest easier not knowing where they are.
sub AUTOLOAD {
    my $self = shift;

    # Method
    my ($package, $method) = $AUTOLOAD =~ /^([\w\:]+)\:\:(\w+)$/;

    # Helper
    croak qq/Can't locate object method "$method" via "$package"/
      unless my $helper = $self->renderer->helper->{$method};

    # Load controller class
    my $class = $self->controller_class;
    if (my $e = Mojo::Loader->load($class)) {
        $self->log->error(
            ref $e
            ? qq/Can't load controller class "$class": $e/
            : qq/Controller class "$class" doesn't exist./
        );
    }

    # Run
    return $class->new(app => $self)->$helper(@_);
}

sub DESTROY { }

# I personalized each of your meals.
# For example, Amy: you're cute, so I baked you a pony.
sub new {
    my $self = shift->SUPER::new(@_);

    # Transaction builder
    $self->on_build_tx(
        sub {
            my $self = shift;

            # Build
            my $tx = Mojo::Transaction::HTTP->new;

            # Hook
            $self->plugins->run_hook(after_build_tx => ($tx, $self));

            return $tx;
        }
    );

    # Routes
    my $r = $self->routes;

    # Namespace
    $r->namespace(ref $self);

    # Renderer
    my $renderer = $self->renderer;

    # Static
    my $static = $self->static;

    # Home
    my $home = $self->home;

    # Root
    $renderer->root($home->rel_dir('templates'));
    $static->root($home->rel_dir('public'));

    # Hide own controller methods
    $r->hide(qw/AUTOLOAD DESTROY client cookie finish finished flash/);
    $r->hide(qw/handler helper on_message param redirect_to render/);
    $r->hide(qw/render_data render_exception render_inner render_json/);
    $r->hide(qw/render_not_found render_partial render_static render_text/);
    $r->hide(qw/rendered send_message session signed_cookie url_for/);
    $r->hide(qw/write write_chunk/);

    # Mode
    my $mode = $self->mode;

    # Log
    $self->log->path($home->rel_file("log/$mode.log"))
      if -w $home->rel_file('log');

    # Plugins
    $self->plugin('agent_condition');
    $self->plugin('default_helpers');
    $self->plugin('tag_helpers');
    $self->plugin('epl_renderer');
    $self->plugin('ep_renderer');
    $self->plugin('request_timer');
    $self->plugin('powered_by');

    # Reduced log output outside of development mode
    $self->log->level('error') unless $mode eq 'development';

    # Run mode
    $mode = $mode . '_mode';
    $self->$mode(@_) if $self->can($mode);

    # Startup
    $self->startup(@_);

    return $self;
}

# Amy, technology isn't intrinsically good or evil. It's how it's used.
# Like the Death Ray.
sub defaults {
    my $self = shift;

    # Initialize
    $self->{defaults} ||= {};

    # Hash
    return $self->{defaults} unless @_;

    # Get
    return $self->{defaults}->{$_[0]} unless @_ > 1 || ref $_[0];

    # Set
    my $values = ref $_[0] ? $_[0] : {@_};
    for my $key (keys %$values) {
        $self->{defaults}->{$key} = $values->{$key};
    }

    return $self;
}

# The default dispatchers with exception handling
sub dispatch {
    my ($self, $c) = @_;

    # Websocket handshake
    $c->res->code(undef) if $c->tx->is_websocket;

    # Session
    $self->session->load($c);

    # Hook
    $self->plugins->run_hook(before_dispatch => $c);

    # New request
    my $req    = $c->req;
    my $method = $req->method;
    my $path   = $req->url->path || '/';
    my $ua     = $req->headers->user_agent || 'Anonymojo';
    $self->log->debug(qq/$method $path ($ua)./);

    # Try to find a static file
    $self->static->dispatch($c);

    # Hook
    $self->plugins->run_hook_reverse(after_static_dispatch => $c);

    # Routes
    if ($self->routes->dispatch($c)) {

        # Nothing found
        $c->render_not_found unless $c->res->code;
    }
}

# Bite my shiny metal ass!
sub handler {
    my ($self, $tx) = @_;

    # Load controller class
    my $class = $self->controller_class;
    if (my $e = Mojo::Loader->load($class)) {
        $self->log->error(
            ref $e
            ? qq/Can't load controller class "$class": $e/
            : qq/Controller class "$class" doesn't exist./
        );
    }

    # Embedded application
    my $stash = {};
    if ($tx->can('stash')) {
        $stash = $tx->stash;
        $tx    = $tx->tx;
    }

    # Defaults
    my $defaults = $self->defaults;
    $stash = {%$stash, %$defaults};

    # Build default controller and process
    eval {
        $self->process($class->new(app => $self, stash => $stash, tx => $tx));
    };

    # Fatal exception
    if ($@) {
        $self->log->fatal("Processing request failed: $@");
        $tx->res->code(500);
        $tx->resume;
    }
}

sub helper {
    my $self = shift;
    my $name = shift;

    # Renderer
    my $r = $self->renderer;

    # Replace helper
    $self->log->debug(qq/Helper "$name" already exists, replacing./)
      if exists $r->helper->{$name};

    # Add helper
    $r->add_helper($name, @_);
}

sub hook {
    my ($self, $name, $cb) = @_;

    # DEPRECATED in Hot Beverage! (callback wrapper)
    $self->plugins->add_hook($name, sub { shift; $cb->(@_) });
}

sub plugin {
    my $self = shift;
    $self->plugins->register_plugin(shift, $self, @_);
}

# This will run for each request
sub process { shift->dispatch(@_) }

# Start command system
sub start {
    my $class = shift;

    # We can be called on class or instance
    $class = ref $class || $class;

    # We are the application
    $ENV{MOJO_APP} ||= $class;

    # Start!
    return Mojolicious::Commands->start(@_);
}

# This will run once at startup
sub startup { }

1;
__END__

=head1 NAME

Mojolicious - The Web In A Box!

=head1 SYNOPSIS

    # Mojolicious application
    package MyApp;

    use base 'Mojolicious';

    sub startup {
        my $self = shift;

        # Routes
        my $r = $self->routes;

        # Default route
        $r->route('/:controller/:action/:id')->to('foo#welcome');
    }

    # Mojolicious controller
    package MyApp::Foo;

    use base 'Mojolicious::Controller';

    # Say hello
    sub welcome {
        my $self = shift;
        $self->render(text => 'Hi there!');
    }

    # Say goodbye from a template (foo/bye.html.ep)
    sub bye { shift->render }

=head1 DESCRIPTION

Back in the early days of the web there was this wonderful Perl library
called L<CGI>, many people only learned Perl because of it.
It was simple enough to get started without knowing much about the language
and powerful enough to keep you going, learning by doing was much fun.
While most of the techniques used are outdated now, the idea behind it is
not.
L<Mojolicious> is a new attempt at implementing this idea using state of the
art technology.

=head2 Features

=over 4

=item *

An amazing MVC web framework supporting a simplified single file mode through
L<Mojolicious::Lite>.

=over 4

Powerful out of the box with RESTful routes, plugins, Perl-ish templates,
session management, signed cookies, testing framework, static file server,
I18N, first class unicode support and much more for you to discover.

=back

=item *

Very clean, portable and Object Oriented pure Perl API without any hidden
magic and no requirements besides Perl 5.8.7.

=item *

Full stack HTTP 1.1 and WebSocket client/server implementation with IPv6,
TLS, Bonjour, IDNA, Comet (long polling), chunking and multipart support.

=item *

Builtin async IO web server supporting epoll, kqueue, UNIX domain sockets and
hot deployment, perfect for embedding.

=item *

Automatic CGI, FastCGI and L<PSGI> detection.

=item *

JSON and XML/HTML5 parser with CSS3 selector support.

=item *

Fresh code based upon years of experience developing L<Catalyst>.

=back

=head2 Duct Tape For The HTML5 Web

Web development for humans, making hard things possible and everything fun.

    use Mojolicious::Lite;

    get '/hello' => sub { shift->render(text => 'Hello World!') }

    get '/time' => 'clock';

    websocket '/echo' => sub {
        my $self = shift;
        $self->on_message(
            sub {
                my ($self, $message) = @_;
                $self->send_message("echo: $message");
            }
        );
    };

    get '/title' => sub {
        my $self = shift;
        my $url  = $self->param('url');
        $self->render(text =>
              $self->client->get($url)->res->dom->at('title')->text);
    };

    post '/:offset' => sub {
        my $self   = shift;
        my $offset = $self->param('offset') || 23;
        $self->render(json => {list => [0 .. $offset]});
    };

    app->start;
    __DATA__

    @@ clock.html.ep
    % my ($second, $minute, $hour) = (localtime(time))[0, 1, 2];
    <%= link_to clock => begin %>
        The time is <%= $hour %>:<%= $minute %>:<%= $second %>.
    <% end %>

=head2 Have Some Cake

Loosely coupled building blocks, use what you like and just ignore the rest.

    .---------------------------------------------------------------.
    |                                                               |
    |                .----------------------------------------------'
    |                | .--------------------------------------------.
    |   Application  | |              Mojolicious::Lite             |
    |                | '--------------------------------------------'
    |                | .--------------------------------------------.
    |                | |                 Mojolicious                |
    '----------------' '--------------------------------------------'
    .---------------------------------------------------------------.
    |                             Mojo                              |
    '---------------------------------------------------------------'
    .-------. .-----------. .--------. .------------. .-------------.
    |  CGI  | |  FastCGI  | |  PSGI  | |  HTTP 1.1  | |  WebSocket  |
    '-------' '-----------' '--------' '------------' '-------------'

=head2 Highlights

These are some of the most important building blocks of L<Mojolicious>.

=over 4

=item L<Mojolicious::Lite>

Micro Web Framework built on top of L<Mojolicious> for prototypes and small
applications.

=item L<Mojo::Client>

Full featured async io HTTP 1.1 and WebSocket client.

=item L<Mojo::DOM>

Very fun and minimalistic XML/HTML5 DOM parser with CSS3 selector support.

=item L<Mojo::JSON>

Minimalistic JSON implementation that just works.

=item L<Mojo::Server::Daemon>

Full featured async io HTTP 1.1 and WebSocket server.

=item L<Mojo::Server::CGI>, L<Mojo::Server::FastCGI>, L<Mojo::Server::PSGI>

Transparent CGI, FastCGI and PSGI support out of the box.

=item L<Mojo::Template>

Very perlish and minimalistic template system.

=item L<Mojo::ByteStream>

Countless portable and very convenient bytestream manipulation methods.

=item L<Mojolicious::Commands>

Pluggable command line system and the backbone of the C<mojo> script.

=item L<Test::Mojo>

Test driven development toolkit for web applications.

=item L<ojo>

Fun oneliners using everything above.

=back

For more documentation see L<Mojolicious::Guides> and the tutorial in
L<Mojolicious::Lite>!

=head1 ATTRIBUTES

L<Mojolicious> inherits all attributes from L<Mojo> and implements the
following new ones.

=head2 C<controller_class>

    my $class = $app->controller_class;
    $app      = $app->controller_class('Mojolicious::Controller');

Class to be used for the default controller, defaults to
L<Mojolicious::Controller>.

=head2 C<mode>

    my $mode = $app->mode;
    $app     = $app->mode('production');

The operating mode for your application.
It defaults to the value of the environment variable C<MOJO_MODE> or
C<development>.
Mojo will name the log file after the current mode and modes other than
C<development> will result in limited log output.

If you want to add per mode logic to your application, you can add a sub
to your application named C<$mode_mode>.

    sub development_mode {
        my $self = shift;
    }

    sub production_mode {
        my $self = shift;
    }

=head2 C<plugins>

    my $plugins = $app->plugins;
    $app        = $app->plugins(Mojolicious::Plugins->new);

The plugin loader, by default a L<Mojolicious::Plugins> object.
You can usually leave this alone, see L<Mojolicious::Plugin> if you want to
write a plugin.

=head2 C<renderer>

    my $renderer = $app->renderer;
    $app         = $app->renderer(Mojolicious::Renderer->new);

Used in your application to render content, by default a
L<Mojolicious::Renderer> object.
The two main renderer plugins L<Mojolicious::Plugin::EpRenderer> and
L<Mojolicious::Plugin::EplRenderer> contain more specific information.

=head2 C<routes>

    my $routes = $app->routes;
    $app       = $app->routes(Mojolicious::Routes->new);

The routes dispatcher, by default a L<Mojolicious::Routes> object.
You use this in your startup method to define the url endpoints for your
application.

    sub startup {
        my $self = shift;

        my $r = $self->routes;
        $r->route('/:controller/:action')->to('test#welcome');
    }

=head2 C<secret>

    my $secret = $app->secret;
    $app       = $app->secret('passw0rd');

A secret passphrase used for signed cookies and the like, defaults to the
application name which is not very secure, so you should change it!!!
As long as you are using the unsecure default there will be debug messages in
the log file reminding you to change your passphrase.

=head2 C<session>

    my $session = $app->session;
    $app        = $app->session(Mojolicious::Session->new);

Simple singed cookie based sessions, by default a L<Mojolicious::Session>
object.

=head2 C<static>

    my $static = $app->static;
    $app       = $app->static(Mojolicious::Static->new);

For serving static assets from your C<public> directory, by default a
L<Mojolicious::Static> object.

=head2 C<types>

    my $types = $app->types;
    $app      = $app->types(Mojolicious::Types->new);

Responsible for tracking the types of content you want to serve in your
application, by default a L<Mojolicious::Types> object.
You can easily register new types.

    $app->types->type(vti => 'help/vampire');

=head1 METHODS

L<Mojolicious> inherits all methods from L<Mojo> and implements the following
new ones.

=head2 C<new>

    my $app = Mojolicious->new;

Construct a new L<Mojolicious> application.
Will automatically detect your home directory and set up logging based on
your current operating mode.
Also sets up the renderer, static dispatcher and a default set of plugins.

=head2 C<defaults>

    my $defaults = $app->defaults;
    my $foo      = $app->defaults('foo');
    $app         = $app->defaults({foo => 'bar'});
    $app         = $app->defaults(foo => 'bar');

Default values for the stash.
Note that this method is EXPERIMENTAL and might change without warning!

    $app->defaults->{foo} = 'bar';
    my $foo = $app->defaults->{foo};
    delete $app->defaults->{foo};

=head2 C<dispatch>

    $app->dispatch($c);

The heart of every Mojolicious application, calls the static and routes
dispatchers for every request and passes them a L<Mojolicious::Controller>
object.

=head2 C<handler>

    $tx = $app->handler($tx);

Sets up the default controller and calls process for every request.

=head2 C<helper>

    $app->helper(foo => sub { ... });

Add a new helper.
Note that this method is EXPERIMENTAL and might change without warning!

    # Helper
    $app->helper(add => sub { $_[1] + $_[2] });

    # Controller/Application
    my $result = $self->add(2, 3);

    # Template
    <%= add 2, 3 %>

=head2 C<hook>

    $app->hook(after_dispatch => sub { ... });

Add hooks to named events.
Note that this method is EXPERIMENTAL and might change without warning!

The following events are available and run in the listed order.

=over 4

=item after_build_tx

Triggered right after the transaction is built and before the HTTP request
gets parsed.
One use case would be upload progress bars.
(Passed the transaction and application instances)

    $app->hook(before_request => sub {
        my ($tx, $app) = @_;
    });

=item before_dispatch

Triggered right before the static and routes dispatchers start their work.
(Passed the default controller instance)

    $app->hook(before_dispatch => sub {
        my $self = shift;
    });

=item after_static_dispatch

Triggered after the static dispatcher determined if a static file should be
served and before the routes dispatcher starts its work, the callbacks of
this hook run in reverse order.
(Passed the default controller instance)

    $app->hook(after_static_dispatch => sub {
        my $self = shift;
    });

=item after_dispatch

Triggered after the static and routes dispatchers are finished and a response
has been rendered, the callbacks of this hook run in reverse order.
(Passed the current controller instance)

    $app->hook(after_dispatch => sub {
        my $self = shift;
    });

=back

=head2 C<plugin>

    $app->plugin('something');
    $app->plugin('something', foo => 23);
    $app->plugin('something', {foo => 23});
    $app->plugin('Foo::Bar');
    $app->plugin('Foo::Bar', foo => 23);
    $app->plugin('Foo::Bar', {foo => 23});

Load a plugin.
Note that this method is EXPERIMENTAL and might change without warning!

=head2 C<process>

    $app->process($c);

This method can be overloaded to do logic on a per request basis, by default
just calls dispatch and passes it a L<Mojolicious::Controller> object.
Generally you will use a plugin or controller instead of this, consider it
the sledgehammer in your toolbox.

    sub process {
        my ($self, $c) = @_;
        $self->dispatch($c);
    }

=head2 C<start>

    Mojolicious->start;
    Mojolicious->start('daemon');

Start the L<Mojolicious::Commands> command line interface for your
application.

=head2 C<startup>

    $app->startup;

This is your main hook into the application, it will be called at application
startup.

    sub startup {
        my $self = shift;
    }

=head1 SUPPORT

=head2 Web

    http://mojolicious.org

=head2 IRC

    #mojo on irc.perl.org

=head2 Mailing-List

    http://groups.google.com/group/mojolicious

=head1 DEVELOPMENT

=head2 Repository

    http://github.com/kraih/mojo

=head1 CODE NAMES

Every major release of L<Mojolicious> has a code name, these are the ones
that have been used in the past.

0.999930, C<Hot Beverage> (u2615)

0.999927, C<Comet> (u2604)

0.999920, C<Snowman> (u2603)

=head1 AUTHOR

Sebastian Riedel, C<sri@cpan.org>.

=head1 CORE DEVELOPERS EMERITUS

Retired members of the core team, we thank you dearly for your service.

=over 4

Viacheslav Tykhanovskyi, C<vti@cpan.org>.

=back

=head1 CREDITS

In alphabetical order.

=over 4

Adam Kennedy

Adriano Ferreira

Alex Salimon

Alexey Likhatskiy

Anatoly Sharifulin

Andre Vieth

Andrew Fresh

Andreas Koenig

Andy Grundman

Aristotle Pagaltzis

Ashley Dev

Ask Bjoern Hansen

Audrey Tang

Breno G. de Oliveira

Burak Gursoy

Ch Lamprecht

Chas. J. Owens IV

Christian Hansen

Curt Tilmes

Danijel Tasov

David Davis

Dmitriy Shalashov

Dmitry Konstantinov

Eugene Toropov

Gisle Aas

Glen Hinkle

Graham Barr

Hideki Yamamura

James Duncan

Jan Jona Javorsek

Jaroslav Muhin

Jesse Vincent

John Kingsley

Jonathan Yu

Kazuhiro Shibuya

Kevin Old

Lars Balker Rasmussen

Leon Brocard

Maik Fischer

Marcus Ramberg

Mark Stosberg

Matthew Lineen

Maksym Komar

Maxim Vuets

Mirko Westermeier

Mons Anderson

Oleg Zhelo

Pascal Gaudette

Paul Tomlin

Pedro Melo

Peter Edwards

Pierre-Yves Ritschard

Quentin Carbonneaux

Rafal Pocztarski

Randal Schwartz

Robert Hicks

Ryan Jendoubi

Sascha Kiefer

Sergey Zasenko

Simon Bertrang

Shu Cho

Stanis Trendelenburg

Tatsuhiko Miyagawa

The Perl Foundation

Tomas Znamenacek

Ulrich Habel

Ulrich Kautz

Uwe Voelker

Yaroslav Korshak

Yuki Kimoto

Zak B. Elep

=back

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2008-2010, Sebastian Riedel.

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=cut
