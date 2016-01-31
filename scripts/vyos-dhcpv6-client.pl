#!/usr/bin/perl
#
# Module: vyos-dhcpv6-client.pl
# Configures IPv6 addresses on interfaces using DHCPv6.
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
use Math::BigInt;
use Sys::Hostname;
use Vyatta::Config;
use Vyatta::Interface;
use VyOS::DHCP qw(config_edit_interface_v6 config_remove_interface_v6
                  client_rebind_interface client_release_interface
                  client_start_if_stopped client_get_lease
                  client_is_running);

sub usage {
    print <<'USAGE';
Usage: $0 --ifname=ethX --{start|stop|renew|release}

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
    "ifname=s"          => \$ifname
) or usage();

if (!$ifname) {
    die "Error: Interface name must be specified with --ifname parameter!\n";
}

if (!$start_flag and !$stop_flag and !$renew_flag and !$release_flag) {
    die "Error: One of --start, --stop, --renew, or --release must be specified!\n";
}

my $intf = new Vyatta::Interface($ifname) or die "Error: Cannot find interface $ifname!\n";

sub configure_interface {
    my $config = new Vyatta::Config;

    $config->setLevel("system");
    my $host_name = $config->returnValue("host-name");
    my $domain_name = $config->returnValue("domain-name");

    my $send_main_config = 0;
    my @main_config = ();
    my @version_config = (
        'ipv6',
        'dhcp6',
        'dhcp6_option name_servers'
    );

    if (defined($hostname)) {
        $send_main_config = 1;
        push @main_config, "hostname $hostname";
    }
    if (!defined($domainname)) {
        push @version_config, 'dhcp6_option domain_search';
    } else {
        push @version_config, 'dhcp6_nooption domain_search';
    }

    my $level = $intf->path() . ' dhcpv6-options';
    $config->setLevel($level);

    if ($config->exists('duid')) {
        my $duid = $config->returnValue('duid');
        push @version_config, "clientid $duid";
    }

    # TODO: Uncomment this when config improvements are merged
    # $rapid = $config->exists('rapid-commit') && $config->returnValue('rapid-commit') eq 'enable'
    #     ? 'dhcp6_option' : 'dhcp6_nooption';
    # push @version_config, "$rapid rapid_commit";

    my $temporary = $config->exists('temporary');
    my $parameters_only = $config->exists('parameters-only');
    my $prefix_delegation = 0;
    # TODO: Uncomment this when config improvements are merged
    # my $prefix_delegation = $config->exists('prefix-delegation');

    if (($temporary and $parameters_only) or
        ($temporary and $prefix_delegation) or
        ($parameters_only and $prefix_delegation)) {
        die('Error: The prefix-delegation, parameters-only, and temporary configurations are mutually exclusive!');
    }

    if ($temporary) {
        push @version_config, 'ia_ta';
    } elsif ($parameters_only) {
        # TODO: Don't know
    # TODO: Uncomment this when config improvements are merged
    # } elsif ($prefix_delegation) {
    #     push @version_config, 'ia_na 1';

    #     $two = new Math::BigInt('2');
    #     $max = new Math::BigInt('128');

    #     $level .= ' prefix-delegation';
    #     $config->setLevel($level);

    #     $prefix_length = $config->exists('prefix-length') ?
    #         Math::BigInt($config->returnValue('prefix-length')) : 0;
    #     $prefix_addresses = $prefix_length ? $two ** ($max - $prefix_length) : 0;

    #     $option = 'ia_pd 2' . ($prefix_length ? "/::/$prefix_length" : '');

    #     $total_addresses = 0;
    #     $i = 0;
    #     foreach my $pd_ifname ($config->listNodes("interface")) {
    #         new Vyatta::Interface($pd_ifname) or die "Error: Cannot find delegation interface $pd_ifname!\n";
    #         $i++;

    #         $sublevel = "interface $pd_ifname"
    #         my $pd_length = $config->exists("$sublevel prefix-length") ?
    #             Math::BigInt($config->returnValue("$sublevel prefix-length")) : 0;

    #         if ($prefix_length and $pd_length) {
    #             $option .= " $pd_ifname/$i/$pd_length";
    #             $total_addresses += $two ** ($max - Math::BigInt->new($prefix));
    #         } else {
    #             $option .= " $pd_ifname";
    #             if ($pd_length) {
    #                 warn "Warning: Subdelegated prefix-length ignored due to no master prefix-length.\n";
    #             }
    #         }

    #         foreach my $pd_service ($config->returnValues("$sublevel service")) {
    #             # TODO: Do something with these!
    #         }
    #     }

    #     if ($total_addresses > $prefix_addresses) {
    #         die "Total addresses available ($total_addresses) in master prefix-length " .
    #             "$prefix_length not sufficient for total subdelegation of $prefix_addresses addresses.";
    #     }

    #     push @version_config, $option;
    # }
    } else {
        push @version_config, 'ia_na';
    }

    if ($send_main_config) {
        config_edit_interface_v6($ifname, @main_config, @version_config);
    } else {
        config_edit_interface_v6($ifname, -1, @version_config);
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
    config_remove_interface_v6($ifname);
    client_is_running() and client_rebind_interface($ifname);
}
