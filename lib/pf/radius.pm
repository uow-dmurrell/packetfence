package pf::radius;

=head1 NAME

pf::radius - Module that deals with everything RADIUS related

=head1 SYNOPSIS

The pf::radius module contains the functions necessary for answering RADIUS queries.
RADIUS is the network access component known as AAA used in 802.1x, MAC authentication, etc.
This module acts as a proxy between our FreeRADIUS perl module's SOAP requests
(packetfence.pm) and PacketFence core modules.

All the behavior contained here can be overridden in lib/pf/radius/custom.pm.

=cut

use strict;
use warnings;

use pf::log;
use Readonly;

use pf::authentication;
use pf::Connection;
use pf::constants;
use pf::constants::trigger qw($TRIGGER_TYPE_ACCOUNTING);
use pf::config;
use pf::locationlog;
use pf::node;
use pf::Switch;
use pf::SwitchFactory;
use pf::util;
use pf::config::util;
use pf::violation;
use pf::role::custom $ROLE_API_LEVEL;
use pf::floatingdevice::custom;
use pf::radius_accounting_log qw(radius_accounting_log_add radius_accounting_log_update radius_accounting_log_close);
# constants used by this module are provided by
use pf::radius::constants;
use List::Util qw(first);
use pf::util::statsd qw(called);
use pf::StatsD::Timer;
use Hash::Merge qw (merge);

our $VERSION = 1.03;

=head1 SUBROUTINES

=over

=cut

=item * new - get a new instance of the pf::radius object

=cut

sub new {
    my $logger = get_logger();
    $logger->debug("instantiating new pf::radius object");
    my ( $class, %argv ) = @_;
    my $self = bless { }, $class;
    return $self;
}

=item * authorize - handling the RADIUS authorize call

Returns an arrayref (tuple) with element 0 being a response code for Radius and second element an hash meant
to fill the Radius reply (RAD_REPLY). The arrayref is to workaround a quirk in SOAP::Lite and have everything in result()

See http://search.cpan.org/~byrne/SOAP-Lite/lib/SOAP/Lite.pm#IN/OUT,_OUT_PARAMETERS_AND_AUTOBINDING

=cut

