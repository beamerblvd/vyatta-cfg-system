#!/usr/bin/perl
#
# Module: vyos-dhcpv4-client.pl
# Configures IPv4 addresses on interfaces using DHCPv4.
#
# Copyright (C) 2016 VyOS maintainers and contributors
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# Author: Nick Williams <nicholas+vyos@nicholaswilliams.net>
# Date: January 2016
#
# **** End License ****
#
#

use strict;
use warnings;

use lib "/opt/vyatta/share/perl5/";
use Getopt::Long;
use Sys::Hostname;
use Vyatta::Config;
use Vyatta::Interface;
use VyOS::DHCP qw(config_edit_interface_v4 config_remove_interface_v4
                  client_rebind_interface client_release_interface
                  client_start_if_stopped client_get_lease
                  client_is_running);

sub usage {
    print <<'USAGE';
Usage: $0 --ifname=ethX --{start|stop|renew|release|get-leased-ip}

--start    Configure and start DHCP services for the interface
--stop     Stop DHCP services and delete all configuration for the interface
--renew    Reconfigure and restart DHCP services for the interface
--release  Stop DHCP services but leave all configuration for the interface
USAGE
    exit 1;
}

#
# Main Section
#

my $start_flag;     # Configure and start DHCP services for the interface
my $stop_flag;      # Stop DHCP services and delete all configuration for the interface
my $renew_flag;     # Reconfigure and restart DHCP services for the interface
my $release_flag;   # Stop DHCP services but leave all configuration for the interface
my $ifname;

GetOptions(
    "start"             => \$start_flag,
    "stop"              => \$stop_flag,
    "renew"             => \$renew_flag,
    "release"           => \$release_flag,
    "get-leased-ip"     => \$get_lease_flag,
    "ifname=s"          => \$ifname,
) or usage();

if (!$ifname) {
    die "Error: Interface name must be specified with --ifname parameter!\n";
}

if (!$start_flag and !$stop_flag and !$renew_flag and !$release_flag and !$get_lease_flag) {
    die "Error: One of --start, --stop, --renew, or --release must be specified!\n";
}

my $intf = new Vyatta::Interface($ifname) or die "Error: Cannot find interface $ifname!\n";

sub configure_interface {
    my $config = new Vyatta::Config;

    $config->setLevel("system");
    my $host_name = $config->returnValue("host-name");
    my $domain_name = $config->returnValue("domain-name");

    my $mtu = $intf->mtu();

    my $send_main_config = 0;
    my @main_config = ();
    my @version_config = (
        'ipv4',
        'dhcp',
        'option subnet_mask',
        'option broadcast_address',
        'option routers',
        'option domain_name_servers'
    );

    if (defined($hostname)) {
        $send_main_config = 1;
        push @main_config, "hostname $hostname";
    }
    if (!defined($domainname)) {
        push @version_config, 'option domain_search';
        push @version_config, 'option domain_name';
    } else {
        push @version_config, 'nooption domain_search';
        push @version_config, 'nooption domain_name';
    }
    if (!$mtu) {
        push @version_config, 'option interface_mtu';
    } else {
        push @version_config, 'nooption interface_mtu';
    }

    # TODO: Uncomment this when config improvements are merged
    # my $level = $intf->path() . ' dhcp-options';
    # $config->setLevel($level);
    # $rapid = $config->exists('rapid-commit') && $config->returnValue('rapid-commit') eq 'enable'
    #     ? 'dhcp_option' : 'dhcp_nooption';
    # push @version_config, "$rapid rapid_commit";

    if ($send_main_config) {
        config_edit_interface_v4($ifname, @main_config, @version_config);
    } else {
        config_edit_interface_v4($ifname, -1, @version_config);
    }
}

if ($release_flag) {
    client_is_running() and client_release_interface($ifname);
}

if ($start_flag or $renew_flag) {
    configure_interface();
    client_start_if_stopped() or client_rebind_interface($ifname);
}

if ($stop_flag) {
    config_remove_interface_v4($ifname);
    client_is_running() and client_rebind_interface($ifname);
}

if ($get_lease_flag) {
    my %lease = client_get_lease($ifname);
    print "$lease{'ip_address'}";
}
