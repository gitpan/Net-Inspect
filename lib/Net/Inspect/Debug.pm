use strict;
use warnings;
package Net::Inspect::Debug;

use base 'Exporter';
our @EXPORT = qw(debug trace );
our @EXPORT_OK = qw($DEBUG %TRACE xdebug xtrace);

our $DEBUG = 0;
sub debug {
    $DEBUG or return;
    my $msg = shift;
    $msg = sprintf($msg,@_) if @_;
    if ( $msg !~ m{^\S+:} ) {
	my ($pkg,$func,$sub) = (caller(1))[0,1,3];
	my $line             = (caller(0))[2];
	$sub =~s{^main::}{} if $sub;
	$sub ||= 'Main';
	$msg = "$sub\[$line]: ".$msg;
    }

    $msg =~s{^}{DEBUG: }mg;
    print STDERR $msg,"\n";
}

sub xdebug {
    $DEBUG or return;
    my $obj = shift;
    my $msg = shift;
    unshift @_,"[$obj] $msg";
    goto &debug;
}

our %TRACE;
sub trace {
    %TRACE or return;
    my $pkg = lc((caller(0))[0]);
    $pkg =~s/.*:://;
    $TRACE{$pkg} or $TRACE{'*'} or return;

    my $msg = shift;
    $msg = sprintf($msg,@_) if @_;
    $msg =~s{\n}{\n  *  }g;
    $msg =~s{\A}{[$pkg]: };
    print STDERR $msg,"\n";
}

sub xtrace {
    %TRACE or return;
    my $obj = shift;
    my $msg = shift;
    unshift @_, "[$obj] $msg";
    goto &trace;
}


1;
__END__

=head1 NAME

Net::Inspect::Debug - provides debugging facilities for Net::Inspect library

=head1 DESCRIPTION

the following functionality is provided:

=over 4

=item debug(msg,[@args])

if C<$DEBUG> is set prints out debugging message, prefixed with "DEBUG" and info
about calling function and code line. If C<@args> are given C<msg> is considered
and format string which will be combined with C<@args> to the final message.

This function is exported by default.

=item xdebug(object,...)

Same es debug, but prefixed with object.
Usually overwritten in classes to show info about object.

This function can be exported on demand.

=item trace(msg,[@args])

if C<$TRACE{'*'}> or C<$TRACE{$$pkg}>' is set prints out trace message, prefixed
with "[$pkg]". C<$pkg> is the last part of the package name, where trace got
called.
If C<@args> are given C<msg> is considered and format string which will be
combined with C<@args> to the final message.

This function is exported by default.

=item xtrace(object,...)

Same es trace, but prefixed with object.
Usually overwritten in classes to show info about object.

This function can be exported on demand.

=item $DEBUG

If true debugging messages will be print.
Can be explicitly imported, but is not exported by default.

=item %TRACE

If true for '*' or C<$pkg> (see C<trace>) trace messages will be print.
Can be explicitly imported, but is not exported by default.

=back

1;