# WARNING: You cannot change the return structure of this sub unless you also update its clients (like the SOAP 802.1x
# module). This is because of the way perl mangles a returned hash as a list. Clients would get confused if you add a
# scalar return without updating the clients.
sub authorize {
    my $timer = pf::StatsD::Timer->new();
    my ($self, $radius_request) = @_;
    my $logger = $self->logger;
    my($switch_mac, $switch_ip,$source_ip,$stripped_user_name,$realm) = $self->_parseRequest($radius_request);
    my $RAD_REPLY_REF;

    $logger->debug("instantiating switch");
    my $switch = pf::SwitchFactory->instantiate({ switch_mac => $switch_mac, switch_ip => $switch_ip, controllerIp => $source_ip});

    # is switch object correct?
    if (!$switch) {
        $logger->warn(
            "Can't instantiate switch ($switch_ip). This request will be failed. "
            ."Are you sure your switches.conf is correct?"
        );
        $RAD_REPLY_REF = [ $RADIUS::RLM_MODULE_FAIL, ('Reply-Message' => "Switch is not managed by PacketFence") ];
        goto AUDIT;
    }


    my ($nas_port_type, $eap_type, $mac, $port, $user_name, $nas_port_id, $session_id) = $switch->parseRequest($radius_request);
    Log::Log4perl::MDC->put( 'mac', $mac );
    my $connection = pf::Connection->new;
    $connection->identifyType($nas_port_type, $eap_type, $mac, $user_name, $switch);
    my $connection_type = $connection->attributesToBackwardCompatible;
    my $connection_sub_type = $connection->subType;
    # switch-specific information retrieval
    my $ssid;
    if (($connection_type & $WIRELESS) == $WIRELESS) {
        $ssid = $switch->extractSsid($radius_request);
        $logger->debug("SSID resolved to: $ssid") if (defined($ssid));
    }

    {
        my $timer = pf::StatsD::Timer->new({ 'stat' => called() . ".getIfIndex"});
        $port = $switch->getIfIndexByNasPortId($nas_port_id) || $self->_translateNasPortToIfIndex($connection_type, $switch, $port);
    }

    my $args = {
        switch => $switch,
        switch_mac => $switch_mac,
        switch_ip => $switch_ip,
        source_ip => $source_ip,
        stripped_user_name => $stripped_user_name,
        realm => $realm,
        nas_port_type => $nas_port_type,
        eap_type => $eap_type,
        mac => $mac,
        ifIndex => $port,
        user_name => $user_name,
        nas_port_id => $nas_port_type,
        session_id => $session_id,
        connection_type => $connection_type,
        connection_sub_type => $connection_sub_type,
        radius_request => $radius_request,
    };

    $logger->trace("received a radius authorization request with parameters: ".
        "nas port type => $nas_port_type, switch_ip => ($switch_ip), EAP-Type => $eap_type, ".
        "mac => [$mac], port => $port, username => \"$user_name\"");

    # let's check if an old port sec entry needs to be removed in another switch
    $self->_handleStaticPortSecurityMovement($args);

    # TODO maybe it's in there that we should do all the magic that happened in the FreeRADIUS module
    # meaning: the return should be decided by _doWeActOnThisCall, not always $RADIUS::RLM_MODULE_NOOP
    my $weActOnThisCall = $self->_doWeActOnThisCall($args);
    if ($weActOnThisCall == 0) {
        $logger->info("We decided not to act on this radius call. Stop handling request from $switch_ip.");
        $RAD_REPLY_REF = [ $RADIUS::RLM_MODULE_NOOP, ('Reply-Message' => "Not acting on this request") ];
        goto CLEANUP;
    }

    $logger->info("handling radius autz request: from switch_ip => ($switch_ip), "
        . "connection_type => " . connection_type_to_str($connection_type) . ","
        . "switch_mac => ".( defined($switch_mac) ? "($switch_mac)" : "(Unknown)" ).", mac => [$mac], port => $port, username => \"$user_name\""
        . ( defined $ssid ? ", ssid => $ssid" : '' ) );

    #add node if necessary
    if ( !node_exist($mac) ) {
        $logger->info("does not yet exist in database. Adding it now");
        node_add_simple($mac);
    }

    # Handling machine auth detection
    if ( defined($user_name) && $user_name =~ /^host\// ) {
        $logger->info("is doing machine auth with account '$user_name'.");
        node_modify($mac, ('machine_account' => $user_name));
    }

    if (defined($session_id)) {
         node_modify($mac, ('sessionid' => $session_id));
    }

    my $switch_id =  $switch->{_id};

    # verify if switch supports this connection type
    if (!$self->_isSwitchSupported($args)) {
        # if not supported, return
        $RAD_REPLY_REF = $self->_switchUnsupportedReply($args);
        goto CLEANUP;
    }


    my $role_obj = new pf::role::custom();

    # Vlan Filter
    my $node_info = node_view($mac);
    $args->{'ssid'} = $ssid;
    $args->{'node_info'} = $node_info;
    my $result = $role_obj->filterVlan('IsPhone',$args);
    # determine if we need to perform automatic registration
    # either the switch detects that this is a phone or we take the result from the vlan filters
    my $isPhone = $switch->isPhoneAtIfIndex($mac, $port) || defined($result);

    $args->{'isPhone'} = $isPhone;

    $args->{'autoreg'} = 0;
    # should we auto-register? let's ask the VLAN object
    if ($role_obj->shouldAutoRegister($args)) {
        $args->{'autoreg'} = 1;
        # automatic registration
        my %autoreg_node_defaults = $role_obj->getNodeInfoForAutoReg($args);
        $args->{'node_info'} = merge($args->{'node_info'}, \%autoreg_node_defaults);
        $logger->debug("[$mac] auto-registering node");
        if (!node_register($mac, $autoreg_node_defaults{'pid'}, %autoreg_node_defaults)) {
            $logger->error("auto-registration of node failed");
        }
        # Commented out as it opens a locationlog even when sending a reject
        # This shouldn't break anything in the flow as the entry is opened afterwards
        # This also creates duplicate entries since the VLAN hasn't been computed yet
        # Can be removed in PF6
        # jsemaan@inverse.ca
        #$switch->synchronize_locationlog($port, undef, $mac, $isPhone ? $VOIP : $NO_VOIP,
        #    $connection_type, $connection_sub_type, $user_name, $ssid, $stripped_user_name, $realm);
    }

    # if it's an IP Phone, let _authorizeVoip decide (extension point)
    if ($isPhone) {
        $RAD_REPLY_REF = $self->_authorizeVoip($args);
        goto CLEANUP;
    }

    # if switch is not in production, we don't interfere with it: we log and we return OK
    if (!$switch->isProductionMode()) {
        $logger->warn("Should perform access control on switch ($switch_id) but the switch "
            ."is not in production -> Returning ACCEPT");
        $RAD_REPLY_REF = [ $RADIUS::RLM_MODULE_OK, ('Reply-Message' => "Switch is not in production, so we allow this request") ];
        goto CLEANUP;
    }

    # Check if a floating just plugged in
    $self->_handleAccessFloatingDevices($args);

    # Fetch VLAN depending on node status
    my $role = $role_obj->fetchRoleForNode($args);
    my $vlan = $role->{vlan} || $switch->getVlanByName($role->{role}) || 0;

    $args->{'node_info'}{'source'} = $role->{'source'} if (defined($role->{'source'}) && $role->{'source'} ne '');
    $args->{'node_info'}{'portal'} = $role->{'portal'} if (defined($role->{'portal'}) && $role->{'portal'} ne '');

    $args->{'vlan'} = $vlan;
    $args->{'wasInline'} = $role->{wasInline};
    $args->{'user_role'} = $role->{role};

    #closes old locationlog entries and create a new one if required
    #TODO: Better deal with INLINE RADIUS
    $switch->synchronize_locationlog($port, $vlan, $mac,
        $isPhone ? $VOIP : $NO_VOIP, $connection_type, $connection_sub_type, $user_name, $ssid, $stripped_user_name, $realm, $args->{'user_role'}
    ) if ( (!$role->{wasInline}) && ($vlan != -1) );

    # does the switch support Dynamic VLAN Assignment, bypass if using Inline
    if (!$switch->supportsRadiusDynamicVlanAssignment() && !$role->{wasInline}) {
        $logger->info(
            "Switch doesn't support Dynamic VLAN assignment. " .
            "Setting VLAN with SNMP on (" . $switch->{_id} . ") ifIndex $port to $vlan"
        );
        # WARNING: passing empty switch-lock for now
        # When the _setVlan of a switch who can't do RADIUS VLAN assignment uses the lock we will need to re-evaluate
        $switch->_setVlan( $port, $vlan, undef, {} );
    }

    $RAD_REPLY_REF = $switch->returnRadiusAccessAccept($args);

CLEANUP:
    # cleanup
    $switch->disconnectRead();
    $switch->disconnectWrite();

AUDIT:

    push @$RAD_REPLY_REF, $self->_addRadiusAudit($args);
    return $RAD_REPLY_REF;
}

