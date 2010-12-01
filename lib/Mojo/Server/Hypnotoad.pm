package Mojo::Server::Hypnotoad;

use strict;
use warnings;

use base 'Mojo::Base';

use Carp 'croak';
use Cwd 'abs_path';
use Fcntl ':flock';
use File::Basename 'dirname';
use File::Spec;
use IO::File;
use IO::Poll 'POLLIN';
use List::Util 'shuffle';
use Mojo::Server::Daemon;
use POSIX qw/setsid WNOHANG/;
use Scalar::Util 'weaken';

use constant DEBUG => $ENV{HYPNOTOAD_DEBUG} || 0;

sub DESTROY {
    my $self = shift;

    # Worker
    return if $ENV{HYPNOTOAD_WORKER};

    # Manager
    return unless my $file = $self->{_config}->{pid_file};
    unlink $file if -f $file;
}

# Marge? Since I'm not talking to Lisa,
# would you please ask her to pass me the syrup?
# Dear, please pass your father the syrup, Lisa.
# Bart, tell Dad I will only pass the syrup if it won't be used on any meat
# product.
# You dunkin' your sausages in that syrup homeboy?
# Marge, tell Bart I just want to drink a nice glass of syrup like I do every
# morning.
# Tell him yourself, you're ignoring Lisa, not Bart.
# Bart, thank your mother for pointing that out.
# Homer, you're not not-talking to me and secondly I heard what you said.
# Lisa, tell your mother to get off my case.
# Uhhh, dad, Lisa's the one you're not talking to.
# Bart, go to your room.
sub run {
    my ($self, $app, $config) = @_;

    # No windows support
    die "Hypnotoad not available for Windows.\n" if $^O eq 'MSWin32';

    # Application
    $ENV{HYPNOTOAD_APP} ||= abs_path $app;

    # Config
    $ENV{HYPNOTOAD_CONFIG} ||= abs_path $config;

    # Production
    $ENV{MOJO_MODE} ||= 'production';

    # Executable
    $ENV{HYPNOTOAD_EXE} ||= $0;
    $0 = $ENV{HYPNOTOAD_APP};

    # Cleanup
    delete $ENV{MOJO_COMMANDS_DONE};
    delete $ENV{MOJO_RELOAD};

    # Clean start
    exec $ENV{HYPNOTOAD_EXE} unless $ENV{HYPNOTOAD_REV}++;

    # Daemon
    my $daemon = $self->{_daemon} = Mojo::Server::Daemon->new;

    # Debug
    warn "APPLICATION $ENV{HYPNOTOAD_APP}\n" if DEBUG;

    # Preload application
    my $file = $ENV{HYPNOTOAD_APP};
    my $preload;
    unless ($preload = do $file) {
        die qq/Can't load application "$file": $@/ if $@;
        die qq/Can't load application "$file": $!/ unless defined $preload;
        die qq/Can't load application' "$file".\n/ unless $preload;
    }
    $daemon->app($preload);

    # Load configuration
    $self->_config;

    # Testing
    die "Everything looks good!\n" if $ENV{HYPNOTOAD_TEST};

    # Prepare loop
    $daemon->prepare_ioloop;

    # Pipe for worker communication
    pipe($self->{_reader}, $self->{_writer})
      or croak "Can't create pipe: $!";
    $self->{_poll} = IO::Poll->new;
    $self->{_poll}->mask($self->{_reader}, POLLIN);

    # Daemonize
    if (!DEBUG && !$ENV{HYPNOTOAD_FOREGROUND}) {

        # Fork and kill parent
        die "Can't fork: $!" unless defined(my $pid = fork);
        exit 0 if $pid;
        setsid or die "Can't start a new session: $!";

        # Close file handles
        open STDIN,  '</dev/null';
        open STDOUT, '>/dev/null';
        open STDERR, '>&STDOUT';
    }

    # Config
    my $c = $self->{_config};

    # Manager signals
    $SIG{INT} = $SIG{TERM} = sub { $self->{_done} = 1 };
    $SIG{CHLD} = sub {
        while ((my $pid = waitpid -1, WNOHANG) > 0) { $self->_reap($pid) }
    };
    $SIG{QUIT} = sub { $self->{_done} = $self->{_graceful} = 1 };
    $SIG{USR2} = sub { $self->{_upgrade} ||= time };
    $SIG{TTIN} = sub { $c->{workers}++ };
    $SIG{TTOU} = sub {
        return unless $c->{workers};
        $c->{workers}--;
        $self->{_workers}->{shuffle keys %{$self->{_workers}}}->{graceful}
          ||= time;
    };

    # Debug
    warn "MANAGER STARTED $$\n" if DEBUG;

    # Mainloop
    $self->_manage while 1;
}

