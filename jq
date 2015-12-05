#!/usr/bin/perl
use strict;
use warnings;
use 5.10.0;
use Data::Dumper;
$Data::Dumper::Terse  = 1;
$Data::Dumper::Indent = 0;

use Getopt::Long qw(:config require_order);
use DBM::Deep;
use Cwd;

# ----------------------------------------------------------------------
# kinda sorta globals
my ( $db, $qid, $BASE, %options );

# ----------------------------------------------------------------------
# arguments
#<<<
GetOptions( \%options,
    "help|h|?",
    "qid|q=s",
    "tail|t",
    "flush|f",
    "history|c",
    "errors|e",
    "purge",
    "limit=i",
    "sleep|s=s",
    "logfile|lf=s",
) or die "option error; maybe a typo or a missing '--' somewhere?\n";
#>>>
usage() if $options{help};

# ----------------------------------------------------------------------
# set globals, open db
prep( $options{qid} );

# ----------------------------------------------------------------------
# main

#<<<
if      ( $options{tail} )          { tail(); }                     # tail on in-progress output
elsif   ( $options{flush} )         { flush(); }                    # cat 'done' files, unlink them
elsif   ( $options{history} )       { history(0); }                 # print history, all jobs
elsif   ( $options{errors} )        { history(1); }                 # print history, failed jobs only
elsif   ( $options{purge} )         { purge(); }
elsif   ( exists $options{limit} )  { limit( $options{limit} ); }
elsif   ( @ARGV )                   { queue(@ARGV); }               # no subcommands but arguments exist; queue up shell command
else                                { status(); say "\n(run 'jq -h' for help)\n"; }
                                                                    # no subcommands, no arguments; print status
#>>>

exit 0;

# ----------------------------------------------------------------------

sub _printf_n;
sub status {
    db_lock();

    my @d  = glob("$BASE/d/*.err");                     # we assume count of *.err and *.out is same
    my @r  = glob("$BASE/r/*.err");
    my $qc = scalar( @{ $db->{queued_pids} || [] } );

    printf STDERR ( "WARNING! %d jobs queued, but running (%d) < LIMIT (%d)\n", $qc, $db->{running}, $db->{LIMIT} )
      if $qc and $db->{LIMIT} > $db->{running};

    printf "Queue ID: '%s', limit: %d\n", $qid, $db->{LIMIT};
    _printf_n "%7d queued jobs\n",    $qc;
    _printf_n "%7d running\n",        $db->{running};
    _printf_n "%7d unflushed jobs\n", scalar(@d);
    _printf_n "%7d completed jobs\n", scalar( @{ $db->{history} || [] } );
    _printf_n "%7d errors\n",         scalar( _history_subset(1) );

    db_unlock();
}

# the workhorse of this program
sub queue {
    exit 0 if fork();    # hah!  no need to use '&' anymore :)
                         # unkillable!  well for -15 anyway not for -9
    $SIG{TERM} = sub { "phhht!"; };

    # explicit sleep if asked
    if ( ($options{sleep} || '') =~ /^(\d+)([smh]?)$/ ) {
        my %mult = ( s => 1, m => 60, h => 3600 );
        sleep $1 * $mult{ $2 || 's' };
    }

    redir();             # redirect STDOUT and STDERR right away

    # and *then* throw your hat in the ring
    my $queued     = gen_ts();
    my $sleep_time = 1;
    _log( 0, "[q $$] " . join( " ", @_ ) );

    # the waiting game

    db_lock();
    push @{ $db->{queued_pids} }, $$;
    while ( queue_full() or not my_turn() ) {
        db_unlock();
        _log( 1, "[w $$] $sleep_time" );
        sleep $sleep_time; $sleep_time %= 31; $sleep_time *= 2;
        # TODO: the backoff time is hardcoded; may (at some point) need a more sophisticated algorithm
        db_lock();
    }
    # reserve our slot and get out
    shift @{ $db->{queued_pids} };
    $db->{running}++;
    db_unlock();

    # the running game

    _log( 0, "[s $$] " . join( " ", @_ ) );
    my $started = gen_ts();
    my ( $rc, $es ) = run( $queued, @_ );
    my $completed = gen_ts();
    _log( 0, "[e $$] rc=$rc, es=$es" );

    # the end game

    db_lock();
    $db->{running}--;
    push @{ $db->{history} },
      {
        pwd       => getcwd(),
        cmd       => \@_,
        rc        => $rc,
        es        => $es,
        queued    => $queued,
        started   => $started,
        completed => $completed,
      };
    db_unlock();

    un_redir();
}

sub queue_full {
    return $db->{LIMIT} <= $db->{running};
}

sub my_turn {
    return $db->{queued_pids}->[0] == $$;
}

sub run {
    my $queued = shift;

    _log( 0, join( " ", "+", @_ ) );
    my $rc = system(@_);
    my $es = ( $rc == 0 ? 0 : interpret_exit_code() );
    say STDERR "";
    system("mv $BASE/r/$$.out $BASE/r/$$.err $BASE/d");

    return ( $rc, $es );
}