=item accounting

=cut

sub accounting {
    my $timer = pf::StatsD::Timer->new();
    my ($self, $radius_request) = @_;
    my $logger = $self->logger;

    my ( $switch_mac, $switch_ip, $source_ip, $stripped_user_name, $realm ) = $self->_parseRequest($radius_request);

    $logger->debug("instantiating switch");
    my $switch = pf::SwitchFactory->instantiate( { switch_mac => $switch_mac, switch_ip => $switch_ip, controllerIp => $source_ip } );

    # is switch object correct?
    if ( !$switch ) {
        $logger->warn( "Can't instantiate switch ($switch_ip). This request will be failed. "
                . "Are you sure your switches.conf is correct?" );
        $pf::StatsD::statsd->increment(called() . ".error" );
        return [ $RADIUS::RLM_MODULE_FAIL, ( 'Reply-Message' => "Switch is not managed by PacketFence" ) ];
    }

    my $isStop   = $radius_request->{'Acct-Status-Type'} eq 'Stop';
    my $isUpdate = $radius_request->{'Acct-Status-Type'} eq 'Interim-Update';
    my ($nas_port_type, $eap_type, $mac, $port, $user_name, $nas_port_id, $session_id) = $switch->parseRequest($radius_request);
    my %FIELDS = {};
    $self->_parse_accounting($radius_request, \%FIELDS);
    $FIELDS{'mac'} = $mac;
    radius_accounting_log_add(%FIELDS) if $radius_request->{'Acct-Status-Type'} eq 'Start';
    radius_accounting_log_update($mac,%FIELDS) if $radius_request->{'Acct-Status-Type'} eq 'Interim-Update';
    radius_accounting_log_close($mac,%FIELDS) if $radius_request->{'Acct-Status-Type'} eq 'Stop';

    if ($isStop || $isUpdate) {

        my $connection = pf::Connection->new;
        $connection->identifyType($nas_port_type, $eap_type, $mac, $user_name, $switch);
        my $connection_type = $connection->attributesToBackwardCompatible;

        $port = $switch->getIfIndexByNasPortId($nas_port_id) || $self->_translateNasPortToIfIndex($connection_type, $switch, $port);

        if($isStop){
            #handle radius floating devices
            $self->_handleAccountingFloatingDevices($switch, $mac, $port);
        }

        # On accounting stop/update, check the usage duration of the node
        if ($mac && $user_name) {
            my $session_time = int $radius_request->{'Acct-Session-Time'};
            if ($session_time > 0) {
                my $node_attributes = node_attributes($mac);
                if (defined $node_attributes->{'time_balance'}) {
                    my $time_balance = $node_attributes->{'time_balance'} - $session_time;
                    $time_balance = 0 if ($time_balance < 0);
                    # Only update the node table on a Stop
                    if ($isStop && node_modify($mac, ('time_balance' => $time_balance))) {
                        $logger->info("Session stopped: duration was $session_time secs ($time_balance secs left)");
                    }
                    elsif ($isUpdate) {
                        $logger->info("Session status: duration is $session_time secs ($time_balance secs left)");
                    }
                    if ($time_balance == 0) {
                        # Trigger violation
                        violation_trigger($mac, $ACCOUNTING_POLICY_TIME, $TRIGGER_TYPE_ACCOUNTING);
                    }
                }
            }
        }
    }

    return [ $RADIUS::RLM_MODULE_OK, ('Reply-Message' => "Accounting ok") ];
}

