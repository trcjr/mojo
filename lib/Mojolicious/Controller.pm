package Mojolicious::Controller;

use strict;
use warnings;

use base 'Mojo::Base';

use Mojo::ByteStream;
use Mojo::Command;
use Mojo::Cookie::Response;
use Mojo::Exception;
use Mojo::Transaction::HTTP;
use Mojo::URL;
use Mojo::Util;

require Carp;

# Scalpel... blood bucket... priest.
__PACKAGE__->attr([qw/app match/]);
__PACKAGE__->attr(tx => sub { Mojo::Transaction::HTTP->new });

# Exception template
our $EXCEPTION =
  Mojo::Command->new->get_data('exception.html.ep', __PACKAGE__);

# Not found template
our $NOT_FOUND =
  Mojo::Command->new->get_data('not_found.html.ep', __PACKAGE__);

# Reserved stash values
my $STASH_RE = qr/
    ^
    (?:
    action
    |
    app
    |
    cb
    |
    class
    |
    controller
    |
    data
    |
    exception
    |
    extends
    |
    format
    |
    handler
    |
    json
    |
    layout
    |
    method
    |
    namespace
    |
    partial
    |
    path
    |
    status
    |
    template
    |
    text
    )
    $
    /x;

# Is all the work done by the children?
# No, not the whipping.
sub AUTOLOAD {
    my $self = shift;

    # Method
    my ($package, $method) = our $AUTOLOAD =~ /^([\w\:]+)\:\:(\w+)$/;

    # Helper
    Carp::croak(qq/Can't locate object method "$method" via "$package"/)
      unless my $helper = $self->app->renderer->helper->{$method};

    # Run
    return $self->$helper(@_);
}

sub DESTROY { }

sub client { shift->app->client }

# For the last time, I don't like lilacs!
# Your first wife was the one who liked lilacs!
# She also liked to shut up!
sub cookie {
    my ($self, $name, $value, $options) = @_;

    # Shortcut
    return unless $name;

    # Response cookie
    if (defined $value) {

        # Cookie too big
        $self->app->log->error(qq/Cookie "$name" is bigger than 4096 bytes./)
          if length $value > 4096;

        # Create new cookie
        $options ||= {};
        my $cookie = Mojo::Cookie::Response->new(
            name  => $name,
            value => $value,
            %$options
        );
        $self->res->cookies($cookie);
        return $self;
    }

    # Request cookie
    unless (wantarray) {
        return unless my $cookie = $self->req->cookie($name);
        return $cookie->value;
    }

    # Request cookies
    my @cookies = $self->req->cookie($name);
    return map { $_->value } @cookies;
}

# Something's wrong, she's not responding to my poking stick.
sub finish {
    my $self = shift;

    # Transaction
    my $tx = $self->tx;

    # WebSocket check
    Carp::croak('No WebSocket connection to finish') unless $tx->is_websocket;

    # Finish WebSocket
    $tx->finish;
}

# You two make me ashamed to call myself an idiot.
sub flash {
    my $self = shift;

    # Get
    my $session = $self->stash->{'mojo.session'};
    if ($_[0] && !defined $_[1] && !ref $_[0]) {
        return unless $session && ref $session eq 'HASH';
        return unless my $flash = $session->{flash};
        return unless ref $flash eq 'HASH';
        return $flash->{$_[0]};
    }

    # Initialize
    $session = $self->session;
    my $flash = $session->{new_flash};
    $flash = {} unless $flash && ref $flash eq 'HASH';
    $session->{new_flash} = $flash;

    # Hash
    return $flash unless @_;

    # Set
    my $values = exists $_[1] ? {@_} : $_[0];
    $session->{new_flash} = {%$flash, %$values};

    return $self;
}

# My parents may be evil, but at least they're stupid.
sub on_finish {
    my ($self, $cb) = @_;

    # Transaction finished
    $self->tx->on_finish(sub { shift and $self->$cb(@_) });
}

# Stop being such a spineless jellyfish!
# You know full well I'm more closely related to the sea cucumber.
# Not where it counts.
sub on_message {
    my $self = shift;

    # Transaction
    my $tx = $self->tx;

    # WebSocket check
    Carp::croak('No WebSocket connection to receive messages from')
      unless $tx->is_websocket;

    # Callback
    my $cb = shift;

    # Receive
    $tx->on_message(sub { shift and $self->$cb(@_) });

    # Rendered
    $self->rendered;

    return $self;
}

# Just make a simple cake. And this time, if someone's going to jump out of
# it make sure to put them in *after* you cook it.
sub param {
    my $self = shift;
    my $name = shift;

    # Captures
    my $p = $self->stash->{'mojo.captures'} || {};

    # List
    unless (defined $name) {
        my %seen;
        return sort grep { !$seen{$_}++ } keys %$p, $self->req->param;
    }

    # Override value
    if (@_) {
        $p->{$name} = $_[0];
        return $self;
    }

    # Captured value
    return $p->{$name} if exists $p->{$name};

    # Param value
    return $self->req->param($name);
}

# Is there an app for kissing my shiny metal ass?
# Several!
# Oooh!
sub redirect_to {
    my $self = shift;

    # Response
    my $res = $self->res;

    # Code
    $res->code(302);

    # Headers
    my $headers = $res->headers;
    $headers->location($self->url_for(@_)->to_abs);
    $headers->content_length(0);

    # Rendered
    $self->rendered;

    return $self;
}

# Mamma Mia! The cruel meatball of war has rolled onto our laps and ruined
# our white pants of peace!
sub render {
    my $self = shift;

    # Template as single argument
    my $stash = $self->stash;
    my $template;
    $template = shift if @_ % 2 && !ref $_[0];

    # Arguments
    my $args = ref $_[0] ? $_[0] : {@_};

    # Template
    $args->{template} = $template if $template;
    unless ($stash->{template} || $args->{template}) {

        # Default template
        my $controller = $args->{controller} || $stash->{controller};
        my $action     = $args->{action}     || $stash->{action};

        # Normal default template
        if ($controller && $action) {
            $self->stash->{template} =
              join('/', split(/-/, $controller), $action);
        }

        # Try the route name if we don't have controller and action
        elsif ($self->match && $self->match->endpoint) {
            $self->stash->{template} = $self->match->endpoint->name;
        }
    }

    # Render
    my ($output, $type) = $self->app->renderer->render($self, $args);

    # Failed
    return unless defined $output;

    # Partial
    return $output if $args->{partial};

    # Response
    my $res = $self->res;

    # Status
    $res->code($stash->{status}) if $stash->{status};
    $res->code(200) unless $res->code;

    # Output
    $res->body($output) unless $res->body;

    # Type
    my $headers = $res->headers;
    $headers->content_type($type) unless $headers->content_type;

    # Rendered
    $self->rendered;

    # Success
    return 1;
}

sub render_data {
    my $self = shift;
    my $data = shift;

    # Arguments
    my $args = ref $_[0] ? $_[0] : {@_};

    # Data
    $args->{data} = $data;

    return $self->render($args);
}

# The path to robot hell is paved with human flesh.
# Neat.
sub render_exception {
    my ($self, $e) = @_;

    # Exception
    $e = Mojo::Exception->new($e);

    # Error
    $self->app->log->error($e);

    # Recursion
    return if $self->stash->{'mojo.exception'};

    # Request
    my $s     = {};
    my $stash = $self->stash;
    for my $key (keys %$stash) {
        next if $key =~ /^mojo\./;
        next unless defined(my $value = $stash->{$key});
        $s->{$key} = $value;
    }
    my $req = $self->req;
    my $url = $req->url;
    my @r   = (
        Method     => $req->method,
        Path       => $url->to_string,
        Base       => $url->base->to_string,
        Parameters => $self->dumper($req->params->to_hash),
        Stash      => $self->dumper($s),
        Session    => $self->dumper($self->session),
        Version    => $req->version
    );

    # Info
    my @i = (
        Perl        => "$] ($^O)",
        Mojolicious => "$Mojolicious::VERSION ($Mojolicious::CODENAME)",
        Home        => $self->app->home,
        Include     => $self->dumper(\@INC),
        PID         => $$,
        Name        => $0,
        Executable  => $^X,
        Time        => scalar localtime(time)
    );


    # Exception template
    my $options = {
        template         => 'exception',
        format           => 'html',
        handler          => undef,
        status           => 500,
        layout           => undef,
        extends          => undef,
        request          => \@r,
        info             => \@i,
        exception        => $e,
        'mojo.exception' => 1
    };

    # Inline template
    unless ($self->render($options)) {
        $self->render(
            inline           => $EXCEPTION,
            format           => 'html',
            handler          => 'ep',
            status           => 500,
            layout           => undef,
            extends          => undef,
            request          => \@r,
            info             => \@i,
            exception        => $e,
            'mojo.exception' => 1
        );
    }

    # Rendered
    $self->rendered;
}

sub render_inner {
    my $self    = shift;
    my $name    = shift;
    my $content = pop;

    # Initialize
    my $stash = $self->stash;
    my $c = $stash->{'mojo.content'} ||= {};
    $name ||= 'content';

    # Set
    if (defined $content) {

        # Reset with multiple values
        if (@_) {
            $c->{$name} = '';
            for my $part (@_, $content) {
                $c->{$name} .= ref $part eq 'CODE' ? $part->() : $part;
            }
        }

        # First come
        else {
            $c->{$name} ||= ref $content eq 'CODE' ? $content->() : $content;
        }
    }

    # Get
    $content = $c->{$name};
    $content = '' unless defined $content;
    return Mojo::ByteStream->new("$content");
}

# If you hate intolerance and being punched in the face by me,
# please support Proposition Infinity.
sub render_json {
    my $self = shift;
    my $json = shift;

    # Arguments
    my $args = ref $_[0] ? $_[0] : {@_};

    # JSON
    $args->{json} = $json;

    return $self->render($args);
}

# Excuse me, sir, you're snowboarding off the trail.
# Lick my frozen metal ass.
sub render_not_found {
    my ($self, $resource) = @_;

    # Debug
    $self->app->log->debug(qq/Resource "$resource" not found./)
      if $resource;

    # Stash
    my $stash = $self->stash;

    # Exception
    return if $stash->{'mojo.exception'};

    # Recursion
    return if $stash->{'mojo.not_found'};

    # Check for POD plugin
    my $guide =
        $self->app->renderer->helpers->{pod_to_html}
      ? $self->url_for('/perldoc')
      : 'http://mojolicio.us/perldoc';


    # Render not found template
    my $options = {
        template         => 'not_found',
        format           => 'html',
        status           => 404,
        layout           => undef,
        extends          => undef,
        guide            => $guide,
        'mojo.not_found' => 1
    };

    # Inline template
    unless ($self->render($options)) {
        $self->render(
            inline           => $NOT_FOUND,
            format           => 'html',
            handler          => 'ep',
            status           => 404,
            layout           => undef,
            extends          => undef,
            guide            => $guide,
            'mojo.not_found' => 1
        );
    }

    # Rendered
    $self->rendered;
}

# You called my thesis a fat sack of barf, and then you stole it?
# Welcome to academia.
sub render_partial {
    my $self = shift;

    # Template as single argument
    my $template;
    $template = shift if (@_ % 2 && !ref $_[0]) || (!@_ % 2 && ref $_[1]);

    # Arguments
    my $args = ref $_[0] ? $_[0] : {@_};

    # Template
    $args->{template} = $template if $template;

    # Partial
    $args->{partial} = 1;

    return Mojo::ByteStream->new($self->render($args));
}

sub render_static {
    my ($self, $file) = @_;

    # Application
    my $app = $self->app;

    # Static
    $app->static->serve($self, $file)
      and $app->log->debug(
        qq/Static file "$file" not found, public directory missing?/);

    # Rendered
    $self->rendered;
}

sub render_text {
    my $self = shift;
    my $text = shift;

    # Arguments
    my $args = ref $_[0] ? $_[0] : {@_};

    # Data
    $args->{text} = $text;

    return $self->render($args);
}

# On the count of three, you will awaken feeling refreshed,
# as if Futurama had never been canceled by idiots,
# then brought back by bigger idiots. One. Two.
sub rendered {
    my $self = shift;

    # Resume
    $self->tx->resume;

    # Rendered
    $self->stash->{'mojo.rendered'} = 1;

    # Stash
    my $stash = $self->stash;

    # Already finished
    return $self if $stash->{'mojo.finished'};

    # Application
    my $app = $self->app;

    # Hook
    $app->plugins->run_hook_reverse(after_dispatch => $self);

    # Session
    $app->sessions->store($self);

    # Finished
    $stash->{'mojo.finished'} = 1;

    return $self;
}

sub req { shift->tx->req }
sub res { shift->tx->res }

sub send_message {
    my $self = shift;

    # Transaction
    my $tx = $self->tx;

    # WebSocket check
    Carp::croak('No WebSocket connection to send message to')
      unless $tx->is_websocket;

    # Send
    $tx->send_message(@_);

    # Rendered
    $self->rendered;

    return $self;
}

# Why am I sticky and naked? Did I miss something fun?
sub session {
    my $self = shift;

    # Get
    my $stash   = $self->stash;
    my $session = $stash->{'mojo.session'};
    if ($_[0] && !defined $_[1] && !ref $_[0]) {
        return unless $session && ref $session eq 'HASH';
        return $session->{$_[0]};
    }

    # Initialize
    $session = {} unless $session && ref $session eq 'HASH';
    $stash->{'mojo.session'} = $session;

    # Hash
    return $session unless @_;

    # Set
    my $values = exists $_[1] ? {@_} : $_[0];
    $stash->{'mojo.session'} = {%$session, %$values};

    return $self;
}

sub signed_cookie {
    my ($self, $name, $value, $options) = @_;

    # Shortcut
    return unless $name;

    # Secret
    my $secret = $self->app->secret;

    # Response cookie
    if (defined $value) {

        # Sign value
        my $signature = Mojo::Util::hmac_md5_sum $value, $secret;
        $value = $value .= "--$signature";

        # Create cookie
        my $cookie = $self->cookie($name, $value, $options);
        return $cookie;
    }

    # Request cookies
    my @values = $self->cookie($name);
    my @results;
    for my $value (@values) {

        # Check signature
        if ($value =~ s/\-\-([^\-]+)$//) {
            my $signature = $1;
            my $check = Mojo::Util::hmac_md5_sum $value, $secret;

            # Verified
            if ($signature eq $check) { push @results, $value }

            # Bad cookie
            else {
                $self->app->log->debug(
                    qq/Bad signed cookie "$name", possible hacking attempt./);
            }
        }

        # Not signed
        else { $self->app->log->debug(qq/Cookie "$name" not signed./) }
    }

    return wantarray ? @results : $results[0];
}

# All this knowledge is giving me a raging brainer.
sub stash {
    my $self = shift;

    # Initialize
    $self->{stash} ||= {};

    # Hash
    return $self->{stash} unless @_;

    # Get
    return $self->{stash}->{$_[0]} unless @_ > 1 || ref $_[0];

    # Set
    my $values = ref $_[0] ? $_[0] : {@_};
    for my $key (keys %$values) {
        $self->app->log->debug(qq/Careful, "$key" is a reserved stash value./)
          if $key =~ $STASH_RE;
        $self->{stash}->{$key} = $values->{$key};
    }

    return $self;
}

# Behold, a time traveling machine.
# Time? I can't go back there!
# Ah, but this machine only goes forward in time.
# That way you can't accidentally change history or do something disgusting
# like sleep with your own grandmother.
# I wouldn't want to do that again.
sub url_for {
    my $self = shift;
    my $target = shift || '';

    # Make sure we have a match for named routes
    $self->match(
        Mojolicious::Routes::Match->new($self)->root($self->app->routes))
      unless $self->match;

    # URL
    if ($target =~ /^\w+\:\/\//) { return Mojo::URL->new($target) }

    # Route
    elsif (my $url = $self->match->url_for($target, @_)) { return $url }

    # Path
    return Mojo::URL->new->base($self->req->url->base->clone)->parse($target);
}

# I wax my rocket every day!
sub write {
    my ($self, $chunk, $cb) = @_;

    # Callback only
    if (ref $chunk && ref $chunk eq 'CODE') {
        $cb    = $chunk;
        $chunk = undef;
    }

    # Write
    $self->res->write(
        $chunk,
        sub {

            # Cleanup
            shift;

            # Callback
            $self->$cb(@_) if $cb;
        }
    );

    # Rendered
    $self->rendered;
}

sub write_chunk {
    my ($self, $chunk, $cb) = @_;

    # Callback only
    if (ref $chunk && ref $chunk eq 'CODE') {
        $cb    = $chunk;
        $chunk = undef;
    }

    # Write
    $self->res->write_chunk(
        $chunk,
        sub {

            # Cleanup
            shift;

            # Callback
            $self->$cb(@_) if $cb;
        }
    );

    # Rendered
    $self->rendered;
}

1;
__DATA__

@@ exception.html.ep
% my $e = delete $self->stash->{'exception'};
<!doctype html><html>
    <head>
        <title>Exception</title>
        <meta http-equiv="Pragma" content="no-cache">
        <meta http-equiv="Expires" content="-1">
        %= base_tag
        %= javascript 'js/jquery.js'
        %= stylesheet 'css/prettify-mojo.css'
        %= javascript 'js/prettify.js'
        %= stylesheet begin
            a img { border: 0; }
            body {
                background-color: #f5f6f8;
                color: #333;
                font: 0.9em Verdana, sans-serif;
                margin-left: 3em;
                margin-right: 3em;
                margin-top: 0;
                text-shadow: #ddd 0 1px 0;
            }
            h1 {
                font: 1.5em Georgia, Times, serif;
                margin: 0;
                text-shadow: #333 0 1px 0;
            }
            pre {
                margin: 0;
                white-space: pre-wrap;
            }
            table {
                border-collapse: collapse;
                margin-top: 1em;
                margin-bottom: 1em;
                width: 100%;
            }
            td { padding: 0.3em; }
            .box {
                background-color: #fff;
                -moz-box-shadow: 0px 0px 2px #ccc;
                -webkit-box-shadow: 0px 0px 2px #ccc;
                box-shadow: 0px 0px 2px #ccc;
                overflow: hidden;
                padding: 1em;
            }
            .code {
                background-color: #1a1a1a;
                background: url("mojolicious-pinstripe.gif") fixed;
                color: #eee;
                font-family: 'Menlo', 'Monaco', Courier, monospace !important;
                text-shadow: #333 0 1px 0;
            }
            .file {
                margin-bottom: 0.5em;
                margin-top: 1em;
            }
            .important { background-color: rgba(47, 48, 50, .75); }
            .infobox tr:nth-child(odd) .value { background-color: #ddeeff; }
            .infobox tr:nth-child(even) .value { background-color: #eef9ff; }
            .key {
                text-align: right;
                text-weight: bold;
            }
            .preview {
                background-color: #1a1a1a;
                background: url("mojolicious-pinstripe.gif") fixed;
                -moz-border-radius: 5px;
                border-radius: 5px;
                margin-bottom: 1em;
                padding: 0.5em;
            }
            .tap {
                font: 0.5em Verdana, sans-serif;
                text-align: center;
            }
            .value {
                padding-left: 1em;
                width: 100%;
            }
            #footer {
                margin-top: 1.5em;
                text-align: center;
                width: 100%;
            }
            #showcase {
                margin-top: 1em;
                -moz-border-radius-topleft: 5px;
                border-top-left-radius: 5px;
                -moz-border-radius-topright: 5px;
                border-top-right-radius: 5px;
            }
            #more, #trace {
                -moz-border-radius-bottomleft: 5px;
                border-bottom-left-radius: 5px;
                -moz-border-radius-bottomright: 5px;
                border-bottom-right-radius: 5px;
            }
            #request {
                -moz-border-radius-topleft: 5px;
                border-top-left-radius: 5px;
                -moz-border-radius-topright: 5px;
                border-top-right-radius: 5px;
                margin-top: 1em;
            }
        % end
    </head>
    <body onload="prettyPrint()">
        % if ($self->app->mode eq 'development') {
            % my $code = begin
                <code class="prettyprint"><%= shift %></code>
            % end
            % my $cv = begin
                % my ($key, $value, $i) = @_;
                %= tag 'tr', $i ? (class => 'important') : undef, begin
                    <td class="key"><%= $key %>.</td>
                    <td class="value">
                       %== $code->($value)
                    </td>
                % end
            % end
            % my $kv = begin
                % my ($key, $value) = @_;
                <tr>
                    <td class="key"><%= $key %>:</td>
                    <td class="value">
                        <pre><%= $value %></pre>
                    </td>
                </tr>
            % end
            <div id="showcase" class="code box">
                <h1><%= $e->message %></h1>
                <div id="context">
                    <table>
                        % for my $line (@{$e->lines_before}) {
                            %== $cv->($line->[0], $line->[1])
                        % }
                        % if (defined $e->line->[1]) {
                            %== $cv->($e->line->[0], $e->line->[1], 1)
                        % }
                        % for my $line (@{$e->lines_after}) {
                            %== $cv->($line->[0], $line->[1])
                        % }
                    </table>
                </div>
                % if (defined $e->line->[2]) {
                    <div id="insight">
                        <table>
                            % for my $line (@{$e->lines_before}) {
                                %== $cv->($line->[0], $line->[2])
                            % }
                            %== $cv->($e->line->[0], $e->line->[2], 1)
                            % for my $line (@{$e->lines_after}) {
                                %== $cv->($line->[0], $line->[2])
                            % }
                        </table>
                    </div>
                    <div class="tap">tap for more</div>
                    %= javascript begin
                        var current = '#context';
                        $('#showcase').click(function() {
                            $(current).slideToggle('slow', function() {
                                if (current == '#context') {
                                    current = '#insight';
                                }
                                else {
                                    current = '#context';
                                }
                                $(current).slideToggle('slow');
                            });
                        });
                        $('#insight').toggle();
                    % end
                % }
            </div>
            <div class="box" id="trace">
                % if (@{$e->frames}) {
                    <div id="frames">
                        % for my $frame (@{$e->frames}) {
                            % if (my $line = $frame->[3]) {
                                <div class="file"><%= $frame->[1] %></div>
                                <div class="code preview">
                                    %= "$frame->[2]."
                                    %== $code->($line)
                                </div>
                            % }
                        % }
                    </div>
                    <div class="tap">tap for more</div>
                    %= javascript begin
                        $('#trace').click(function() {
                            $('#frames').slideToggle('slow');
                        });
                        $('#frames').toggle();
                    % end
                % }
            </div>
            <div class="box infobox" id="request">
                <table>
                    % for (my $i = 0; $i < @$request; $i += 2) {
                        % my $key = $request->[$i];
                        % my $value = $request->[$i + 1];
                        %== $kv->($key, $value)
                    % }
                    % for my $name (@{$self->req->headers->names}) {
                        % my $value = $self->req->headers->header($name);
                        %== $kv->($name, $value)
                    % }
                </table>
            </div>
            <div class="box infobox" id="more">
                <div id="infos">
                    <table>
                        % for (my $i = 0; $i < @$info; $i += 2) {
                            %== $kv->($info->[$i], $info->[$i + 1])
                        % }
                    </table>
                </div>
                <div class="tap">tap for more</div>
            </div>
            <div id="footer">
                %= link_to 'http://mojolicio.us' => begin
                    <img src="mojolicious-black.png" alt="Mojolicious logo">
                % end
            </div>
            %= javascript begin
                $('#more').click(function() {
                    $('#infos').slideToggle('slow');
                });
                $('#infos').toggle();
            % end
        % } else {
            Page temporarily unavailable, please come back later.
        % }
    </body>
