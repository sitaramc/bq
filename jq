#!/usr/bin/perl
use strict;
use warnings;
use 5.10.0;
use Data::Dumper;
$Data::Dumper::Terse = 1;
$Data::Dumper::Indent = 0;

use DBM::Deep;
use Cwd;

# for now, q size is 1 and each job is independent; no IPC

@ARGV = qw(-status) unless @ARGV;
usage() if $ARGV[0] eq '-h';

# ----------------------------------------------------------------------
# kinda sorta globals
my ($db);
my $BASE = "$ENV{HOME}/.cache/jq";
-d "$BASE/r" or system("mkdir -p $BASE/r $BASE/d");
db_open();    # may end up waiting for a looooong time

# ----------------------------------------------------------------------
# main

if ($ARGV[0] eq '-status') {
    status();
} elsif ( $ARGV[0] eq '-t' ) {
    tail();     # tail on in-progress output
} elsif ( $ARGV[0] eq '-f' ) {
    flush();    # cat 'done' files, unlink them
} elsif ( $ARGV[0] eq '-c' ) {
    history(0); # print history, all jobs
} elsif ( $ARGV[0] eq '-e' ) {
    history(1); # print history, failed jobs only
} elsif ( $ARGV[0] eq '-purge' ) {
    purge();
} else {
    queue(@ARGV);
}

exit 0;

sub status {
    db_lock();

    my @d = glob("$BASE/d/*.err");    # we assume count of *.err and *.out is same
    my @r = glob("$BASE/r/*.err");
    my $qc = scalar( @{ $db->{queued_pids} || [] } );

    printf STDERR ( "WARNING! %d jobs queued, but running (%d) < LIMIT (%d)\n", $qc, $db->{running}, $db->{LIMIT} )
      if $qc and $db->{LIMIT} > $db->{running};

    printf "%7d queued jobs\n",  $qc;
    printf "%7d running\n",      $db->{running};
    # printf "%7d LIMIT\n",        $db->{LIMIT};
    printf "%7d unflushed jobs\n", scalar( @d );
    say "";
    printf "%7d completed jobs\n", scalar( @{ $db->{history} || [] } );
    printf "%7d errors\n", scalar( _history_subset(1) );

    db_unlock();
    say "\n(run 'jq -h' for help)\n";
}

# the workhorse of this program
sub queue {
    exit 0 if fork();   # hah!  no need to use '&' anymore :)
    # unkillable!  well for -15 anyway not for -9
    $SIG{TERM} = sub { "phhht!"; };

    # explicit sleep if asked
    if ($_[0] eq '-s' and $_[1] =~ /^(\d+)([smh]?)$/) {
        my %mult = (s => 1, m => 60, h => 3600);
        sleep $1 * $mult{ $2 || 's' };
        shift; shift;
    }

    redir();    # redirect STDOUT and STDERR right away

    # and *then* throw your hat in the ring
    my $queued = gen_ts();
    my $sleep_time = 1;
    _log( 0, "[q $$] " . join(" ", @_) );

    # the waiting game

    db_lock();
    push @{ $db->{queued_pids} }, $$;
    while (queue_full() or not my_turn()) {
        db_unlock();
        _log( 1, "[w $$] $sleep_time" );
        sleep $sleep_time; $sleep_time %= 31; $sleep_time *= 2;
        db_lock();
    }
    # reserve our slot and get out
    shift @{ $db->{queued_pids} };
    $db->{running}++;
    db_unlock();

    # the running game

    _log( 0, "[s $$] " . join(" ", @_) );
    my $started = gen_ts();
    my ($rc, $es) = run($queued, @_);
    my $completed = gen_ts();
    _log( 0, "[e $$] rc=$rc, es=$es" );

    # the end game

    db_lock();
    $db->{running}--;
    push @{ $db->{history} }, {
        pwd => getcwd(),
        cmd => \@_,
        rc => $rc,
        es => $es,
        queued => $queued,
        started => $started,
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
    my $es = ($rc == 0 ? 0 : interpret_exit_code());
    say STDERR "";
    system("mv $BASE/r/$$.out $BASE/r/$$.err $BASE/d");

    return($rc, $es);
}

sub tail {
    for my $f (glob "$BASE/r/*") {
        say "----8<---- $f";
        say `tail $f`;
    }
}

sub flush {
    for my $f (glob "$BASE/d/*") {
        say "----8<---- $f";
        say `cat $f`;
        unlink $f;
    }
}

sub history {
    my $min_rc = shift;
    my @db2 = _history_subset($min_rc);
    # XXX needs to be refined later
    for ( @db2 ) {
        next if $_->{rc} < $min_rc;
        say Dumper $_->{cmd} if $ENV{D};
        say "cd $_->{pwd}; " . join(" ", @{ $_->{cmd} });
        say $_->{completed} . "\t" . $_->{rc} . "\t" . $_->{es};
        say "";
    }
}

sub purge {
    db_lock();
    if ($db->{running}) {
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

# ----------------------------------------------------------------------
# service routines

sub db_open {
    # 'new' == 'open' here
    my $dbfile = "$BASE/db";
    $db = DBM::Deep->new(
        file      => $dbfile,
        locking   => 1,
        autoflush => 1,
        num_txns  => 2,                          # else begin_work won't!
    );
    $db->{LIMIT} //= 1;
    $db->{running} //= 0;
}
sub db_lock { $db->lock_exclusive(); }
sub db_unlock { $db->unlock(); }

sub _history_subset {
    my $min_rc = shift;
    my $db2 = $db->export();
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
        open($oldout, ">&STDOUT") or die;
        open($olderr, ">&STDERR") or die;
        open( STDIN, "<", "/dev/null");
        open( STDOUT, ">>", "$BASE/r/$$.out" );
        open( STDERR, ">>", "$BASE/r/$$.err" );
    }

    sub un_redir {
        close(STDOUT);
        close(STDERR);
        open(STDOUT, ">&", $oldout) or die;
        open(STDERR, ">&", $olderr) or die;
    }
}

sub _log {
    my ( $lvl, $msg ) = @_;
    return if $lvl > ( $ENV{D} || 0 );
    say STDERR "[" . gen_ts . "] $msg";
}


# ----------------------------------------------------------------------
# usage

sub usage {
    say <DATA>;
    exit 1;
}

__DATA__

Usage: jq [-status|-t|-f|-c|-e|-purge]
       jq [-s time] command [args]

-status: if no arguments are supplied, '-status' is implied
-t: "tail" running and queued jobs' stdout and stderr files
-f: print and "flush" completed jobs stdout and stderr files
-c: show "completed" jobs
-e: show jobs with "errors"

-purge: purge everything (assuming no jobs are running and no outputs pending
    flush)

-s: time is an integer, followed optionally by 's', 'm', or 'h' (no spaces).
    The job will first sleep for that duration and *then* get queued.
