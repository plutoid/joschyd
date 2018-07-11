#!/usr/bin/perl
#
#
#        joschyd: Yet another watchdog - daemon
#
#           by F.-P. Reich, O3SI Dresden
#
#           $Rev: 98 $
#           $Author: fpreich $
# $LastChangedDate: 2008-03-18 10:44:48 +0100 (Di, 18 Mrz 2008) $
#
#
#
package PerlSvc;

use strict;
use vars qw/ $VERSION $DATE @rcfile @sections $cfg $rc $db @norec $start_time
             $dirname $basename $job $section $receipts $db_file $pid_fname $log_file
             $path $realtime @rcfile $keep_alive $live_cycle $keepalive_subject $keepalive_body /;

$VERSION = sprintf("%d", q$Rev: 98 $ =~ /(\d+)/);
$DATE    = sprintf("%4d.%02d.%02d %02d:%02d:%02d", q$LastChangedDate: 2008-03-18 10:44:48 +0100 (Di, 18 Mrz 2008) $ =~ /(\d\d\d\d)-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)/);
#
use Cwd;
use IO::File;
use IO::Socket;
use IO::Handle;
use File::Basename;
use Mail::Sender;
use AppConfig qw(:expand :argcount);
use AppConfig::State;
use AppConfig::File;
use AppConfig::Args;
use AppConfig::Sys;
use POSIX;
use Fcntl ':flock';
use Time::Piece ':override';
use Time::Seconds;
use POSIX 'setsid';
use Storable;
use Data::Dumper;
use Pod::Usage;
use Sys::Hostname;

$|=1;

$path = $0;

unless($^O =~ /MSWin32/i) {
    *ContinueRun = sub { sleep $_[0] };
    _main()
}

