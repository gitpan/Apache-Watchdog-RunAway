package Apache::Watchdog::RunAway;

BEGIN {
  # RCS/CVS complient:  must be all one line, for MakeMaker
  $Apache::VMonitor::VERSION = do { my @r = (q$Revision: 0.01 $ =~ /\d+/g); sprintf "%d."."%02d" x $#r, @r }; 
}

use strict;
use Apache::Scoreboard ();
use Apache::Constants ();
use Symbol ();
use Apache ();



########## user configurable variables #########

# timeout before counted as hang (in seconds)
# 0 means deactivated
$Apache::Watchdog::RunAway::TIMEOUT = 0;

# polling intervals in seconds
$Apache::Watchdog::RunAway::POLLTIME = 60;

# debug mode
$Apache::Watchdog::RunAway::DEBUG = 0;

# lock file
$Apache::Watchdog::RunAway::LOCK_FILE = "/tmp/safehang.lock";

# log file
$Apache::Watchdog::RunAway::LOG_FILE = "/tmp/safehang.log";

# scoreboard URL
$Apache::Watchdog::RunAway::SCOREBOARD_URL = "http://localhost/scoreboard";

########## internal variables #########

# request processing times cache
%Apache::Watchdog::RunAway::req_proc_time = ();

# current request number
%Apache::Watchdog::RunAway::req_number = ();


# check whether the monitor is already running
# returns the PID if lockfile exists
##############
sub is_running{

  return 0 unless -e $Apache::Watchdog::RunAway::LOCK_FILE;

  my $pid = get_proc_pid();

  print STDERR qq{$0 is already running (proc $pid). Locked in $Apache::Watchdog::RunAway::LOCK_FILE.};

  return $pid;

} # end of sub is_running


# returns the PID if lockfile exists or 0
################
sub get_proc_pid{

  my $fh = Symbol::gensym();
  open $fh, $Apache::Watchdog::RunAway::LOCK_FILE 
    or die "Cannot open $Apache::Watchdog::RunAway::LOCK_FILE: $!";
  chomp (my $pid = <$fh>);
  $pid = 0 unless $pid =~ /^\d+$/;
  close $fh;

  return $pid;
} # end of get_proc_pid


# create the lockfile and put the PID inside
##############
sub lock{

  my $fh = Symbol::gensym();
  open $fh, ">".$Apache::Watchdog::RunAway::LOCK_FILE
    or die "Cannot open $Apache::Watchdog::RunAway::LOCK_FILE: $!";
  flock $fh, 2;
  seek $fh, 0, 0;
  print $fh $$;
  close $fh;

} # end of lock


#################
sub stop_monitor{
  
  unless (-e $Apache::Watchdog::RunAway::LOCK_FILE) {
    print "$0: Lockfile $Apache::Watchdog::RunAway::LOCK_FILE doesn't exist. Exitting...\n";
    return;
  }
  
  my $pid = get_proc_pid();

  my $killed = kill 15, $pid if $pid;
  print "$0: Process $pid was killed\n" if $killed;

    # unlock the lockfile
  unlink $Apache::Watchdog::RunAway::LOCK_FILE;

} # end of stop_monitor


##################
sub start_detached_monitor{
  
  defined (my $watchdog_pid = fork) or die "Cannot fork: $!\n";
  
  start_monitor() unless $watchdog_pid;

} # end of sub start_detached_monitor


#################
sub start_monitor{

    # 0 means don't monitor
  return unless $Apache::Watchdog::RunAway::TIMEOUT;

  # handle the case where apache restarts itself, either on start or
  # with PerlFresh ON... this is a closure to protect this variable
  # from user. it's inaccessable outside of this module
  return if is_running();

    # The forked process is supposed to run as long as main process
    # runs, so we don't care about wait()
  warn "$0: spawned a monitor process $$\n";
#      if $Apache::Watchdog::RunAway::DEBUG;

    # create a lock file
  lock();

#    # redirect all messages to the log file
#  open STDERR, ">>$Apache::Watchdog::RunAway::LOG_FILE" or 
#    die "Cannot open >>$Apache::Watchdog::RunAway::LOG_FILE: $!";

    # neverending loop
  while (1) {
#    warn(__PACKAGE__.": $$ sleeping $Apache::Watchdog::RunAway::POLLTIME\n")
#      if $Apache::Watchdog::RunAway::DEBUG;
    monitor();
    sleep $Apache::Watchdog::RunAway::POLLTIME;
  }

} # end of sub start_monitor


# the real code that does all the accounting and killings
############
sub monitor{

  my $image = Apache::Scoreboard->fetch($Apache::Watchdog::RunAway::SCOREBOARD_URL);
  unless ($image){
      # reset the counters and timers
    %Apache::Watchdog::RunAway::req_proc_time = ();
    %Apache::Watchdog::RunAway::req_number = ();
    return;
  }

  for (my $i = 0; $i<Apache::Constants::HARD_SERVER_LIMIT; $i++) {
    my $pid = $image->parent($i)->pid;

    last unless $pid;

    my $process = $image->servers($i);
      # we care only about processes that kin 'W' status
      # processing. this is very not clean coding style: (W means
      # 'writing to a client' and it's equal to 4 in status field
    next unless $process->status == 4;

      # init if it's uninitialized (to non existant -1 count)
      # can't use ||= construct as a value can be 0...
    $Apache::Watchdog::RunAway::req_number{$pid} = -1 unless exists $Apache::Watchdog::RunAway::req_number{$pid};
      # make sure the proc time is initialized
    $Apache::Watchdog::RunAway::req_proc_time{$pid} ||= 0;

    my $count = $process->my_access_count;
#    warn "OK $i $pid ",$process->status," $count ",
#      $Apache::Watchdog::RunAway::req_proc_time{$pid}," ",
#    $Apache::Watchdog::RunAway::req_number{$pid},"\n";

    if ($count == $Apache::Watchdog::RunAway::req_number{$pid}) {

       # the same request is still being processed
      if ($Apache::Watchdog::RunAway::req_proc_time{$pid} > $Apache::Watchdog::RunAway::TIMEOUT) {

	my $fh = Symbol::gensym();
	open $fh, ">>".$Apache::Watchdog::RunAway::LOG_FILE
	  or die "Cannot open >>$Apache::Watchdog::RunAway::LOG_FILE: $!";
	flock $fh, 2;
	seek $fh, 0, 2; # go to eof
	print $fh "[".scalar localtime()."] ".__PACKAGE__.
	  qq{: child proc $pid seems to hang -- 
it is running longer than limit of $Apache::Watchdog::RunAway::TIMEOUT secs (\$Apache::Watchdog::RunAway::TIMEOUT). 
Killing proc $pid.\n};
	close $fh;
	kill 9, $pid;

    # META: should I kill or just send a SIGPIPE to a hanging process?

      } else {
	#warn "o0o\n";
	  # Note: this is not true processing time, since there is a
	  # work done between sleeps, but it takes less than 1 second
	$Apache::Watchdog::RunAway::req_proc_time{$pid} += $Apache::Watchdog::RunAway::POLLTIME;
      }

    } else {
      $Apache::Watchdog::RunAway::req_number{$pid} = $count;	
        # reset time delta
      $Apache::Watchdog::RunAway::req_proc_time{$pid} = 0;
    }

  } # end of for (my $i=-1; ...

}  # end of sub monitor

=pod

=head1 NAME

Apache::Watchdog::RunAway - a monitor for hanging processes

=head1 SYNOPSIS

  stop_monitor();
  start_monitor();
  start_detached_monitor();

  $Apache::Watchdog::RunAway::TIMEOUT = 0;
  $Apache::Watchdog::RunAway::POLLTIME = 60;
  $Apache::Watchdog::RunAway::DEBUG = 0;
  $Apache::Watchdog::RunAway::LOCK_FILE = "/tmp/safehang.lock";
  $Apache::Watchdog::RunAway::LOG_FILE = "/tmp/safehang.log";
  $Apache::Watchdog::RunAway::SCOREBOARD_URL = "http://localhost/scoreboard";

=head1 DESCRIPTION

A module that monitors hanging Apache/mod_perl processes. You define
the time in seconds after which the process to be counted as
hanging. You also control the polling time between check to check.

When the process is considered as 'hanging' it will be killed and the
event logged into a log file. The log file is being opened on append,
so you can basically defined the same log file that uses Apache. 

You can start this process from startup.pl or through any other
method. (e.g. a crontab). Once started it runs indefinitely, untill
killed.

You cannot start a new monitoring process before you kill the old one.
The lockfile will prevent you from doing that.

Generally you should use the C<amprapmon> program that bundled with this
module's distribution package, but you can write your own code using
the module as well. See the amprapmon manpage for more info about it.

Methods:

=over

=item * stop_monitor()

Stop the process based on the PID in the lock file. Remove the lock
file.

=item * start_monitor()

Starts the monitor in the current process. Create the lock file.

=item * start_detached_monitor()

Starts the monitor in a forked process. (used by C<amprapmon>). Create
the lock file.

=back

=head1 WARNING

This is an alpha version of the module, so use it after a testing on
development machine. 

The most critical parameter is the value of
I<$Apache::Watchdog::RunAway::TIMEOUT> (see
L<CONFIGURATION|/CONFIGURATION>), since the processes will be killed
without waiting for them to quit (since they hung).

=head1 CONFIGURATION

Install and configure C<Apache::Scoreboard> module

 <Location /scoreboard>
    SetHandler perl-script
    PerlHandler Apache::Scoreboard::send
    order deny,allow
 #    deny from all
 #    allow from ...
 </Location>

Configure the Apache::Watchdog::RunAway parameters:

  $Apache::Watchdog::RunAway::TIMEOUT = 0;

The time in seconds after which the process is considered hanging. 0
means deactivated. The default is 0 (deactivated).

  $Apache::Watchdog::RunAway::POLLTIME = 60;

Polling intervals in seconds. The default is 60.

  $Apache::Watchdog::RunAway::DEBUG = 0;

Debug mode (0 or 1). The default is 0.

  $Apache::Watchdog::RunAway::LOCK_FILE = "/tmp/safehang.lock";

The process lock file location. The default is I</tmp/safehang.lock>

  $Apache::Watchdog::RunAway::LOG_FILE = "/tmp/safehang.log";

The log file location. Since it flocks the file, you can safely use
the same log file that Apache uses, so you will get the messages about
killed processes in file you've got used to. The default is
I</tmp/safehang.log>

  $Apache::Watchdog::RunAway::SCOREBOARD_URL = "http://localhost/scoreboard";

Since the process relies on scoreboard URL configured on any of your
machines (the URL returns a binary image that includes the status of
the server and its children), you must specify it. This enables you to
run the monitor on one machine while the server can run on the other
machine. The default is URI is I<http://localhost/scoreboard>.

Start the monitoring process either with:

  start_detached_monitor()

that starts the monitor in a forked process or

  start_monitor()

that starts the monitor in the current process.

Stop the process with:

stop_monitor()

The distribution arrives with C<amprapmon> program that provides an rc.d
like or apachectl interface.

Instead of using a Perl interface you can start it from the command line:

  amprapmon start

or from the I<startup.pl> file:

  system "amprapmon start";

or

  system "amprapmon stop";
  system "amprapmon start";

or

  system "amprapmon restart";

As mentioned before, once started it sholdn't be killed. So you may
leave only the C<system "amprapmon start";> in the I<startup.pl>

You can start the C<amprapmon> program from crontab as well.

=head1 TUNING

The most important part of configuration is choosing the right timeout
(aka $Apache::Watchdog::RunAway::TIMEOUT) parameter. You should try
this code that hangs and see the process killed after a timeout if the
monitor is running.

  my $r = shift;
  $r->send_http_header('text/plain');
  print "PID = $$\n";
  $r->rflush;
  while(1){
    $r->print("\0");
    $r->rflush;
    $i++;
    sleep 1;
  }

=head1 TROUBLESHOOTING

The module relies on correctly configured C</scoreboard> location
URI. If it cannot fetch the URI, it queitly assumes that server is
stopped. So either check manually that the C</scoreboard> location URI
is working or use the above test script that hangs to make sure it
works.

Enable debug mode for more information.

=head1 PREREQUISITES

You need to have B<Apache::Scoreboard> installed and configured in
I<httpd.conf>.

=head1 BUGS

Was ist dieses?

=head1 SEE ALSO

L<Apache>, L<mod_perl>, L<Apache::Scoreboard>

=head1 AUTHORS

Stas Bekman <sbekman@iname.com>

=head1 COPYRIGHT

Apache::Watchdog::RunAway is free software; you can redistribute it
and/or modify it under the same terms as Perl itself.

=cut

1;