</html>

@@ not_found.html.ep
<!doctype html><html>
    <head>
        <title>Not Found</title>
        %= base_tag
        %= stylesheet 'css/prettify-mojo.css'
        %= javascript 'js/prettify.js'
        %= stylesheet begin
            a {
                color: inherit;
                text-decoration: none;
            }
            a img { border: 0; }
            body {
                background-color: #f5f6f8;
                color: #333;
                font: 0.9em Verdana, sans-serif;
                margin: 0;
                text-align: center;
                text-shadow: #ddd 0 1px 0;
            }
            h1 {
                font: 1.5em Georgia, Times, serif;
                margin-bottom: 1em;
                margin-top: 1em;
                text-shadow: #666 0 1px 0;
            }
            #footer {
                background-color: #caecf6;
                padding-top: 20em;
                width: 100%;
            }
            #footer a img { margin-top: 20em; }
            #documentation {
                background-color: #ecf1da;
                padding-bottom: 20em;
                padding-top: 20em;
            }
            #documentation h1 { margin-bottom: 3em; }
            #header {
                margin-bottom: 20em;
                margin-top: 15em;
                width: 100%;
            }
            #perldoc {
                background-color: #eee;
                border: 2px dashed #1a1a1a;
                color: #000;
                display: inline-block;
                margin-left: 0.1em;
                padding: 0.5em;
                white-space: nowrap;
            }
            #preview {
                background-color: #1a1a1a;
                background: url("mojolicious-pinstripe.gif") fixed;
                -moz-border-radius: 5px;
                border-radius: 5px;
                font-family: 'Menlo', 'Monaco', Courier, monospace !important;
                font-size: 1.5em;
                margin: 0;
                margin-left: auto;
                margin-right: auto;
                padding: 0.5em;
                padding-left: 1em;
                text-align: left;
                width: 500px;
            }
            #suggestion {
                background-color: #2f3032;
                color: #eee;
                padding-bottom: 20em;
                padding-top: 20em;
                text-shadow: #333 0 1px 0;
            }
        % end
    </head>
    <body onload="prettyPrint()">
        % if ($self->app->mode eq 'development') {
            <div id="header">
                <img src="mojolicious-box.png" alt="Mojolicious banner">
                <h1>This page is brand new and has not been unboxed yet!</h1>
            </div>
            <div id="suggestion">
                <img src="mojolicious-arrow.png" alt="Arrow">
                <h1>Perhaps you would like to add a route for it?</h1>
                <div id="preview">
                    <pre class="prettyprint">
get '/<%= $self->req->url->path %>' => sub {
    my $self = shift;
    $self->render(text => 'Hello world!');
};</pre>
                </div>
            </div>
            <div id="documentation">
                <h1>
                    You might also enjoy our excellent documentation in
                    <div id="perldoc">
                        <%= link_to 'perldoc Mojolicious::Guides', $guide %>
                    </div>
                </h1>
                <img src="amelia.png" alt="Amelia">
            </div>
            <div id="footer">
                <h1>And don't forget to have fun!</h1>
                <p><img src="mojolicious-clouds.png" alt="Clouds"></p>
                %= link_to 'http://mojolicio.us' => begin
                    <img src="mojolicious-black.png" alt="Mojolicious logo">
                % end
            </div>
        % } else {
            Page not found, want to go <%= link_to home => url_for->base %>?
        % }
    </body>