sub tail {
    for my $f ( glob "$BASE/r/*" ) {
        say "----8<---- $f";
        say `tail $f`;
    }
}

sub flush {
    for my $f ( glob "$BASE/d/*" ) {
        say "----8<---- $f";
        say `cat $f`;
        unlink $f;
    }
}

sub history {
    my $min_rc = shift;
    my @db2    = _history_subset($min_rc);
    # XXX needs to be refined later
    for (@db2) {
        next if $_->{rc} < $min_rc;
        say Dumper $_->{cmd} if $ENV{D};
        say "cd $_->{pwd}; " . join( " ", @{ $_->{cmd} } );
        say $_->{completed} . "\t" . $_->{rc} . "\t" . $_->{es};
        say "";
    }
}

sub purge {
    db_lock();
    if ( $db->{running} ) {
        db_unlock();
        die "some jobs are still running";
    }
    my @d = glob "$BASE/d/*";
    if (@d) {
        db_unlock();
        die "some job reports are still unread";
    }

    $db->{history} = [];
    db_unlock();
}

sub limit {
    my $l = shift;
    db_lock();
    $db->{LIMIT} = $l;
    db_unlock();
}

# ----------------------------------------------------------------------
# service routines

sub _printf_n {
    my ($f, $i) = @_;
    return unless $i;
    printf $f, $i;
}

sub prep {
    $qid = shift || 'default';
    $BASE = "$ENV{HOME}/.cache/jq-$qid";
    -d "$BASE/r" or system("mkdir -p $BASE/r $BASE/d");
    db_open();

    $options{logfile} ||= $ENV{JQ_LOGFILE} || '';
}

sub db_open {
    # 'new' == 'open' here
    my $dbfile = "$BASE/db";
    $db = DBM::Deep->new(
        file      => $dbfile,
        locking   => 1,
        autoflush => 1,
        num_txns  => 2,         # else begin_work won't!
    );
    $db->{LIMIT}   //= 1;
    $db->{running} //= 0;
}
sub db_lock   { $db->lock_exclusive(); }
sub db_unlock { $db->unlock(); }

sub _history_subset {
    my $min_rc = shift;
    my $db2    = $db->export();
    my @db2;
    for ( @{ $db2->{history} } ) {
        next if $_->{rc} < $min_rc;
        push @db2, $_;
    }
    return @db2;
}

sub interpret_exit_code {
    if ( $? == -1 ) {
        return sprintf "failed to execute: $!";
    } elsif ( $? & 127 ) {
        return sprintf "child died with signal %d, %s coredump", ( $? & 127 ), ( $? & 128 ) ? 'with' : 'without';
    } else {
        return sprintf "child exited with value %d", $? >> 8;
    }
}

sub gen_ts {
    my ( $s, $min, $h, $d, $m, $y ) = (localtime)[ 0 .. 5 ];
    $y += 1900; $m++;    # usual adjustments
    for ( $s, $min, $h, $d, $m ) {
        $_ = "0$_" if $_ < 10;
    }
    my $ts = "$y-$m-$d.$h:$min:$s";

    return $ts;
}

{
    my $oldout;
    my $olderr;

    sub redir {
        open( $oldout, ">&STDOUT" ) or die;
        open( $olderr, ">&STDERR" ) or die;
        open( STDIN,  "<",  "/dev/null" );
        open( STDOUT, ">>", "$BASE/r/$$.out" );
        open( STDERR, ">>", "$BASE/r/$$.err" );
    }

    sub un_redir {
        close(STDOUT);
        close(STDERR);
        open( STDOUT, ">&", $oldout ) or die;
        open( STDERR, ">&", $olderr ) or die;
    }
}

sub _log {
    my ( $lvl, $msg ) = @_;
    return if $lvl > ( $ENV{D} || 0 );

    say STDERR "[" . gen_ts . "] $msg";

    # log file also?
    return unless $options{logfile};
    open my $lfh, ">>", $options{logfile}
      or say STDERR "logfile '$options{logfile}' could not be opened: $!";
    say $lfh "[" . gen_ts . "] $msg";
}

# ----------------------------------------------------------------------
# usage

sub usage {
    say <DATA>;
    exit 1;
}

__DATA__

Usage: jq [options] [subcommand]
       jq [options] shell-command [args]

Options:
    -q                  queue ID to use (default: 'default')
    -s, -sleep N[mh]    sleep N (s|m|h) before queueing 'shell-command'
    -lf, -logfile PATH  also log messages to given PATH; also works by setting
                        JQ_LOGFILE env var

Subcommands:
    -h                  show this help
    -t, -tail           "tail" running and queued jobs' stdout and stderr files
    -f, -flush          print and "flush" completed jobs stdout and stderr files
    -c, -history        show "completed" jobs
    -e, -errors         show jobs with "errors"
    -purge              purge history records from DB
    -limit N            set limit to N for given queue
If no subcommand is given, print status for given queue.  If you supply more
than one subcommand, behaviour is undefined, so don't do that.

See docs for more, especially for details on '-q', '-s', etc.