sub _config {
    my $self = shift;

    # File
    my $file = $ENV{HYPNOTOAD_CONFIG};

    # Debug
    warn "CONFIG $file\n" if DEBUG;

    # Config
    my $c = {};
    if (-r $file) {
        unless ($c = do $file) {
            die qq/Can't load config file "$file": $@/ if $@;
            die qq/Can't load config file "$file": $!/ unless defined $c;
            die qq/Config file "$file" did not return a hashref.\n/
              unless ref $c eq 'HASH';
        }
    }
    $self->{_config} = $c;

    # Graceful timeout
    $c->{graceful_timeout} ||= 30;

    # Heartbeat interval
    $c->{heartbeat_interval} ||= 5;

    # Heartbeat timeout
    $c->{heartbeat_timeout} ||= 2;

    # Lock file
    $c->{lock_file}
      ||= File::Spec->catfile($ENV{MOJO_TMPDIR} || File::Spec->tmpdir,
        "hypnotoad.$$.lock");

    # PID file
    $c->{pid_file}
      ||= File::Spec->catfile(dirname($ENV{HYPNOTOAD_APP}), 'hypnotoad.pid');

    # Reverse proxy support
    $ENV{MOJO_REVERSE_PROXY} = 1 if $c->{proxy};

    # Upgrade timeout
    $c->{upgrade_timeout} ||= 30;

    # Workers
    $c->{workers} ||= 4;

    # Daemon
    my $daemon = $self->{_daemon};

    # Backlog
    $daemon->backlog($c->{backlog}) if defined $c->{backlog};

    # Clients
    $daemon->max_clients($c->{clients} || 1000);

    # Group
    $daemon->group($c->{group}) if $c->{group};

    # Keep alive requests
    $daemon->max_requests($c->{keep_alive_requests} || 100);

    # Keep alive timeout
    $daemon->keep_alive_timeout($c->{keep_alive_timeout} || 5);

    # Listen
    my $listen = $c->{listen} || ['http://*:8080'];
    $listen = [$listen] unless ref $listen;
    $daemon->listen($listen);

    # User
    $daemon->group($c->{user}) if $c->{user};

    # WebSocket timeout
    $daemon->websocket_timeout($c->{websocket_timeout} || 300);
}

sub _heartbeat {
    my $self = shift;

    # Poll
    my $poll = $self->{_poll};
    $poll->poll(1);

    # Readable
    return unless $poll->handles(POLLIN);

    # Read
    return unless $self->{_reader}->sysread(my $chunk, 4194304);

    # Parse
    while ($chunk =~ /(\d+)\n/g) {
        my $pid = $1;

        # Heartbeat
        $self->{_workers}->{$pid}->{time} = time;
    }
}