</html>

__END__

=head1 NAME

Mojolicious::Controller - Controller Base Class

=head1 SYNOPSIS

    use base 'Mojolicious::Controller';

=head1 DESCRIPTION

L<Mojolicous::Controller> is the base class for your L<Mojolicious>
controllers.
It is also the default controller class for L<Mojolicious> unless you set
C<controller_class> in your application.

=head1 ATTRIBUTES

L<Mojolicious::Controller> inherits all attributes from L<Mojo::Base> and
implements the following new ones.

=head2 C<app>

    my $app = $c->app;
    $c      = $c->app(Mojolicious->new);

A reference back to the application that dispatched to this controller.

=head2 C<match>

    my $m = $c->match;

A L<Mojolicious::Routes::Match> object containing the routes results for the
current request.

=head2 C<tx>

    my $tx = $c->tx;

The transaction that is currently being processed, defaults to a
L<Mojo::Transaction::HTTP> object.

=head1 METHODS

L<Mojolicious::Controller> inherits all methods from L<Mojo::Base> and
implements the following new ones.

=head2 C<client>

    my $client = $c->client;
    
A L<Mojo::Client> prepared for the current environment.

    my $tx = $c->client->get('http://mojolicio.us');

    $c->client->post_form('http://kraih.com/login' => {user => 'mojo'});

    $c->client->get('http://mojolicio.us' => sub {
        my $client = shift;
        $c->render_data($client->res->body);
    })->start;

