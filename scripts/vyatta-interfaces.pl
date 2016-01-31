#!/usr/bin/perl
#
# Module: vyatta-interfaces.pl
#
# **** License ****
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# A copy of the GNU General Public License is available as
# `/usr/share/common-licenses/GPL' in the Debian GNU/Linux distribution
# or on the World Wide Web at `http://www.gnu.org/copyleft/gpl.html'.
# You can also obtain it by writing to the Free Software Foundation,
# Free Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston,
# MA 02110-1301, USA.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2007 Vyatta, Inc.
# All Rights Reserved.
#
# Author: Stig Thormodsrud
# Date: November 2007
# Description: Script to assign addresses to interfaces.
#
# **** End License ****
#

use lib "/opt/vyatta/share/perl5/";
use Vyatta::Config;
use Vyatta::Misc qw(getInterfaces getIP);
use Vyatta::Interface;

use Getopt::Long;

use strict;
use warnings;

my $ETHTOOL     = '/sbin/ethtool';

my ($dev, $mac, $mac_update);
my %skip_interface;
my ($check_name, $show_names, $vif_name, $warn_name);
my ($check_up, $allowed_speed);
my (@speed_duplex, @addr_commit, @check_speed, @offload_option);

sub usage {
    print <<EOF;
Usage: $0 --dev=<interface> --check=<type>
       $0 --dev=<interface> --warn
       $0 --dev=<interface> --valid-mac=<aa:aa:aa:aa:aa:aa>
       $0 --dev=<interface> --valid-addr-commit={addr1 addr2 ...}
       $0 --dev=<interface> --speed-duplex=speed,duplex
       $0 --dev=<interface> --check-speed=speed,duplex
       $0 --dev=<interface> --allowed-speed
       $0 --dev=<interface> --isup
       $0 --dev=<interface> --offload-option={tcp-segmention,udp-fragmentation} {value}
       $0 --dev=<interface> --offload-option={generic-segmentation,generic-receive} {value}
       $0 --dev=<interface> --offload-option={scatter-gather} {value}
       $0 --show=<type>
EOF
    exit 1;
}

GetOptions(
    "valid-addr-commit=s{,}" => \@addr_commit,
    "dev=s"             => \$dev,
    "valid-mac=s"       => \$mac,
    "set-mac=s"         => \$mac_update,
    "check=s"           => \$check_name,
    "show=s"            => \$show_names,
    "skip=s"            => sub {$skip_interface{$_[1]} = 1},
    "vif=s"             => \$vif_name,
    "warn"              => \$warn_name,
    "isup"              => \$check_up,
    "speed-duplex=s{2}" => \@speed_duplex,
    "check-speed=s{2}"  => \@check_speed,
    "allowed-speed"     => \$allowed_speed,
    "offload-option=s{2}" => \@offload_option,
) or usage();

is_valid_addr_commit($dev, @addr_commit)  if (@addr_commit);
is_valid_mac($mac, $dev)                  if ($mac);
update_mac($mac_update, $dev)             if ($mac_update);
is_valid_name($check_name, $dev)          if ($check_name);
exists_name($dev)                         if ($warn_name);
show_interfaces($show_names)              if ($show_names);
is_up($dev)                               if ($check_up);
set_speed_duplex($dev, @speed_duplex)     if (@speed_duplex);
check_speed_duplex($dev, @check_speed)    if (@check_speed);
allowed_speed($dev)                       if ($allowed_speed);
set_offload_option($dev, @offload_option) if (@offload_option);
exit 0;

sub is_ip_configured {
    my ($intf, $ip) = @_;
    my $found = grep {$_ eq $ip} getIP($intf);
    return ($found > 0);
}

sub is_ipv4 {
    return index($_[0],':') < 0;
}

sub is_up {
    my $name = shift;
    my $intf = new Vyatta::Interface($name);

    die "Unknown interface type for $name" unless $intf;

    exit 0 if ($intf->up());
    exit 1;
}

sub update_mac {
    my ($mac, $name) = @_;
    my $intf = new Vyatta::Interface($name);
    $intf or die "Unknown interface name/type: $name\n";

    # maybe nothing needs to change
    my $oldmac = $intf->hw_address();
    exit 0 if (lc($oldmac) eq lc($mac));

    # try the direct approach
    if (system("ip link set $name address $mac") == 0) {
        exit 0;
    } elsif ($intf->up()) {

        # some hardware can not change MAC address if up
        system "ip link set $name down"
            and die "Could not set $name down\n";
        system "ip link set $name address $mac"
            and die "Could not set $name address\n";
        system "ip link set $name up"
            and die "Could not set $name up\n";
    } else {
        die "Could not set mac address for $name\n";
    }

    exit 0;
}

