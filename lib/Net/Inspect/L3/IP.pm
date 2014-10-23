
############################################################################
# RawIP
# reassembles fragmented IP packets
############################################################################

use strict;
use warnings;
package Net::Inspect::L3::IP;
use base 'Net::Inspect::Flow';
use fields qw(frag frag_timeout);
use Net::Inspect::Debug;
use Socket;

# field frag: hash indexed by {ip.id,saddr,daddr} with values
# [ $pos, \@fragments, $expire ]
#   $pos - up to which position defragmentation is done
#   @fragments - list of fragments [final,offset,data]
#      final: true if this is the last fragment
#   $expire - if no more fragments are received after $expire the
#      packet gets discarded


sub new {
    my ($class,$flow,%args) = @_;
    if ( ref($flow) eq 'ARRAY' ) {
	my $f = Net::Inspect::Flow->new_any('pktin');
	$f->attach($_) for @$flow;
	$flow = $f;
    }
    my $self = $class->SUPER::new($flow);
    $self->{frag} = {};
    $self->{frag_timeout} = $args{timeout} || 60;
    return $self;
};

############################################################################
# process single raw packet, call ip-version specific function
############################################################################
sub pktin {
    my Net::Inspect::L3::IP $self = shift;
    my ($data,$time) = @_;

    # check IP version
    my $ver = unpack('C',$data) >> 4;
    if ($ver == 4) {
	$self->pktin4($data,$time);
	return 1;
    } elsif ($ver == 6) {
	# no IPv6 implemented yet
	trace("cannot handle ipv6");
	return 0;
    } else {
	trace("bad IP version $ver");
	return 0;
    }
}

############################################################################
# defragment ipv4 raw packets
############################################################################
sub pktin4 {
    my Net::Inspect::L3::IP $self = shift;
    my ($data,$time) = @_;

    # parse IPv4 header
    my ($vi,$qos,$len,$id,$ffo,$ttl,$proto,$chksum,$saddr,$daddr) =
	unpack('CCnnnCCna4a4',$data);

    # get payload
    my $ihl = $vi & 0xf;
    if ( $ihl<5 ) {
	trace("bad packet ihl=$ihl");
	return;
    }
    if ( $len>length($data)) {
	trace("short packet len=".length($data)."/$len");
	return;
    }
    substr($data,$len) = '';
    my $buf = substr($data,$ihl*4);

    my $fo = ( $ffo & 0x1fff ) << 3; # fragment offset
    my $mf = ( $ffo >> 13 ) & 0x01;  # more fragments
    my $fragments;
    if ( ! $mf ) {
	# last fragment
	if ( $fo == 0 ) {
	    # not fragmented, done
	    if ( delete $self->{frag}{$id,$saddr,$daddr} ) {
		# there were fragments for this packet!
		trace("discarding fragments %s->%s because of no-fragments replacement",
		    inet_ntoa($saddr),inet_ntoa($daddr));
	    }
	    debug("forward ".length($buf)." bytes");
	    return $self->{upper_flow}->pktin( $buf, {
		time  => $time,
		saddr => inet_ntoa($saddr),
		daddr => inet_ntoa($daddr),
		proto => $proto,
		id    => $id,
		ttl   => $ttl,
		qos   => $qos,
	    });
	} else {
	    $fragments = $self->{frag}{$id,$saddr,$daddr} ||= [0,[]];
	    push @{$fragments->[1]}, [ 1,$fo,$buf ];
	    debug("final fragment offset=$fo len=%d",length($buf));
	}
    } else {
	$fragments = $self->{frag}{$id,$saddr,$daddr} ||= [0,[]];
	push @{ $fragments->[1] },[ 0,$fo,$buf ];
	debug("fragment offset=$fo len=%d",length($buf));
    }
    $fragments or return; # something wrong

    if (@{ $fragments->[1] } >1) {
	# merge if possible
	my @f = sort { $a->[1] <=> $b->[1] } @{ $fragments->[1] };
	my $fq = $fragments->[1] = [ shift(@f) ];
	while (@f) {
	    my $f = shift(@f);
	    my $diff = $f->[1] - ( $fq->[-1][1] + length($fq->[-1][2]) );
	    debug("merge fragments: %d - (%d+%d) -> %d", $f->[1], $fq->[-1][1],
		length($fq->[-1][2]),$diff);
	    if ($diff == 0) {
		# merge fragments
		$fq->[-1][2].= $f->[2];
		$fragments->[0]++;
	    } elsif ( $diff>0 ) {
		# still missing fragment
		push @f,$f
	    } else {
		# overlapping fragments -> discard
		trace( "discarding overlapping fragments $id/%s->%s",
		    inet_ntoa($saddr),inet_ntoa($daddr));
		return;
	    }
	}
    }

    if ( @{ $fragments->[1] } == 1      # all fragments together
	and $fragments->[1][0][0]       # final fragment received
	and $fragments->[1][0][1] == 0  # offset == 0, eg start of packet
	) {
	delete $self->{frag}{$id,$saddr,$daddr};
	debug("forward %d bytes assembled from %d fragments",
	    length($fragments->[1][0][2]),$fragments->[0]);
	return $self->{upper_flow}->pktin( $fragments->[1][0][2], {
	    time  => $time,
	    saddr => $saddr,
	    daddr => $daddr,
	    proto => $proto,
	    id    => $id,
	    ttl   => $ttl,
	    qos   => $qos,
	    fragments => $fragments->[0],
	});
    }

    # set time for last fragment and expire old fragments
    $fragments->[2] = $time + $self->{frag_timeout};
    my $fdb = $self->{frag};
    my @k = keys %$fdb;
    if ( @k > 1 ) {
	for (@k) {
	    $fdb->{$_}[2] >= $time and next;
	    delete $fdb->{$_} # expired
	}
    }
}

1;


__END__

=head1 NAME

Net::Inspect::L3::IP - get raw IP packets, reassemble fragments

=head1 SYNOPSIS

 my $raw = Net::Inspect::L3::IP->new($tcp);
 $raw->pktin($data,$timestamp);

=head1 DESCRIPTION

Gets Raw-IP packets via C<pktin> hook, extracts meta-data, reassembles
fragmented packets and calls C<pktin> hook on attached flows, once for
each full packet.

Provides the hooks required by C<Net::Inspect::L2::Pcap>.
Usually C<Net::Inspect::L4::TCP> or similar are used as upper flow.

Constructor:

=over 4

=item new(%args)

The only used argument is %args is C<timeout>, which specifies when timeout in
seconds, after which the next fragment of a packet must be received.
Defaults to 60.

=back

Hooks provided:

=over 4

=item pktin($data,$timestamp)

=back

Hooks called:

=over 4

=item pktin($ip_data,\%meta)

The following meta data are given:

=over 8

=item time

time when the last fragment of the packet was received.
Like time_t, but double.

=item saddr, daddr

the addresses of the sender and destination of the packet

=item proto

protocol of the packet

=item id

id of the packet

=item qos

QoS flags of the packet

=item ttl

TTL counter of the packet

=item fragments

number of fragments or undef if packet wasn't fragmented

=back

=back

=head1 LIMITS

for now only IPv4 is implemented