Some environments such as L<Mojo::Server::Daemon> even allow async requests.

    $c->client->async->get('http://mojolicio.us' => sub {
        my $client = shift;
        $c->render_data($client->res->body);
    })->start;

=head2 C<cookie>

    $c         = $c->cookie(foo => 'bar');
    $c         = $c->cookie(foo => 'bar', {path => '/'});
    my $value  = $c->cookie('foo');
    my @values = $c->cookie('foo');

Access request cookie values and create new response cookies.

=head2 C<finish>

    $c->finish;

Gracefully end WebSocket connection.

=head2 C<flash>

    my $flash = $c->flash;
    my $foo   = $c->flash('foo');
    $c        = $c->flash({foo => 'bar'});
    $c        = $c->flash(foo => 'bar');

Data storage persistent for the next request, stored in the session.

    $c->flash->{foo} = 'bar';
    my $foo = $c->flash->{foo};
    delete $c->flash->{foo};

=head2 C<on_finish>

    $c->on_finish(sub {...});

Callback signaling that the transaction has been finished.

    $c->on_finish(sub {
        my $self = shift;
    });

=head2 C<on_message>

    $c = $c->on_message(sub {...});

Receive messages via WebSocket, only works if there is currently a WebSocket
connection in progress.

    $c->on_message(sub {
        my ($self, $message) = @_;
    });