=item _parse_accounting

Takes FreeRADIUS' RAD_REQUEST hash and process it to return accounting attributes

=cut

sub _parse_accounting {
    my ($self, $radius_request, $FIELDS) = @_;

    $$FIELDS{'acctsessiontime'} = $radius_request->{'Acct-Session-Time'} if exists($radius_request->{'Acct-Session-Time'});
    $$FIELDS{'acctinputoctets'} = $radius_request->{'Acct-Input-Octets'} if exists($radius_request->{'Acct-Input-Octets'});
    $$FIELDS{'acctoutputoctets'} = $radius_request->{'Acct-Output-Octets'} if exists($radius_request->{'Acct-Output-Octets'});
    $$FIELDS{'acctinputpackets'} = $radius_request->{'Acct-Input-Packets'} if exists($radius_request->{'Acct-Input-Packets'});
    $$FIELDS{'acctoutputpackets'} = $radius_request->{'Acct-Output-Packets'} if exists($radius_request->{'Acct-Output-Packets'});
}

=item update_locationlog_accounting

Update the location log based on the accounting information

=cut

sub update_locationlog_accounting {
    my $timer = pf::StatsD::Timer->new({sample_rate => 0.05 });
    my ($self, $radius_request) = @_;
    my $logger = $self->logger;

    my ( $switch_mac, $switch_ip, $source_ip, $stripped_user_name, $realm ) = $self->_parseRequest($radius_request);

    $logger->debug("instantiating switch");
    my $switch = pf::SwitchFactory->instantiate( { switch_mac => $switch_mac, switch_ip => $switch_ip, controllerIp => $source_ip } );

    # is switch object correct?
    if ( !$switch ) {
        $logger->warn( "Can't instantiate switch ($switch_ip). This request will be failed. "
                . "Are you sure your switches.conf is correct?" );
        $pf::StatsD::statsd->increment(called() . ".error" );
        return [ $RADIUS::RLM_MODULE_FAIL, ( 'Reply-Message' => "Switch is not managed by PacketFence" ) ];
    }

    if ($switch->supportsRoamingAccounting()) {
        my ($nas_port_type, $eap_type, $mac, $port, $user_name, $nas_port_id, $session_id) = $switch->parseRequest($radius_request);
        my $connection = pf::Connection->new;
        $connection->identifyType($nas_port_type, $eap_type, $mac, $user_name, $switch);
        my $connection_type = $connection->attributesToBackwardCompatible;
        my $connection_sub_type = $connection->subType;
        my $ssid;
        if (($connection_type & $WIRELESS) == $WIRELESS) {
            $ssid = $switch->extractSsid($radius_request);
            $logger->debug("SSID resolved to: $ssid") if (defined($ssid));
        }
        my $vlan;
        $vlan = $radius_request->{'Tunnel-Private-Group-ID'} if ( (defined( $radius_request->{'Tunnel-Type'}) && $radius_request->{'Tunnel-Type'} eq '13') && (defined($radius_request->{'Tunnel-Medium-Type'}) && $radius_request->{'Tunnel-Medium-Type'} eq '6') );
        my $node_info = node_attributes($mac);
        $switch->synchronize_locationlog($port, $vlan, $mac, undef, $connection_type, $connection_sub_type, $user_name, $ssid, $stripped_user_name, $realm, $node_info->{category});
    }
    return [ $RADIUS::RLM_MODULE_OK, ('Reply-Message' => "Update locationlog from accounting ok") ];
}