sub _main {
  $rc = AppConfig->new( { CASE     => 1,
                          CREATE   => 1,
                          GLOBAL   => {
					DEFAULT  => 0,
					ARGCOUNT => ARGCOUNT_ONE,
                           }
                         },
              qw( conf )
	);

  $dirname  = dirname($path);
  $basename = basename($path); $basename =~ s/\..*$//;

  if ($ARGV[0] eq '-h') {
  	pod2usage( -verbose => 2 );
  	exit
  }
  if ($ARGV[0] eq '-c') {
     push @rcfile, $ARGV[1];
  }
  for my $rcfile ("$dirname/${basename}.conf", <$dirname/../etc/${basename}*.conf>, <$dirname/etc/${basename}*.conf>) {
     next if $rcfile eq $ARGV[1] or not -e $rcfile;
     push @rcfile, $rcfile
  }
  for my $rcfile (@rcfile) {
      $rc->file("$rcfile") or Die("reading @rcfile: $!")
  }
  %$cfg = $rc->varlist("config_", "config_");		# get Configuration

  daemonize() unless $cfg->{debug};

  $log_file = $cfg->{log_file} ? $cfg->{log_file} : "$dirname/$basename.log";
  $cfg->{debug} and flog_ts("rcfile(s): @rcfile, dirname = $dirname, basename = $basename");

  flog_ts("Try to start joschyd ...");

  $db_file = $cfg->{db_file} ? $cfg->{db_file} : "$dirname/.${basename}.db";

  $pid_fname =  $cfg->{pid_fname} ? $cfg->{pid_fname} : "/var/run/${basename}.pid";

  unless($^O =~ /MSWin32/) {

    Die("You should be root to run $basename") if `id` =~ /^uid=(\d+)\(.*$/ && $1;

    my $ps_flags = $^O =~ /linux/i ? 'aefww' : 'aef';
    @norec = grep /$basename/, `ps -$ps_flags | egrep -v start`;

    Die("${0} already running") if -e $pid_fname && $#norec > 0
  }

  my $pidfile = new IO::File; $pidfile->open("> $pid_fname") or Die("Can't create $pid_fname: $!\n");

  $pidfile->print($$) or warn "Can\'t print to pid_file: $!\n"; $pidfile->close;
  flog_ts("#----*--- joschyd V$VERSION/$DATE just invoked, $pid_fname created ---*----#");

  catch_zap();						# print config

  $SIG{HUP} = $SIG{TERM} = $SIG{INT} = \&catch_zap;	# catching some signals

  $cfg->{alarm_type} 	    = 'JOSCHY' unless $cfg->{alarm_type};
  $cfg->{keepalive_seconds} = $keep_alive = Tim2Sec($cfg->{keepalive});
  $live_cycle		    = $keep_alive / Tim2Sec($cfg->{sleeptime});
  $keepalive_subject	    = $cfg->{keepalive_subject}	|| "Heartbeat [% hostname %]"; 
  $keepalive_body	    = $cfg->{keepalive_body}	|| "Type:[% alarm_type %]\nInterval:$keep_alive";
  send_mail( process_templates($keepalive_subject, $keepalive_body, $basename), split(/,|;/, $cfg->{receipts}) );
  $realtime 		    = Tim2Sec($cfg->{sleeptime});
  flog_ts("Sleeping $realtime sec. . . .") if $cfg->{debug};

  while(ContinueRun($realtime)) {

    my $start_time = localtime;
    unless ( --$live_cycle ) {
  	send_mail( process_templates($keepalive_subject, $keepalive_body, $basename), split(/,|;/, $cfg->{receipts}) );
        $live_cycle = $keep_alive / Tim2Sec($cfg->{sleeptime})
    }
    -e $db_file and $db = eval { retrieve($db_file) };
    if($@) {
        $db->{msg} = "Critical error: retrieve: $db_file: $@";
        flog_ts($db->{msg});       
        unlink $db_file;
        catch_zap();
        $db = {}
    }
    for $section (@sections) {
        $cfg->{debug} and flog_ts("\n\n\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\ $section ////////////////////");
        $job = {};
        %$job = $rc->varlist("${section}_", "${section}_");
	if ($job->{min_time} and $job->{max_time}) {
	  next unless check_time_period('*:'.$start_time->hms, $job->{min_time}, $job->{max_time})
	}
        if($job->{sleeptime} and Tim2Sec($job->{sleeptime}) > Tim2Sec($cfg->{sleeptime})) {
            $db->{n_sleep}->{$section} or
                $db->{n_sleep}->{$section} = int(Tim2Sec($job->{sleeptime}) / Tim2Sec($cfg->{sleeptime}));
            --$db->{n_sleep}->{$section} and next
        }
        my $max_retries    = $job->{max_retries}   || $cfg->{max_retries};
	$receipts          = $job->{receipts}      || $cfg->{receipts};
	my $auto_resum     = $cfg->{auto_resum}    ? Tim2Sec($cfg->{auto_resum}) : 86400;
	my $type           = $job->{alarm_type}    || $cfg->{alarm_type};
	$job->{alarm_type} = $type;
        my $suspend_delay;
        if($job->{suspend_delay}) {
            $suspend_delay = int(Tim2Sec($job->{suspend_delay}) /
			    ($job->{sleeptime} ? Tim2Sec($job->{sleeptime}) : Tim2Sec($cfg->{sleeptime})))
        }
        print_job_config($section, $job)	   if $cfg->{debug};
	unless($^O =~ /MSWin32/i) {
		$SIG{ALRM} = \&job_timeout;
		my $alarm  = $cfg->{alarm} ? $cfg->{alarm} : 60;
        	alarm $alarm
        }
	my $hits = 0;
	if ($job->{command} && $job->{regex}) {
	    $hits = @norec = grep /($job->{regex})/, eval { `$job->{command}` };
	    $job->{description} .= "\n" . join "\n", $@ ? $@ : @norec
	}
	elsif ($job->{eval}) {
	    my $eval = eval"$job->{eval}";
	    if(defined $eval) {
	        if($job->{regex}) {
		    $hits = @norec = grep /($job->{regex})/, split /\n/, $eval;
	            $job->{description} .= "\n" . join "\n", @norec
		} else {
		    $hits = $eval;
		    $job->{description} .= "\nValue: $eval\n"
		}
	    } else {
		$hits = length $@;
		$job->{description} .= "\n$@"
	    }
	}
	elsif ($job->{logfile}) {
            if($job->{precmd}) {
		eval { system "$job->{precmd}" };
                $@ and warn "Error executing: $job->{precmd}: $@"
	    }
	    for my $file ( glob $job->{logfile} ) {
	        unless (-e $file) {
	            logg("$file doesn't exists");
	            next
	        }
	        if ((! defined $db->{mem}->{$section}->{$file}->{curpos}) or
	           (defined $db->{mem}->{$section}->{$file}->{curpos} and $db->{mem}->{$section}->{$file}->{curpos} > -s $file)) {
	            $db->{mem}->{$section}->{$file}->{curpos} = 0;	# -s $file;
	            logg("First Run or Logfile ($file) cutted, Curpos set to: 0\n")
	        }
	        $job->{description} .= "\n";
	        open(FH, "< $file") or Die("can't open $file: $!");
	        binmode FH;
	        seek(FH, $db->{mem}->{$section}->{$file}->{curpos}, 0);
	        while (<FH>) {
	            if ( /($job->{regex})/ ) {
	            	next if $job->{andnot} and /($job->{andnot})/;
	        	$hits++; $job->{description} .= "$file: $_"
	            }
	        }
	        $db->{mem}->{$section}->{$file}->{curpos} = tell(FH);
	        close(FH);
	        $job->{description} .= "\nNumber of Errors: $hits \n"
	    }
	}
	else {
	    $hits = eval { `$job->{command}` };
	    $job->{description} .= $@ ? "\n$job->{command} returns: $@\n" : "\nValue: $hits\n"
	}
        logg(sprintf "+++ $section: Occurs with #%s +++", $hits) if $cfg->{debug};
	my $severities = {};
        ($severities->{yellow}->{operator}, $severities->{yellow}->{threshold}) = split / /, $job->{yellow} if exists $job->{yellow};
        ($severities->{red}->{operator},    $severities->{red}->{threshold})    = split / /, $job->{red}    if exists $job->{red};
	# Auto resuming
	if($db->{suspend}->{$section} and ((time - $db->{suspend}->{$section}) > $auto_resum)) {
            $job->{description} =  "${basename}: Just auto resuming job " . $section  .
	        ", suspended since " . localtime($db->{suspend}->{$section}) . " !!!\n\n\t";
	    clear_event($db, $section, $job, $receipts)
	}
        # Red / Yellow Event !!!
        elsif ((defined $severities->{red}->{operator}    and defined $severities->{red}->{threshold}    and eval "$hits $severities->{red}->{operator} $severities->{red}->{threshold}")   or
               (defined $severities->{yellow}->{operator} and defined $severities->{yellow}->{threshold} and eval "$hits $severities->{yellow}->{operator} $severities->{yellow}->{threshold}") ) {
            for my $color (keys %$severities) {
                if(defined $severities->{$color}->{operator} and defined $severities->{$color}->{threshold}
                    and eval "$hits $severities->{$color}->{operator} $severities->{$color}->{threshold}") {
                    if($db->{suspend}->{$section}) {
                        $cfg->{debug} and flog_ts("$section suspended !");
                        next
                    }
                    $db->{noocur}->{$section} += 1;                                 # happend
                    if($suspend_delay and $db->{noocur}->{$section} % $suspend_delay) {
                        $cfg->{debug} and flog_ts("$section: noocur: $db->{noocur}->{$section}  < suspend_delay: $suspend_delay");
                        next
                    }
                    if ( $job->{action} ) {
                        $SIG{CHLD}= 'IGNORE';
                        my $pid = fork();
                        if( defined $pid && $pid == 0 ) {			   # From this point on, we are the child.
                            my @action = split /\s+/, $job->{action};
                            flog_ts("try to exec: system: @action");
                            system(@action) == 0 or
                            flog_ts("system: @action failed: $!");
                            exit
                        }
                    }
                    if (not $job->{logfile} and $db->{noocur}->{$section} >= $max_retries) {
                        $db->{suspend}->{$section} = time unless $job->{no_suspend};
                        $job->{description} .=  "\n\n${basename}: Suspending to watch \"" . $section . "\" after $db->{noocur}->{$section} retries !!!";
                        $cfg->{debug} and flog_ts($job->{description})
                    }
                    if ($job->{logfile} or ($db->{noocur}->{$section} == 1) or ($db->{noocur}->{$section} == $suspend_delay)) {
                        send_mail(build_msg($basename, $section, $job, $color, $type), split /,|;/, $receipts)
                    }
                    exit if $cfg->{exit} and $db->{suspend}->{$section};
                }
            }
        }
        # clearing/resuming Event
	elsif ($db->{noocur}->{$section} and ! $job->{no_resume}) {
            clear_event($db, $section, $job, $receipts)
	}
    }
    eval { store($db, $db_file) };                                          # make persistent
    $@ and flog_ts("can't store db: $@");
    $realtime = Tim2Sec($cfg->{sleeptime}) - time + $start_time->epoch;
    $realtime = Tim2Sec($cfg->{sleeptime}) if $realtime <= 0;
    flog_ts("Sleeping $realtime sec. . . .") if $cfg->{debug};
    $^O =~ /MSWin32/i or alarm 0;
  }  
}

sub job_timeout {
    $job->{description} .=  "\n\n${basename}: timeout while executing section: $section";
    flog_ts($job->{description});
    send_mail(build_msg($basename, $section, $job, 'Red', $job->{alarm_type}), split /,|;/, $receipts)	
}

sub clear_event {
    my ($db, $section, $job, $receipts) = @_;
    my $msg = "$db->{noocur}->{$section} Error(s) cleared for";

    $db->{noocur}->{$section} = 0;
    if ($db->{suspend}->{$section}) {
         delete $db->{suspend}->{$section};
         $msg = "Resuming to watch"
    }
    $job->{description} .=  "${basename}: $msg " . $section;

    send_mail(build_msg($basename, $section, $job, 'Green', $job->{alarm_type}), split /,|;/, $receipts);
}


sub check_time_period {
  my $act_time = mk_time2obj(shift);
  my $min_time = mk_time2obj(shift);
  my $max_time = mk_time2obj(shift);

  $max_time += ONE_DAY if $max_time < $min_time;
  logg (sprintf "\nact_time: %s \t min_time: %s \t max_time: %s", $act_time->cdate, $min_time->cdate, $max_time->cdate)
	if $cfg->{debug};
  return 1 if $act_time >= $min_time and $act_time <= $max_time;
}


sub mk_time2obj {
	my ($days, $hours, $min, $sec) = split(/:/, "@_");;

        my $t = localtime;
        $t = $t - $t->hour * ONE_HOUR - $t->min * ONE_MINUTE - $t->second;
        if ($days !~ /\*/) {
	  $t -= $t->day_of_week * ONE_DAY;
          $t += ($days * ONE_DAY);
	}
	$t += ($hours * ONE_HOUR + $min * ONE_MINUTE + $sec)
}


sub Tim2Sec {
	my ($hour, $minute, $second) = split(/:/, "@_");

	return( $hour * 3600  + $minute  * 60 + $second )
}

sub slurp {
	my $fname = shift;
	my $ret = do { local(@ARGV, $/) = $fname, <> };
	chomp $ret;
	return $ret
}

sub my_hostname {
	if   ( $^O =~ /linux/i   ) { return slurp('/etc/HOSTNAME') }
	elsif( $^O =~ /solaris/i ) { return slurp('/etc/nodename') }
	else 			   { return hostname }
}

sub build_msg {
  my($prog, $section, $job, $severity, $type) = @_;
  my $msg_body		= $cfg->{msg_body} || <<'EOB'
Customer:[% customer %]
Date:[% datetime %]
Thema:[% section %]
Alarmtyp:JOSCHY
Severity:[% severity %]
Host:[% hostname %]
User:[% user %]
Description:[% description %]
EOB
;
  my $msg_subject		= $cfg->{msg_subject} || <<'EOS'
[% program %]: [% section %]; [% alarm_type %]; [% hostname %]; [% user %]
EOS
;

  return process_templates($msg_subject, $msg_body, $prog, $section, $job, $severity, $type)
}

sub process_templates {
  my ($msg_subject, $msg_body, $prog, $section, $job, $severity, $type) = @_;

  my $db = {};

  $db->{$_}= $cfg->{$_} for keys %$cfg;
  if($job) { $db->{$_}= $job->{$_} for keys %$job};
  $type          and $db->{alarm_type} = $type;
  $section       and $db->{section}    = $section;
  $severity      and $db->{severity}   = $severity;
  $db->{datetime}                      = ftime();
  $db->{hostname}                      = my_hostname();
  $db->{user}	                       = getlogin;
  $prog          and $db->{program}    = $prog;

  $msg_body    =~ s/\[% (\S+) %\]/$db->{$1}/g;
  $msg_subject =~ s/\[% (\S+) %\]/$db->{$1}/g;

  return ($msg_subject, $msg_body)
}

sub send_mail {
  my ($subject, $msg, @recpts) = @_;

  return unless @recpts;

  flog_ts("Mailing: ".$msg);

  for my $recpt (@recpts) {

     logg("\tTo: $recpt");

     my $sender;
     flog_ts($Mail::Sender::Error) unless ref ($sender = new Mail::Sender {
	 smtp => $cfg->{smtp_server} ? $cfg->{smtp_server} : 'localhost',
	 port => $cfg->{smtp_port}   ? $cfg->{smtp_port}   : 25,
	 from => $cfg->{sender} ? $cfg->{sender} : 'frank-peter.reich@sapsi.de'
     });
     flog_ts($Mail::Sender::Error) unless ref ($sender->MailMsg({
         to	 => $recpt,
         subject => $subject,
         msg	 => $msg
     }));
   }
}


sub catch_zap {
    my $signame = shift;

    flog_ts("Oops, somebody sent me a SIG${signame} !") if $signame;

    if($signame =~ /(TERM|INT)/ ) {

        store($db, $db_file);                                                      # make persistent

        unlink $pid_fname or Die("Can't unlink $pid_fname: $!");

        Die()

    } else {

        logg("(Re-)Reading config");

  	for my $rcfile (@rcfile) {
            $rc->file("$rcfile")				or Die("reading @rcfile: $!")
        }

        %$cfg = $rc->varlist("config_", "config_");	# get configuration

        @sections = split /,|;/, $cfg->{section_list};

        print_config();

	logg("End of (re-)reading config");

        send_state()
    }

}


sub Die {
    my $msg = shift;

    $msg .= "\n" if $msg;

    flog_ts("${msg}, Exiting ...");

    die
}


sub print_config {

    for my $section (@sections) {

        my $job = {};

        %$job = $rc->varlist("${section}_", "${section}_");

        print_job_config($section, $job)
    }
}


sub print_job_config {
    my ($section, $j) = @_;

    my $str;

    for my $entry (keys %$j) {

        $str .= sprintf "%20s: =\t%-20s\n", $entry, $j->{$entry} if exists $j->{$entry}
    }

    $str .= sprintf "\n%20s: =\t%-20s\n", '!!! Occurrences', $db->{noocur}->{$section} if $db->{noocur}->{$section};

    flog_ts("### $section ###\n");

    logg($str)
}


sub send_state {
  my $msg = "";

  logg("Entering send_state ...\n")      if $cfg->{debug};

  my $msg1 = $db->{msg} ? "$db->{msg}\n" : "";
  for (keys %{$db->{noocur}}) {

      logg("\t$_:\t$db->{noocur}->{$_}\n")	if $cfg->{debug};
      $msg1 .= "\t$_:\t$db->{noocur}->{$_}\n"
  }
  $msg .= "\n    job error occurences:\n".$msg1 if $msg1;

  $msg1 = "";
  for (keys %{$db->{suspend}}) {

    my $msg2 = "\t$_:\t" . scalar localtime($db->{suspend}->{$_}) . "\n";
    logg($msg2) if $cfg->{debug};
    $msg1 .= $msg2
  }
  $msg .= "\n    jobs suspended since:\n".$msg1 if $msg1;

  send_mail('joschyd status message', $msg, split(/,|;/, $cfg->{admins})) if $msg
}


sub flog_ts {
    my $msg = shift;

    $msg = "\n " . ftime() . ": $msg";

    logg($msg);
}


sub ftime {

    return localtime()->strftime("%Y-%m-%d %H:%M:%S")
}


#sub basename {
#    $_ = shift;
#    s/^.*\///;
#    return $_
#}


#sub dirname {
#    $_ = shift;
#    s/\/[^\/]+$//;
#    return $_
#}


sub logg {
    my $msg = shift;

    # $msg .= "\n";

    print $msg;

    my $logfile = new IO::File;

    $logfile->open(">> " . $log_file) || warn("Can't open log_file: #" . $log_file . "#: $!\n");

    flock($logfile, LOCK_EX);

    $logfile->print($msg);

    flock($logfile, LOCK_UN);

    $logfile->close
}


sub daemonize {
    unless($^O =~ /MSWin32/i) {
        chdir '/'		or Die "Can't chdir to /: $!";
        open STDIN, '/dev/null' or Die "Can't read /dev/null: $!";
        open STDOUT, '>/dev/null'
			or Die "Can't write to /dev/null: $!";
        defined(my $pid = fork)	or Die "Can't fork: $!";
        exit if $pid;
        setsid			or Die "Can't start a new session: $!";
        open STDERR, '>&STDOUT'	or Die "Can't dup stdout: $!"
    }
}

############################################ For MSWin32 service ###########################################
# Default values for configuration parameter
my $service = 'joschyd';
our(%Config,$Verbose);

# These assignments will allow us to run the script with `perl joschyd.pl`
unless (defined &ContinueRun) {
    # Don't delay the very first time ContinueRun() is called
    my $sleep;
    *ContinueRun = sub {
	Win32::Sleep(1000*shift) if $sleep && @_;
	$sleep = 1;
	return 1
    };
    *RunningAsService = sub {return 0};

    # Interactive() would be called automatically if we were running
    # the compiled joschyd.exe
    Interactive();
}

sub unsupported {
    my $option = shift;
    die "The '--$option' option is only supported in the compiled script.\n";
}

sub configure {
    %Config = (ServiceName => $service,
	       DisplayName => "joschyd",
	       Parameters  => "$ARGV[0] $ARGV[1] $ARGV[2]",
	       Description => "Yet another Watchdog Daemon V$VERSION");
}

# The Interactive() function is called whenever the Service is run from the
# commandline, and none of the --install, --remove or --help options were used.
sub Interactive {
    # Setup the %Config hash based on our configuration parameter
    configure();
    Startup();
}

# The Startup() function is called automatically when the service starts
sub Startup {
    Log("$Config{DisplayName} starting");
    _main();
    Log("$Config{DisplayName} stopped");
}

sub Log {
    my $msg = shift;
    unless (RunningAsService()) {
	print "$msg\n";
	return;
    }
    flog_ts($msg)
}

sub Install {
    configure();
}

sub Remove {
    # Let's be generous and support `joschyd --remove FooBar` too:
    $service = shift @ARGV if @ARGV;

    $Config{ServiceName} = $service;
}

sub Help {
    my $h =<<__HELP__;

Joschyd Win32 specifics

Install it as a service:
    joschyd --install auto -c config_file
    net start $service

You can pause and resume the service with:
    net pause $service
    net continue $service

To remove the service from your system, stop und uninstall it:
    net stop $service
    joschyd --remove
__HELP__

    pod2usage( -verbose => 2, input => \*DATA );
    
    # Don't display standard PerlSvc help text
    $Verbose = 0;
}

sub Pause {
    Log("$Config{ServiceName} is about to pause");
}

sub Continue {
    Log("$Config{ServiceName} is continuing");
}

__DATA__

=head1 NAME

joschyd - yet another watchdog daemon - is watching your systems with the real power of perl.

=head1 SYNOPSIS

=head2 Unix/Linux

joschyd [-h | -c config_file] &

=head2 Win32

=over 4

=item *
Install as a service:

 joschyd --install -c C:/win32app/joschyd/joschyd.conf 
 net start joschyd

=item *
You can pause and resume the service with:

 net pause joschyd
 net continue joschyd

=item *
To remove the service from your system, stop und uninstall it:

 net stop joschyd
 joschyd --remove

=back

=head1 DESCRIPTION

The guiding idea is, that's always the same:
Processes are to be checked by a command-regex combination,
logfiles watched for different expressions and
unthinkable watching needs are to be satisfied.
In all cases the number of returned hits is to be compared with a threshold and in case of bad results notified to a framework.
This and a lot of other features are realized:

=over 4

=item *
Configuration- and Logfile

A win.ini-like file is used with one section for the general daemon configuration and with one for each watchjob.
The daemon is always using a logfile.

=item *
Error hysteresis

After an incident the watchjob will be suspended for notifications (suspended job).
if the cause for the problem has been resolved a clearing message is send to the framework.

=item *
Boot cycle persistence

The current states are permanent stored.

=item *
Win32 port

Really running as service.

=item *
Signal handling

=over 4

=item *
HUP

Reads the reconfiguration file, makes a logfile entry, resets the incident counters and sends a status message.

=item *
INT, TERM

Makes a logfile entry, removes the pidfile and exits.

=back

=item *
Debugging

1 debugging level

=back

=head1 CONFIG-FILE DIRECTIVES

The following directives are provided:

=head2 Daemon specific

=over 4

=item *
admins

List of admins (separated by comma or colons) as receipts for status messages, overwritten by job specific values.

=item *
auto_resum

Time to auto resume suspended jobs, overwritten by job specific values.

=item *
customer

Describes the customer.

=item *
db_file

The optional name of the persistent db file.
Default is $dirname/.${basename}.db

=item *
debug

Level 1 enables a more verbose logging and displaying mode.

=item *
exit

Tells the daemon to exit, after reaching max_retries.

=item *
log_file

The optional logfile name.
Default is /var/adm/syslog.dated/current/${basename}.log

=item *
max_retries

Number of retries before giving up to watch, overwritten by job specific values.

=item *
pid_fname

The optional name of the pid file.
Default is /var/run/${basename}.pid

=item *
receipts

List of email receipts separated by comma or colons, overwritten by job specific values.

=item *
section_list

List of active sections of watchjobs (strongly recommended).

=item *
sender

The email - C<"From: "> - field.

=item *
sleeptime

The daemon polling time.

=item *
keepalive

The daemon keepalive time.

=item *
smtp_server

Name of the preferred smtp_server.
Default is localhost.

=item *
msg_subject

Template of notification message subject.
All global and job specific directives are accessable included by [%  %] (See example below).

 Dynamically loaded:
 section
 severity

 Additional directives:
 datetime
 hostname
 user
 program


=item *
msg_body

Template of notification body.
All global and job specific directives are accessable included by [%  %] (See example below).

 Dynamically loaded:
 section
 severity

 Additional directives:
 datetime
 hostname
 user
 program


=item *
keepalive_subject

Template of keepalive message subject.
All global configuration directives are accessable included by [%  %].

 Additional directives:
 datetime
 hostname
 user
 program
 keepalive_seconds

=item *
keepalive_body

Template of keepalive message body.
All global configuration directives are accessable included by [%  %].

 Additional directives:
 datetime
 hostname
 user
 program
 keepalive_seconds


=back

=head2 Job specific

=over 4

=item *
I<command>

B<Default type of watchjob!> OS-Command (incl. ssh, rsh !).

=item *
I<logfile>

B<Special type of watchjob!> (to use instead of B<command>) To watch growing logfiles.
As exception this kind of watchjob in case of incident will not be suspended (no error hysteresis). 

=item *
I<eval>

B<Special type of watchjob!> (to use instead of B<command>). Inserted perlcode will be executed via eval.

=item *
action

Action in case of reaching the threshold.

=item *
alarm_type

type reported to the framework.

=item *
auto_resum

Time to auto resume suspended jobs.

=item *
description

Describes the watchjob. Used for the email body.

=item *
max_retries

Number of retries before giving up to watch, overwrites the global daemon value.

=item *
max_time

Endtime for watching the job.
format: d:hh:mm:ss, d starts with 0 = Sunday

=item *
min_time

Starttime for watching the job.
format: d:hh:mm:ss, d starts with 0 = Sunday

=item *
sleeptime

Job specific polling time. Has to be bigger than daemon sleeptime.

=item *
no_suspend

The job has never to be suspend (leaving always active).
May be used for preparations for another watchjob.

=item *
no_resume

The job leavs suspended after the first incident.
May be used to supress iterations of incidents.

=item *
precmd

Command to execute as preparation for the job entry.

=item *
receipts

List of email receipts separated by comma or colons.

=item *
regex

Extended Regular expression for grep'ing the command output.

=item *
andnot

Second negatived Regular expression (only logfile entries).

=item *
threshold

Threshold of hits.

=item *
suspend_delay

After occuring event handling is delayed while this time.
format: hh:mm:ss


=back

=head1 DIAGNOSTICS

In case of incident (reaching the threshold for a job) a log entry and email will be created.

=head1 EXAMPLES

=head2 General

=over 4

 [config]
 debug            = 0
 sender           = godfather@foo.com
 log_file         = joschyd.log
 sleeptime        = 00:10:00
 keepalive        = 24:00:00
 max_retries      = 20
 section_list     = xemacs
 exit             = 0
 msg_body	= <<'EOB'
 Customer:[% customer %]
 Date:[% datetime %]
 Thema:[% section %]
 Alarmtyp:JOSCHY
 Severity:[% severity %]
 Host:[% hostname %]
 User:[% user %]
 Description:[% description %]
 EOB
 msg_subject	= <<'EOS'
 [% program %]: [% section %]; [% alarm_type %]; [% hostname %]; [% user %]
 EOS

=back

=head2 Sample Process

 [xemacs]
 command          = ps -aef
 regex            = xemacs
 red              = < 0
 min_time         = 07:00:00
 max_time         = 19:00:00
 receipts         = alert@foo.com
 description      = I don't belive it
 action           = xemacs

=head2 Oracle Alert Logfile

 [alertlog]
 logfile           = /oracle/IP1/saptrace/background/alert_IP1.log
 regex             = corrupted|ORA-(00343|00345|00312|00313|00321|27037|00376|01110|1516|1631|1632|1653|1654)
 red               = > 0
 description       = Database CORRUPTION detected, very critical !!!

=head2 SAN Paths (HDS)

 [HDS_SAN_Path]
 eval             = my (%path, $i); \
                    @_=split, $path{$_[-1]}++ \
                    for grep /^00000.+Online/, `/opt/DynamicLinkManager/bin/dlnkmgr view -path`; \
                    $path{$_} and $path{$_} < 2 and $i++ for keys %path; return $i
 red              = > 0
 description      = HDLM problem recognized !

=head1 BUGS

Currently not known.

=head1 LIMITATIONS

 Job timeout not wtched at Win32, because the missed alarm service call.
 Tested (in this order) with I<B<Tru64>>, I<B<Linux>>, I<B<Solaris>>, I<B<Aix>> and I<B<Win32>>.

=head1 SEE ALSO

The B<C>omprhensive B<P>erl B<A>rchive B<N>etwork

http://search.cpan.org

for the additional necessarly moduls:

=over 4

=item *
Mail::Sender

=item *
AppConfig

=item *
Time::Piece

=item *
Storable

=item *
Pod::Usage

=back

=head1 AUTHOR

Frank-Peter Reich, Open Source System Integrations (O3SI)

=head1 ACKNOWLEDGMENTS

I'd like to thank Larry Wall, Randolph Schwarz, Tom Christiansen, Lincoln D. Stein,
Gurusamy Sarathy, Gisle Aas and many others for making Perl what it is today,
not to forget I<B<joschy>>, the strongest watchdog I'm knowing.

=head1 COPYRIGHT

Copyright (C) 2001-2008 Open Source System Integrations (O3SI). All Rights Reserved.

This software is free; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