=head2 C<param>

    my @names = $c->param;
    my $foo   = $c->param('foo');
    my @foo   = $c->param('foo');
    $c        = $c->param(foo => 'ba;r');

Request parameters and routes captures.

=head2 C<redirect_to>

    $c = $c->redirect_to('named');
    $c = $c->redirect_to('named', foo => 'bar');
    $c = $c->redirect_to('/path');
    $c = $c->redirect_to('http://127.0.0.1/foo/bar');

Prepare a C<302> redirect response.

=head2 C<render>

    $c->render;
    $c->render(controller => 'foo', action => 'bar');
    $c->render({controller => 'foo', action => 'bar'});
    $c->render(text => 'Hello!');
    $c->render(template => 'index');
    $c->render(template => 'foo/index');
    $c->render(template => 'index', format => 'html', handler => 'epl');
    $c->render(handler => 'something');
    $c->render('foo/bar');
    $c->render('foo/bar', format => 'html');

This is a wrapper around L<Mojolicious::Renderer> exposing pretty much all
functionality provided by it.
It will set a default template to use based on the controller and action name
or fall back to the route name.
You can call it with a hash of options which can be preceded by an optional
template name.
Note that all render arguments get localized, so stash values won't be
changed after the render call.

=head2 C<render_data>

    $c->render_data($bits);