=item * _parseRequest

Takes FreeRADIUS' RAD_REQUEST hash and process it to return
  AP-MAC
  Network Device IP
  Source-IP

=cut

sub _parseRequest {
    my ($self, $radius_request) = @_;
    my $ap_mac = $self->extractApMacFromRadiusRequest($radius_request);
    # freeradius 2 provides the client IP in NAS-IP-Address not Client-IP-Address (non-standard freeradius1 attribute)
    my $networkdevice_ip = $radius_request->{'NAS-IP-Address'} || $radius_request->{'Client-IP-Address'};
    my $source_ip = $radius_request->{'FreeRADIUS-Client-IP-Address'};
    my $stripped_user_name;
    if (defined($radius_request->{'Stripped-User-Name'})) {
        $stripped_user_name = $radius_request->{'Stripped-User-Name'};
    }
    my $realm;
    if (defined($radius_request->{'Realm'})) {
        $realm = $radius_request->{'Realm'};
    }
    return ($ap_mac, $networkdevice_ip, $source_ip, $stripped_user_name, $realm);
}

sub extractApMacFromRadiusRequest {
    my ($self, $radius_request) = @_;
    my $logger = get_logger();
    # it's put in Called-Station-Id
    # ie: Called-Station-Id = "aa-bb-cc-dd-ee-ff:Secure SSID" or "aa:bb:cc:dd:ee:ff:Secure SSID"
    if (defined($radius_request->{'Called-Station-Id'})) {
        if ($radius_request->{'Called-Station-Id'} =~ /^
            # below is MAC Address with supported separators: :, - or nothing
            ([a-f0-9]{2}([-:]?[a-f0-9]{2}){5})
        /ix) {
            return clean_mac($1);
        } else {
            $logger->info("Unable to extract MAC from Called-Station-Id: ".$radius_request->{'Called-Station-Id'});
        }
    }

    return;
}

=item * _doWeActOnThisCall

Is this request of any interest?

returns 0 for no, 1 for yes

=cut

sub _doWeActOnThisCall {
    my ($self, $args) = @_;
    my $logger = $self->logger;
    $logger->trace("_doWeActOnThisCall called");

    # lets assume we don't act
    my $do_we_act = 0;

    # TODO we could implement some way to know if the same request is being worked on and drop right here

    # is it wired or wireless? call sub accordingly
    if (defined($args->{'connection_type'})) {

        if (($args->{'connection_type'} & $WIRELESS) == $WIRELESS) {
            $do_we_act = $self->_doWeActOnThisCallWireless($args);

        } elsif (($args->{'connection_type'} & $WIRED) == $WIRED) {
            $do_we_act = $self->_doWeActOnThisCallWired($args);
        } else {
            $do_we_act = 0;
        }

    } else {
        # we won't act on an unknown request type
        $do_we_act = 0;
    }
    return $do_we_act;
}

=item * _doWeActOnThisCallWireless

Is this wireless request of any interest?

returns 0 for no, 1 for yes

=cut

sub _doWeActOnThisCallWireless {
    my ($self, $args) = @_;
    my $logger = $self->logger;
    $logger->trace("_doWeActOnThisCallWireless called");

    # for now we always act on wireless radius authorize
    return 1;
}

=item * _doWeActOnThisCallWired - is this wired request of any interest?

Pass all the info you can

returns 0 for no, 1 for yes

=cut

sub _doWeActOnThisCallWired {
    my ($self, $args) = @_;
    my $logger = $self->logger;
    $logger->trace("_doWeActOnThisCallWired called");

    # for now we always act on wired radius authorize
    return 1;
}

=item * _authorizeVoip - RADIUS authorization of VoIP

All of the parameters from the authorize method call are passed just in case someone who override this sub
need it. However, connection_type is passed instead of nas_port_type and eap_type and the switch object
instead of switch_ip.

Returns the same structure as authorize(), see it's POD doc for details.

=cut