sub is_vrrp_mac {
    my @octets = @_;
    return 1 if (   hex($octets[0]) == 0
                 && hex($octets[1]) == 0
                 && hex($octets[2]) == 94
                 && hex($octets[3]) == 0
                 && hex($octets[4]) == 1);
    return 0;
}

sub is_valid_mac {
    my ($mac, $intf) = @_;
    my @octets = split /:/, $mac;

    ($#octets == 5) or die "Error: wrong number of octets: $#octets\n";

    ((hex($octets[0]) & 1) == 0) or die "Error: $mac is a multicast address\n";

    is_vrrp_mac(@octets) and die "Error: $mac is a vrrp mac address\n";

    my $sum = 0;
    $sum += hex($_) foreach @octets;
    ($sum != 0) or die "Error: zero is not a valid address\n";

    exit 0;
}

# Validate the set of address values configured on an interface at commit
# Check that full set of address address values are consistent.
#  1. Interface may not be part of bridge or bonding group
#  2. Can not have both DHCP and a static IPv4 address.
sub is_valid_addr_commit {
    my ($ifname, @addrs) = @_;
    my $intf = new Vyatta::Interface($ifname);
    $intf or die "Unknown interface name/type: $ifname\n";

    my $config = new Vyatta::Config;
    $config->setLevel($intf->path());

    my $bridge = $config->returnValue("bridge-group bridge");
    die "Can't configure address on interface that is port of bridge.\n"
        if (defined($bridge));

    my $bond = $config->returnValue("bond-group");
    die "Can't configure address on interface that is slaved to bonding interface.\n"
        if (defined($bond));

    my $addrmap = Vyatta::Interface::get_cfg_addresses();

    my ($dhcp, $static_v4);
    foreach my $addr (@addrs) {
        next if ($addr eq 'dhcpv6');

        if ($addr eq 'dhcp') {
            $dhcp = 1;
            next;
        }

        my $intfs = $addrmap->{$addr};
        if ($intfs && scalar(@{$intfs}) > 1) {
            die "Duplicate address $addr used on interfaces: ",join(',', @${intfs}), "\n";
        }

        $static_v4 = 1
            if (is_ipv4($addr));
    }

    die "Can't configure static IPv4 address and DHCP on the same interface.\n"
        if ($static_v4 && $dhcp);

    exit 0;
}

# Is interface currently in admin down state?
sub is_intf_down {
    my $name = shift;
    my $intf = new Vyatta::Interface($name);

    return 1 unless $intf;
    return !$intf->up();
}

sub is_valid_name {
    my ($type, $name) = @_;
    die "Missing --dev argument\n" unless $name;

    my $intf = new Vyatta::Interface($name);
    die "$name does not match any known interface name type\n"
        unless $intf;

    my $vif = $intf->vif();
    die "$name is the name of VIF interface\n","Need to use \"interface ",$intf->physicalDevice()," vif $vif\"\n"
        if $vif;

    die "$name is a ", $intf->type(), " interface not an $type interface\n"
        if ($type ne 'all' and $intf->type() ne $type);

    die "$type interface $name does not exist on system\n"
        unless grep {$name eq $_} getInterfaces();

    exit 0;
}

sub exists_name {
    my $name = shift;
    die "Missing --dev argument\n" unless $name;

    warn "interface $name does not exist on system\n"
        unless grep {$name eq $_} getInterfaces();
    exit 0;
}

# generate one line with all known interfaces (for allowed)
sub show_interfaces {
    my $type = shift;
    my @interfaces = getInterfaces();
    my @match;

    foreach my $name (@interfaces) {
        my $intf = new Vyatta::Interface($name);
        next unless $intf;		# skip unknown types
        next if $skip_interface{$name};
        next unless ($type eq 'all' || $type eq $intf->type());
        if ($intf->vrid()){
            push @match, $name; # add all vrrp interfaces
        } elsif ($vif_name) {
            next unless $intf->vif();
            push @match, $intf->vif()
                if ($vif_name eq $intf->physicalDevice());
        } else {
            push @match, $name
                unless $intf->vif()
                and $type ne 'all';
        }
    }
    print join(' ', @match), "\n";
}

# Determine current values for autoneg, speed, duplex
sub get_ethtool {
    my $dev = shift;

    open(my $ethtool, '-|', "$ETHTOOL $dev 2>&1")
        or die "ethtool failed: $!\n";

    # ethtool produces:
    #
    # Settings for eth1:
    # Supported ports: [ TP ]
    # ...
    # Speed: 1000Mb/s
    # Duplex: Full
    # ...
    # Auto-negotiation: on
    my ($rate, $duplex);
    my $autoneg = 0;
    while (<$ethtool>) {
        chomp;
        return if (/^Cannot get device settings/);

        if (/^\s+Speed: (\d+)Mb/) {
            $rate = $1;
        } elsif (/^\s+Duplex:\s(.*)$/) {
            $duplex = lc $1;
        } elsif (/^\s+Auto-negotiation: on/) {
            $autoneg = 1;
        }
    }
    close $ethtool;
    return ($autoneg, $rate, $duplex);
}

sub set_speed_duplex {
    my ($intf, $nspeed, $nduplex) = @_;
    die "Missing --dev argument\n" unless $intf;

    # read old values to avoid meaningless speed changes
    my ($autoneg, $ospeed, $oduplex) = get_ethtool($intf);

    if (defined($autoneg) && $autoneg == 1) {

        # Device is already in autonegotiation mode
        return if ($nspeed eq 'auto');
    } elsif (defined($ospeed) && defined($oduplex)) {

        # Device has explicit speed/duplex but they already match
        return if (($nspeed eq $ospeed) && ($nduplex eq $oduplex));
    }

    my $cmd = "$ETHTOOL -s $intf";
    if ($nspeed eq 'auto') {
        $cmd .= " autoneg on";
    } else {
        $cmd .= " speed $nspeed duplex $nduplex autoneg off";
    }

    exec $cmd;
    die "exec of $ETHTOOL failed: $!";
}

# Check if speed and duplex value is supported by device
sub is_supported_speed {
    my ($dev, $speed, $duplex) = @_;

    my $wanted = sprintf("%dbase%s/%s", $speed,($speed == 2500) ? 'X' : 'T', ucfirst($duplex));

    open(my $ethtool, '-|', "$ETHTOOL $dev 2>/dev/null")
        or die "ethtool failed: $!\n";

    # ethtool output:
    #
    # Settings for eth1:
    #	Supported ports: [ TP ]
    #	Supported link modes:   10baseT/Half 10baseT/Full
    #	                        100baseT/Half 100baseT/Full
    #	                        1000baseT/Half 1000baseT/Full
    #   Supports auto-negotiation: Yes
    my $mode;
    while (<$ethtool>) {
        chomp;
        if ($mode) {
            last unless /^\t /;
        } else {
            next unless /^\tSupported link modes: /;
            $mode = 1;
        }

        return 1 if /$wanted/;
    }

    close $ethtool;
    return;
}

# Validate speed and duplex settings prior to commit
sub check_speed_duplex {
    my ($dev, $speed, $duplex) = @_;

    # most basic and default case
    exit 0 if ($speed eq 'auto' && $duplex eq 'auto');

    die "If speed is hardcoded, duplex must also be hardcoded\n"
        if ($duplex eq 'auto');

    die "If duplex is hardcoded, speed must also be hardcoded\n"
        if ($speed eq 'auto');

    die "Speed $speed, duplex $duplex not supported on $dev\n"
        unless is_supported_speed($dev, $speed, $duplex);

    exit 0;
}

# Produce list of valid speed values for device
sub allowed_speed {
    my ($dev) = @_;

    open(my $ethtool, '-|', "$ETHTOOL $dev 2>/dev/null")
        or die "ethtool failed: $!\n";

    my %speeds;
    my $first = 1;
    while (<$ethtool>) {
        chomp;

        if ($first) {
            next unless s/\tSupported link modes:\s//;
            $first = 0;
        } else {
            last unless /^\t /;
        }

        foreach my $val (split / /) {
            $speeds{$1} = 1 if $val =~ /(\d+)base/;
        }
    }

    close $ethtool;
    print 'auto ', join(' ', sort keys %speeds), "\n";
}

sub get_offload_option {
    my ($dev, $option) = @_;
    my $val;
    my $ethtool_option;

    if ($option ne 'scatter-gather') {
        $ethtool_option = "$option-offload";
    } else {
        $ethtool_option = $option;
    }

    open(my $ethtool, '-|', "$ETHTOOL -k $dev 2>&1") or die "ethtool failed: $!\n";
    while (<$ethtool>) {
        next if ($_ !~ m/$ethtool_option:/);
        chomp;
        $val = (split(/: /, $_))[1];
    }
    close $ethtool;
    return $val;

}

sub set_offload_option {
    my ($intf, $option, $nvalue) = @_;
    die "Missing --dev argument\n" unless $intf;

    my $ovalue = get_offload_option($intf, $option);

    my %ethtool_opts = (
        'generic-receive'      => 'gro',
        'generic-segmentation' => 'gso',
        'tcp-segmentation'     => 'tso',
        'udp-fragmentation'    => 'ufo',
        'scatter-gather'       => 'sg',
    );

    if (defined($nvalue) && $nvalue ne $ovalue) {
        my $cmd = "$ETHTOOL -K $intf $ethtool_opts{$option} $nvalue";

        system($cmd);
        if ($? >> 8) {
            die "Offload option for $option is not supported on $intf\n";
        }
    }

}