Render binary data, similar to C<render_text> but data will not be encoded.

=head2 C<render_exception>

    $c->render_exception('Oops!');
    $c->render_exception(Mojo::Exception->new('Oops!'));

Render the exception template C<exception.html.$handler> and set the response
status code to C<500>.

=head2 C<render_inner>

    my $output = $c->render_inner;
    my $output = $c->render_inner('content');
    my $output = $c->render_inner(content => 'Hello world!');
    my $output = $c->render_inner(content => sub { 'Hello world!' });

Contains partial rendered templates, used for the renderers C<layout> and
C<extends> features.

=head2 C<render_json>

    $c->render_json({foo => 'bar'});
    $c->render_json([1, 2, -3]);

Render a data structure as JSON.

=head2 C<render_not_found>

    $c->render_not_found;
    $c->render_not_found($resource);
    
Render the not found template C<not_found.html.$handler> and set the response
status code to C<404>.

=head2 C<render_partial>

    my $output = $c->render_partial;
    my $output = $c->render_partial(action => 'foo');
    
Same as C<render> but returns the rendered result.

=head2 C<render_static>

    $c->render_static('images/logo.png');
    $c->render_static('../lib/MyApp.pm');

Render a static file using L<Mojolicious::Static> relative to the
C<public> directory of your application.