sub _authorizeVoip {
    my $timer = pf::StatsD::Timer->new({sample_rate => 0.05 });
    my ($self, $args) = @_;
    my $logger = $self->logger;

    if (!$args->{'switch'}->supportsRadiusVoip()) {
        $logger->warn("Returning failure to RADIUS.");
        $args->{'switch'}->disconnectRead();
        $args->{'switch'}->disconnectWrite();
        return [
            $RADIUS::RLM_MODULE_FAIL,
            ('Reply-Message' => "Server reported: VoIP authorization over RADIUS not supported for this network device")
        ];
    }
    $args->{'switch'}->synchronize_locationlog($args->{'ifIndex'}, $args->{'switch'}->getVlanByName('voice'), $args->{'mac'}, 1, $args->{'connection_type'}, $args->{'connection_sub_type'}, $args->{'user_name'}, $args->{'ssid'});

    my %RAD_REPLY = $args->{'switch'}->getVoipVsa();
    $args->{'switch'}->disconnectRead();
    $args->{'switch'}->disconnectWrite();
    return [$RADIUS::RLM_MODULE_OK, %RAD_REPLY];
}

=item * _translateNasPortToIfIndex - convert the number in NAS-Port into an ifIndex only when relevant

=cut

sub _translateNasPortToIfIndex {
    my ($self, $conn_type, $switch, $port) = @_;
    my $logger = $self->logger;

    if (($conn_type & $WIRED) == $WIRED) {
        $logger->trace("(" . $switch->{_id} . ") translating NAS-Port to ifIndex for proper accounting");
        return $switch->NasPortToIfIndex($port);
    } elsif (($conn_type & $WIRELESS) == $WIRELESS && !defined($port)) {
        $logger->debug("(" . $switch->{_id} . ") got empty NAS-Port parameter, setting 0 to avoid breakage");
        $port = 0;
    }
    return $port;
}

=item * _isSwitchSupported

Determines if switch is supported by current connection type.

=cut

sub _isSwitchSupported {
    my ($self, $args) = @_;
    my $logger = $self->logger;

    if ($args->{'connection_type'} == $WIRED_MAC_AUTH) {
        return $args->{'switch'}->supportsWiredMacAuth();
    } elsif ($args->{'connection_type'} == $WIRED_802_1X) {
        return $args->{'switch'}->supportsWiredDot1x();
    } elsif ($args->{'connection_type'} == $WIRELESS_MAC_AUTH) {
        # TODO implement supportsWirelessMacAuth (or supportsWireless)
        $logger->trace("Wireless doesn't have a supports...() call for now, always say it's supported");
        return $TRUE;
    } elsif ($args->{'connection_type'} == $WIRELESS_802_1X) {
        # TODO implement supportsWirelessMacAuth (or supportsWireless)
        $logger->trace("Wireless doesn't have a supports...() call for now, always say it's supported");
        return $TRUE;
    }
}

=item * _switchUnsupportedReply - what is sent to RADIUS when a switch is unsupported

=cut

sub _switchUnsupportedReply {
    my ($self, $args) = @_;
    my $logger = $self->logger;

    $logger->warn("(" . $args->{'switch'}->{_id} . ") Sending REJECT since switch is unsupported");
    $args->{'switch'}->disconnectRead();
    $args->{'switch'}->disconnectWrite();
    return [$RADIUS::RLM_MODULE_FAIL, ('Reply-Message' => "Network device does not support this mode of operation")];
}