sub _manage {
    my $self = shift;

    # Config
    my $c = $self->{_config};

    # Housekeeping
    if (!$self->{_done}) {

        # Spawn more workers
        $self->_spawn while keys %{$self->{_workers}} < $c->{workers};

        # Check PID file
        $self->_pid;
    }

    # Shutdown
    elsif (!keys %{$self->{_workers}}) { exit 0 }

    # Upgraded
    if ($ENV{HYPNOTOAD_PID} && $ENV{HYPNOTOAD_PID} ne $$) {

        # Debug
        warn "STOPPING MANAGER $ENV{HYPNOTOAD_PID}\n" if DEBUG;

        kill 'QUIT', $ENV{HYPNOTOAD_PID};
    }
    $ENV{HYPNOTOAD_PID} = $$;

    # Check heartbeat
    $self->_heartbeat;

    # Upgrade
    if ($self->{_upgrade} && !$self->{_done}) {

        # Start
        unless ($self->{_new}) {

            # Debug
            warn "UPGRADING\n" if DEBUG;

            # Fork
            croak "Can't fork: $!" unless defined(my $pid = fork);
            $self->{_new} = $pid if $pid;

            # Fresh start
            exec $ENV{HYPNOTOAD_EXE} unless $pid;
        }

        # Timeout
        kill 'TERM', $self->{_new}
          if $self->{_upgrade} + $c->{upgrade_timeout} <= time;
    }

    # Workers
    while (my ($pid, $w) = each %{$self->{_workers}}) {

        # No heartbeat
        my $interval = $c->{heartbeat_interval};
        my $timeout  = $c->{heartbeat_timeout};
        if ($w->{time} + $interval + $timeout <= time) {

            # Debug
            warn "STOPPING WORKER $pid\n" if DEBUG;

            # Try graceful
            $w->{graceful} ||= time;
        }

        # Graceful stop
        $w->{graceful} ||= time if $self->{_graceful};
        if ($w->{graceful}) {

            # Debug
            warn "QUIT $pid\n" if DEBUG;

            # Kill
            kill 'QUIT', $pid;

            # Timeout
            $w->{force} = 1
              if $w->{graceful} + $c->{graceful_timeout} <= time;
        }

        # Normal stop
        if (($self->{_done} && !$self->{_graceful}) || $w->{force}) {

            # Debug
            warn "TERM $pid\n" if DEBUG;

            # Kill
            kill 'TERM', $pid;
        }
    }
}

sub _pid {
    my $self = shift;

    # PID file
    my $file = $self->{_config}->{pid_file};

    # Check
    return if -e $file;

    # Debug
    warn "PID $file\n" if DEBUG;

    # Create
    my $pid = IO::File->new($file, O_WRONLY | O_CREAT | O_EXCL, 0644)
      or croak qq/Can't create PID file "$file": $!/;
    print $pid $$;
}

# Dear Mr. President, there are too many states nowadays.
# Please eliminate three.
# P.S. I am not a crackpot.
sub _reap {
    my ($self, $pid) = @_;

    # Cleanup failed upgrade
    if (($self->{_new} || '') eq $pid) {

        # Debug
        warn "UPGRADE FAILED\n" if DEBUG;

        delete $self->{_upgrade};
        delete $self->{_new};
    }

    # Cleanup worker
    else {

        # Debug
        warn "WORKER DIED $pid\n" if DEBUG;

        delete $self->{_workers}->{$pid};
    }
}

sub _spawn {
    my $self = shift;

    # Fork
    croak "Can't fork: $!" unless defined(my $pid = fork);

    # Manager
    return $self->{_workers}->{$pid} = {time => time} if $pid;

    # Worker
    $ENV{HYPNOTOAD_WORKER} = 1;

    # Daemon
    my $daemon = $self->{_daemon};

    # Loop
    my $loop = $daemon->ioloop;

    # Config
    my $c = $self->{_config};

    # Lock file
    my $file = $c->{lock_file};
    my $lock = IO::File->new("> $file")
      or croak qq/Can't open lock file "$file": $!/;

    # Weaken
    weaken $self;

    # Accept mutex
    $loop->on_lock(
        sub {

            # Blocking
            my $l;
            if (my $blocking = $_[1]) {
                eval {
                    local $SIG{ALRM} = sub { die "alarm\n" };
                    my $old = alarm 1;
                    $l = flock $lock, LOCK_EX;
                    alarm $old;
                };
                if ($@) {
                    die $@ unless $@ eq "alarm\n";
                    $l = 0;
                }
            }

            # Non blocking
            else { $l = flock $lock, LOCK_EX | LOCK_NB }

            return $l;
        }
    );
    $loop->on_unlock(sub { flock $lock, LOCK_UN });

    # Heartbeat
    my $cb;
    $cb = sub {
        my $loop = shift;
        $loop->timer($c->{heartbeat} => $cb);
        $self->{_writer}->syswrite("$$\n") or exit 0;
    };
    $cb->($loop);
    weaken $cb;

    # Worker signals
    $SIG{INT} = $SIG{TERM} = $SIG{CHLD} = $SIG{USR2} = $SIG{TTIN} =
      $SIG{TTOU} = 'DEFAULT';
    $SIG{QUIT} = sub { $loop->max_connections(0) };

    # Debug
    warn "WORKER STARTED $$\n" if DEBUG;

    # Cleanup
    delete $self->{_reader};
    delete $self->{_poll};

    # User and group
    $daemon->setuidgid;

    # Start
    $loop->start;

    # Shutdown
    exit 0;
}