=head2 C<render_text>

    $c->render_text('Hello World!');
    $c->render_text('Hello World', layout => 'green');

Render the given content as plain text, note that text will be encoded.
See C<render_data> for an alternative without encoding.

=head2 C<rendered>

    $c->rendered;

Finalize response and run C<after_dispatch> plugin hook.
Note that this method is EXPERIMENTAL and might change without warning!

=head2 C<req>

    my $req = $c->req;

Alias for C<$c->tx->req>.
Usually refers to a L<Mojo::Message::Request> object.

=head2 C<res>

    my $res = $c->res;

Alias for C<$c->tx->res>.
Usually refers to a L<Mojo::Message::Response> object.

=head2 C<send_message>

    $c = $c->send_message('Hi there!');

Send a message via WebSocket, only works if there is currently a WebSocket
connection in progress.

=head2 C<session>

    my $session = $c->session;
    my $foo     = $c->session('foo');
    $c          = $c->session({foo => 'bar'});
    $c          = $c->session(foo => 'bar');

Persistent data storage, by default stored in a signed cookie.
Note that cookies are generally limited to 4096 bytes of data.

    $c->session->{foo} = 'bar';
    my $foo = $c->session->{foo};
    delete $c->session->{foo};

=head2 C<signed_cookie>

    $c         = $c->signed_cookie(foo => 'bar');
    $c         = $c->signed_cookie(foo => 'bar', {path => '/'});
    my $value  = $c->signed_cookie('foo');
    my @values = $c->signed_cookie('foo');