sub _handleStaticPortSecurityMovement {
    my $timer = pf::StatsD::Timer->new;
    my ($self,$args) = @_;
    my $logger = $self->logger;
    #determine if $mac is authorized elsewhere
    my $locationlog_mac = locationlog_view_open_mac($args->{'mac'});
    #Nothing to do if there is no location log
    unless( defined($locationlog_mac) ){
        return undef;
    }

    my $old_switch_id = $locationlog_mac->{'switch'};
    #Nothing to do if it is the same switch
    if ( $old_switch_id eq $args->{'switch'}->{_id} ) {
        return undef;
    }

    my $oldSwitch = pf::SwitchFactory->instantiate($old_switch_id);
    if (!$oldSwitch) {
        $logger->error("Can not instantiate switch $old_switch_id !");
        return;
    }
    my $old_port   = $locationlog_mac->{'port'};
    if (!$oldSwitch->isStaticPortSecurityEnabled($old_port)){
        $logger->debug("Stopping port-security handling in radius since old location is not port sec enabled");
        return;
    }
    my $old_vlan   = $locationlog_mac->{'vlan'};
    my $is_old_voip = is_node_voip($args->{'mac'});

    # We check if the mac moved in a different switch. If it's a different port we don't care.
    # Let's say MAB + port sec on the same switch is a bit too extreme

    $logger->debug("has still open locationlog entry at $old_switch_id ifIndex $old_port");

    $logger->info("Will try to check on this node's previous switch if secured entry needs to be removed. ".
        "Old Switch IP: $old_switch_id");
    my $secureMacAddrHashRef = $oldSwitch->getSecureMacAddresses($old_port);
    if ( exists( $secureMacAddrHashRef->{$args->{'mac'}} ) ) {
        my $fakeMac = $oldSwitch->generateFakeMac( $is_old_voip, $old_port );
        $logger->info("de-authorizing $args->{'mac'} (new entry $fakeMac) at old location $old_switch_id ifIndex $old_port");
        $oldSwitch->authorizeMAC( $old_port, $args->{'mac'}, $fakeMac,
            ( $is_old_voip ? $oldSwitch->getVoiceVlan($old_port) : $oldSwitch->getVlan($old_port) ),
            ( $is_old_voip ? $oldSwitch->getVoiceVlan($old_port) : $oldSwitch->getVlan($old_port) ) );
    } else {
        $logger->info("MAC not found on node's previous switch secure table or switch inaccessible.");
    }
    locationlog_update_end_mac($args->{'mac'});
}

=item * _handleFloatingDevices

Takes care of handling the flow for the RADIUS floating devices when receiving an Accept-Request

=cut

sub _handleAccessFloatingDevices{
    my ($self, $args) = @_;
    my $logger = $self->logger;
    if( exists( $ConfigFloatingDevices{$args->{'mac'}} ) ){
        my $floatingDeviceManager = new pf::floatingdevice::custom();
        $floatingDeviceManager->enableMABFloating($args->{'mac'}, $args->{'switch'}, $args->{'port'});
    }
}

=item * _handleAccountingFloatingDevices

Takes care of handling the flow for the RADIUS floating devices when receiving an accounting stop

=cut

sub _handleAccountingFloatingDevices{
    my ($self, $switch, $mac, $port) = @_;
    my $logger = $self->logger;
    $logger->debug("Verifying if $mac has to be handled as a floating");
    if (exists( $ConfigFloatingDevices{$mac} ) ){
        my $floatingDeviceManager = new pf::floatingdevice::custom();

        my $floating_location = locationlog_view_open_mac($mac);
        $port = $floating_location->{port};
        if(!defined($port)){
            $logger->info("Cannot find locationlog entry for floating device $mac. Assuming floating device mode is off.");
            return;
        }

        $logger->info("Floating device $mac has just been detected as unplugged. Disabling floating device mode on $switch->{_ip} port $port");
        # close location log entry to remove the port from the floating mode.
        locationlog_update_end_mac($mac);
        # disable floating device mode on the port
        $floatingDeviceManager->disableMABFloating($switch, $port);
    }
}

=item logger

Return the current logger for the object

=cut

sub logger {
    my ($proto) = @_;
    return get_logger( ref($proto) || $proto );
}

=item switch_access

return RADIUS attributes or reject for switch login

=cut