1;
__END__

=head1 NAME

Mojo::Server::Hypnotoad - ALL GLORY TO THE HYPNOTOAD!

=head1 SYNOPSIS

    use Mojo::Server::Hypnotoad;

    my $toad = Mojo::Server::Hypnotoad->new;
    $toad->run('myapp.pl', 'hypnotoad.conf');

=head1 DESCRIPTION

L<Mojo::Server::Hypnotoad> is a full featured UNIX optimized preforking async
io HTTP 1.1 and WebSocket server built around the very well tested and
reliable L<Mojo::Server::Daemon> with C<TLS>, C<Bonjour>, C<epoll>, C<kqueue>
and hot deployment support that just works.

Optional modules L<IO::KQueue>, L<IO::Epoll>, L<IO::Socket::SSL> and
L<Net::Rendezvous::Publish> are supported transparently and used if
installed.

Note that this module is EXPERIMENTAL and might change without warning!

=head1 SIGNALS

You can control C<hypnotoad> at runtime with signals.

=head2 Manager

=over 4

=item C<INT>, C<TERM>

Shutdown server immediately.

=item C<QUIT>

Shutdown server gracefully.

=item C<TTIN>

Increase worker pool by one.

=item C<TTOU>

Decrease worker pool by one.

=item C<USR2>

Attempt zero downtime software upgrade (hot deployment) without losing any
incoming connections.

    Manager (old)
    |- Worker [1]
    |- Worker [2]
    |- Worker [3]
    |- Worker [4]
    `- Manager
       |- Worker [1]
       |- Worker [2]
       |- Worker [3]
       `- Worker [4]

The new manager will automatically send a C<QUIT> signal to the old manager
and take over serving requests after starting up successfully.

=back

=head2 Worker

=over 4

=item C<INT>, C<TERM>

Stop worker immediately.

=item C<QUIT>

Stop worker gracefully.

=back

=head1 CONFIGURATION

C<Hypnotoad> configuration files are normal Perl scripts returning a hash.

    # hypnotoad.conf
    {listen => ['http://*:3000', 'http://*:4000'], workers => 10};

The following parameters are currently available.

=over 4

=item backlog

    backlog => 128

Listen backlog size, defaults to C<SOMAXCONN>.

=item clients

    clients => 100

Maximum number of parallel client connections per worker process, defaults to
C<1000>.

=item graceful_timeout

    graceful_timeout => 15

Time in seconds a graceful worker stop may take before being forced, defaults
to C<30>.

=item group

    group => 'staff'

Group name for worker processes.

=item heartbeat_interval

    heartbeat_interval => 3

Heartbeat interval in seconds, defaults to C<5>.

=item heartbeat_timeout

    heartbeat_timeout => 5

Time in seconds before a worker without a heartbeat will be stopped, defaults
to C<2>.

=item keep_alive_requests

    keep_alive_requests => 50

Number of keep alive requests per connection, defaults to C<100>.

=item keep_alive_timeout

    keep_alive_timeout => 10

Time in seconds a connection may be idle, defaults to C<5>.

=item listen

    listen => ['http://*:80']

List of ports and files to listen on, defaults to C<http://*:8080>.

=item lock_file

    lock_file => '/tmp/hypnotoad.lock'

Full path to accept mutex lock file, defaults to a random temporary file.

=item pid_file

    pid_file => '/var/run/hypnotoad.pid'

Full path to PID file, defaults to C<hypnotoad.pid> in the same directory as
the application.

=item proxy

    proxy => 1

Activate reverse proxy support, defaults to the value of
C<MOJO_REVERSE_PROXY>.

=item upgrade_timeout

    upgrade_timeout => 15

Time in seconds a zero downtime software upgrade may take before being
aborted, defaults to C<30>.

=item user

    user => 'sri'

User name for worker processes.

=item websocket_timeout

    websocket_timeout => 150

Time in seconds a WebSocket connection may be idle, defaults to C<300>.

=item workers

    workers => 10

Number of worker processes, defaults to C<4>.
A good rule of thumb is two worker processes per cpu core.

=back

=head1 METHODS

L<Mojo::Server::Hypnotoad> inherits all methods from L<Mojo::Base> and
implements the following new ones.

=head2 C<run>

    $toad->run('script/myapp', 'hypnotoad.conf');

Start server.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicious.org>.

=cut