Access signed request cookie values and create new signed response cookies.
Cookies failing signature verification will be automatically discarded.

=head2 C<stash>

    my $stash = $c->stash;
    my $foo   = $c->stash('foo');
    $c        = $c->stash({foo => 'bar'});
    $c        = $c->stash(foo => 'bar');

Non persistent data storage and exchange.

    $c->stash->{foo} = 'bar';
    my $foo = $c->stash->{foo};
    delete $c->stash->{foo};

=head2 C<url_for>

    my $url = $c->url_for;
    my $url = $c->url_for(controller => 'bar', action => 'baz');
    my $url = $c->url_for('named', controller => 'bar', action => 'baz');

Generate a L<Mojo::URL> for the current or a named route.

=head2 C<write>

    $c->write;
    $c->write('Hello!');
    $c->write(sub {...});
    $c->write('Hello!', sub {...});

Write dynamic content matching the corresponding C<Content-Length> header
chunk wise, the optional drain callback will be invoked once all data has
been written to the kernel send buffer or equivalent.

    $c->res->headers->content_length(6);
    $c->write('Hel');
    $c->write('lo!');

Note that this method is EXPERIMENTAL and might change without warning!

=head2 C<write_chunk>

    $c->write_chunk;
    $c->write_chunk('Hello!');
    $c->write_chunk(sub {...});
    $c->write_chunk('Hello!', sub {...});

Write dynamic content chunk wise with the C<chunked> C<Transfer-Encoding>
which doesn't require a C<Content-Length> header, the optional drain callback
will be invoked once all data has been written to the kernel send buffer or
equivalent.
Note that this method is EXPERIMENTAL and might change without warning!

    $c->write_chunk('Hel');
    $c->write_chunk('lo!');
    $c->write_chunk('');

An empty chunk marks the end of the stream.

    3
    Hel
    3
    lo!
    0

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
