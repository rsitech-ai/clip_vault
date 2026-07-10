#!/usr/bin/perl

use strict;
use warnings;

use Errno qw(ECHILD EINTR EPERM ESRCH);
use Fcntl qw(FD_CLOEXEC F_SETFD);
use POSIX qw(
  WEXITSTATUS
  WIFEXITED
  WIFSIGNALED
  WNOHANG
  WTERMSIG
  _exit
  setpgid
);
use Time::HiRes qw(CLOCK_MONOTONIC clock_gettime sleep);

use constant INFRASTRUCTURE_STATUS => 125;
use constant GRACE_SECONDS         => 1.0;
use constant CLEANUP_SECONDS       => 2.0;
use constant POLL_SECONDS          => 0.01;

sub infrastructure_failure {
    my ($message) = @_;
    print STDERR "run_with_timeout: infrastructure failure: $message\n";
    exit INFRASTRUCTURE_STATUS;
}

sub child_setup_failure {
    my ($writer, $message) = @_;
    my $payload = "$message\n";
    syswrite $writer, $payload;
    _exit INFRASTRUCTURE_STATUS;
}

sub wait_for_setup_failure {
    my ($reader) = @_;
    my $message = q{};

    while (1) {
        my $buffer = q{};
        my $read_count = sysread $reader, $buffer, 4096;
        if (defined $read_count) {
            last if $read_count == 0;
            $message .= $buffer;
            next;
        }
        next if $! == EINTR;
        return (undef, "could not read child setup status: $!");
    }

    $message =~ s/\s+\z//;
    return ($message, undef);
}

sub wait_blocking_once {
    my ($pid) = @_;

    while (1) {
        my $waited = waitpid $pid, 0;
        return 1 if $waited == $pid;
        next if $waited == -1 && $! == EINTR;
        return 0;
    }
}

sub process_group_exists {
    my ($pgid) = @_;
    local $! = 0;
    return 1 if kill 0, -$pgid;
    return 1 if $! == EPERM;
    return 0;
}

sub signal_process_group {
    my ($signal, $pgid) = @_;
    local $! = 0;
    return 1 if kill $signal, -$pgid;
    return 1 if $! == ESRCH;
    print STDERR "run_with_timeout: infrastructure failure: could not send $signal to process group $pgid: $!\n";
    return 0;
}

sub map_child_status {
    my ($status) = @_;
    return WEXITSTATUS($status) if WIFEXITED($status);
    return 128 + WTERMSIG($status) if WIFSIGNALED($status);
    return INFRASTRUCTURE_STATUS;
}

@ARGV >= 2 or infrastructure_failure("usage: run_with_timeout <timeout-seconds> <command> [args ...]");
my $timeout_text = shift @ARGV;
$timeout_text =~ /\A(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)\z/
  or infrastructure_failure("timeout must be a positive number");
my $timeout_seconds = 0 + $timeout_text;
$timeout_seconds > 0
  or infrastructure_failure("timeout must be a positive number");

my $external_signal = 0;
$SIG{HUP}  = sub { $external_signal ||= 1 };
$SIG{INT}  = sub { $external_signal ||= 2 };
$SIG{TERM} = sub { $external_signal ||= 15 };

pipe my $setup_reader, my $setup_writer
  or infrastructure_failure("pipe failed: $!");
defined fcntl($setup_writer, F_SETFD, FD_CLOEXEC)
  or infrastructure_failure("could not configure setup pipe: $!");

my $started_at = clock_gettime(CLOCK_MONOTONIC);
my $deadline = $started_at + $timeout_seconds;
my $child_pid = fork;
defined $child_pid or infrastructure_failure("fork failed: $!");

if ($child_pid == 0) {
    close $setup_reader;
    $SIG{HUP} = $SIG{INT} = $SIG{TERM} = 'DEFAULT';

    setpgid(0, 0) == 0
      or child_setup_failure($setup_writer, "setpgid failed: $!");

    {
        no warnings 'exec';
        exec { $ARGV[0] } @ARGV;
        child_setup_failure($setup_writer, "exec '$ARGV[0]' failed: $!");
    }
}

close $setup_writer;
my ($setup_failure, $setup_read_failure) = wait_for_setup_failure($setup_reader);
close $setup_reader;

if (defined $setup_read_failure) {
    kill 'KILL', -$child_pid;
    kill 'KILL', $child_pid;
    wait_blocking_once($child_pid);
    infrastructure_failure($setup_read_failure);
}

if (length $setup_failure) {
    wait_blocking_once($child_pid)
      or infrastructure_failure("could not reap child after setup failure");
    infrastructure_failure($setup_failure);
}

my $child_reaped = 0;
my $child_status = 0;
my $result_status;
my $termination_reason = q{};
my $grace_deadline = 0;
my $cleanup_deadline = 0;
my $kill_sent = 0;

while (1) {
    my $now = clock_gettime(CLOCK_MONOTONIC);

    if (!$termination_reason && $external_signal) {
        $termination_reason = 'external signal';
        $result_status = 128 + $external_signal;
        $grace_deadline = $now + GRACE_SECONDS;
        signal_process_group($external_signal, $child_pid)
          or exit INFRASTRUCTURE_STATUS;
    }

    if (!$child_reaped) {
        my $waited = waitpid $child_pid, WNOHANG;
        if ($waited == $child_pid) {
            $child_status = $?;
            $child_reaped = 1;
        } elsif ($waited == -1 && $! == EINTR) {
            next;
        } elsif ($waited == -1) {
            infrastructure_failure("waitpid failed: $!");
        }
    }

    if (!$termination_reason && $child_reaped) {
        exit map_child_status($child_status);
    }

    $now = clock_gettime(CLOCK_MONOTONIC);
    if (!$termination_reason && $now >= $deadline) {
        # One final reap check gives a child that completed by the deadline its own status.
        my $waited = waitpid $child_pid, WNOHANG;
        if ($waited == $child_pid) {
            exit map_child_status($?);
        } elsif ($waited == -1 && $! == EINTR) {
            next;
        } elsif ($waited == -1) {
            infrastructure_failure("waitpid failed at deadline: $!");
        }
        next if $external_signal;

        $termination_reason = 'deadline';
        $result_status = 124;
        $grace_deadline = $now + GRACE_SECONDS;
        signal_process_group('TERM', $child_pid)
          or exit INFRASTRUCTURE_STATUS;
    }

    if ($termination_reason) {
        my $group_exists = process_group_exists($child_pid);
        exit $result_status if $child_reaped && !$group_exists;

        $now = clock_gettime(CLOCK_MONOTONIC);
        if (!$kill_sent && $now >= $grace_deadline) {
            signal_process_group('KILL', $child_pid)
              or exit INFRASTRUCTURE_STATUS;
            $kill_sent = 1;
            $cleanup_deadline = $now + CLEANUP_SECONDS;
        } elsif ($kill_sent && $now >= $cleanup_deadline) {
            infrastructure_failure("process group $child_pid survived KILL cleanup");
        }
    }

    sleep POLL_SECONDS;
}