sub switch_access {
    my ($self, $radius_request) = @_;
    my $logger = $self->logger;
    my $timer = pf::StatsD::Timer->new();
    my($switch_mac, $switch_ip,$source_ip,$stripped_user_name,$realm) = $self->_parseRequest($radius_request);

    $logger->debug("instantiating switch");
    my $switch = pf::SwitchFactory->instantiate({ switch_mac => $switch_mac, switch_ip => $switch_ip, controllerIp => $source_ip});

    # is switch object correct?
    if (!$switch) {
        $logger->warn(
            "Unknown switch ($switch_ip). This request will be failed."
        );
        return [ $RADIUS::RLM_MODULE_FAIL, ('Reply-Message' => "Switch is not managed by PacketFence") ];
    }
    if ( isdisabled($switch->{_cliAccess})) {
        $logger->warn("CLI Access is not permit on this switch $switch->{_id}");
        return [ $RADIUS::RLM_MODULE_FAIL, ('Reply-Message' => "CLI Access is not allowed by PacketFence on this switch") ];
    }
    my $args = {
        switch => $switch,
        switch_mac => $switch_mac,
        switch_ip => $switch_ip,
        source_ip => $source_ip,
        stripped_user_name => $stripped_user_name,
        realm => $realm,
        user_name => $radius_request->{'User-Name'},
        radius_request => $radius_request,
    };

    my ( $return, $message, $source_id ) = pf::authentication::authenticate( { 'username' =>  $radius_request->{'User-Name'}, 'password' =>  $radius_request->{'User-Password'}, 'rule_class' => $Rules::ADMIN }, @{pf::authentication::getInternalAuthenticationSources()} );
    if ( defined($return) && $return == $TRUE ) {
        my $value = &pf::authentication::match($source_id, { username => $radius_request->{'User-Name'}, 'rule_class' => $Rules::ADMIN }, $Actions::SET_ACCESS_LEVEL);
        if ($value) {
            my @values = split(',', $value);
            foreach $value (@values) {
                if (exists $pf::config::ConfigAdminRoles{$value}->{'ACTIONS'}->{'SWITCH_LOGIN_WRITE'}) {
                    return $switch->returnAuthorizeWrite($args);
                }
                if (exists $pf::config::ConfigAdminRoles{$value}->{'ACTIONS'}->{'SWITCH_LOGIN_READ'}) {
                    return $switch->returnAuthorizeRead($args);
                }
            }
        } else {
            $logger->info("User $args->{'user_name'} has no role (Switches CLI - Read or Switches CLI - Write) to permit to login in $args->{'switch'}{'_id'}");
            return [ $RADIUS::RLM_MODULE_FAIL, ('Reply-Message' => "User has no role defined in PacketFence to allow switch login (SWITCH_LOGIN_READ or SWITCH_LOGIN_WRITE)") ];
        }
    } else {
        $logger->info("User $args->{'user_name'} tried to login in $args->{'switch'}{'_id'} but authentication failed");
        return [ $RADIUS::RLM_MODULE_FAIL, ( 'Reply-Message' => "Authentication failed on PacketFence" ) ];
    }
}

our %ARGS_TO_RADIUS_ATTRIBUTES = (
    mac => 'PacketFence-Mac',
    user_name => 'PacketFence-UserName',
    ifIndex => 'PacketFence-IfIndex',
    isPhone => 'PacketFence-IsPhone',
    ssid => 'PacketFence-SSID',
    autoreg => 'PacketFence-AutoReg',
    eap_type => 'PacketFence-Eap-Type',
    connection_type => 'PacketFence-Connection-Type',
    user_role => 'PacketFence-Role',
);

our %NODE_ATTRIBUTES_TO_RADIUS_ATTRIBUTES = (
    status => 'PacketFence-Status',
    source => 'PacketFence-Source',
    portal => 'PacketFence-Profile',
    computername => 'PacketFence-Computer-Name',
);

our %SWITCH_ATTRIBUTES_TO_RADIUS_ATTRIBUTES = (
    _id => 'PacketFence-Switch-Id',
    _ip => 'PacketFence-Switch-Ip-Address',
    _switchMac => 'PacketFence-Switch-Mac',
);

=item _addRadiusAudit

=cut

sub _addRadiusAudit {
    my ($self, $args) = @_;
    my $stash = {};
    _update_audit_stash($stash, \%ARGS_TO_RADIUS_ATTRIBUTES, $args);
    my $switch = $args->{switch};
    if ($switch) {
        _update_audit_stash($stash, \%SWITCH_ATTRIBUTES_TO_RADIUS_ATTRIBUTES, $switch);
    }
    my $node = $args->{node_info};
    if($node) {
        _update_audit_stash($stash, \%NODE_ATTRIBUTES_TO_RADIUS_ATTRIBUTES, $node);
    }
    $stash->{'PacketFence-Connection-Type'} = connection_type_to_str($stash->{'PacketFence-Connection-Type'})
      if exists $stash->{'PacketFence-Connection-Type'} && defined $stash->{'PacketFence-Connection-Type'};
    return (RADIUS_AUDIT => $stash);
}

sub _update_audit_stash {
    my ($stash, $lookup, $args) = @_;
    foreach my $key (keys %$lookup) {
        next unless exists $args->{$key} && defined $args->{$key};
        $stash->{$lookup->{$key}} = $args->{$key};
    }
}

=back

=head1 AUTHOR

Inverse inc. <info@inverse.ca>

=head1 COPYRIGHT

Copyright (C) 2005-2016 Inverse inc.

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

# vim: set shiftwidth=4:
# vim: set expandtab:
# vim: set tabstop=4:
# vim: set backspace=indent,eol,start:
