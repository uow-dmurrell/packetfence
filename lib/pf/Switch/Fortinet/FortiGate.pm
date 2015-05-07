package pf::Switch::Fortinet::FortiGate;

=head1 NAME

pf::Switch::Fortinet::FortiGate - Object oriented module to FortiGate using the external captive portal

=head1 SYNOPSIS

The pf::Switch::Fortinet::FortiGate  module implements an object oriented interface to interact with the FortiGate captive portal

=head1 STATUS

=cut

=head1 BUGS AND LIMITATIONS

=cut

use strict;
use warnings;
use Log::Log4perl;
use pf::config;
use pf::node;
use pf::violation;
use pf::locationlog;
use pf::util;
use LWP::UserAgent;
use HTTP::Request::Common;
use pf::log;

use base ('pf::Switch::Fortinet');

=head1 METHODS

=cut

sub description { 'FortiGate Firewall with web auth' }

sub supportsExternalPortal { return $TRUE; }
sub supportsWebFormRegistration { return $TRUE }
sub supportsWirelessMacAuth { return $TRUE; }
sub supportsWiredMacAuth { return $TRUE; }

sub parseUrl {
    my($self, $req) = @_;
    my $logger = Log::Log4perl::get_logger( ref($self) );
    # need to synchronize the locationlog event if we'll reject
    $self->synchronize_locationlog("0", "0", clean_mac($$req->param('usermac')),
        0, $WIRELESS_MAC_AUTH, clean_mac($$req->param('usermac')), "0"
    );

    return ($$req->param('usermac'),undef,$$req->param('userip'),undef,$$req->param('post'),"200");
}

=head2 returnRadiusAccessAccept

Prepares the RADIUS Access-Accept reponse for the network device.

Overriding the default implementation for the external captive portal

=cut

sub returnRadiusAccessAccept {
    my ($self, $vlan, $mac, $port, $connection_type, $user_name, $ssid, $wasInline, $user_role) = @_;
    my $logger = Log::Log4perl::get_logger( ref($self) );

    my $radius_reply_ref = {};

    my $node = node_view($mac);

    my $violation = pf::violation::violation_view_top($mac);
    # if user is unregistered or is in violation then we reject him to show him the captive portal 
    if ( $node->{status} eq $pf::node::STATUS_UNREGISTERED || defined($violation) ){
        $logger->info("[$mac] is unregistered. Refusing access to force the eCWP");
        my $radius_reply_ref = {
            'Tunnel-Medium-Type' => $RADIUS::ETHERNET,
            'Tunnel-Type' => $RADIUS::VLAN,
            'Tunnel-Private-Group-ID' => -1,
        }; 
        return [$RADIUS::RLM_MODULE_OK, %$radius_reply_ref]; 

    }
    else{
        $logger->info("[$mac] Returning ACCEPT");
        return [$RADIUS::RLM_MODULE_OK, %$radius_reply_ref];
    }

}

sub getAcceptForm {
    my ( $self, $mac , $destination_url, $cgi_session) = @_;
    my $logger = Log::Log4perl::get_logger( ref($self) );
    $logger->debug("[$mac] Creating web release form");

    my $magic = $cgi_session->param("ecwp-original-param-magic");
    my $post = $cgi_session->param("ecwp-original-param-post");

    my $html_form = qq[
        <form name="weblogin_form" method="POST" action="$post">
            <input type="hidden" name="username" value="$mac">
            <input type="hidden" name="password" value="$mac">
            <input type="hidden" name="magic" value="$magic">
            <input type="submit" style="display:none;">
        </form>
        <script language="JavaScript" type="text/javascript">
        window.setTimeout('document.weblogin_form.submit();', 1000);
        </script>
    ];

    $logger->debug("Generated the following html form : ".$html_form);
    return $html_form;
}

sub deauthenticateMacDefault {
    get_logger->info("No doing deauthentication since this is a web form released switch.");
}


=head1 AUTHOR

Inverse inc. <info@inverse.ca>

=head1 COPYRIGHT

Copyright (C) 2005-2015 Inverse inc.

=head1 LICENSE

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301,
USA.

=cut

1;

