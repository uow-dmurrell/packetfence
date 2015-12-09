package pf::role;

=head1 NAME

pf::role - Object oriented module for VLAN isolation oriented functions

=head1 SYNOPSIS

The pf::role module contains the functions necessary for the VLAN isolation.
All the behavior contained here can be overridden in lib/pf/role/custom.pm.

=cut

# When adding a "use", remember to keep pf::role::custom up to date for easier customization.
use strict;
use warnings;

use pf::log;

use pf::constants;
use pf::constants::trigger qw($TRIGGER_ID_PROVISIONER $TRIGGER_TYPE_PROVISIONER);
use pf::config;
use pf::node qw(node_exist node_modify);
use pf::Switch::constants;
use pf::util;
use pf::config::util;
use pf::violation qw(violation_count_reevaluate_access violation_exist_open violation_view_top violation_trigger violation_add);
use pf::floatingdevice::custom;
use pf::constants::scan qw($POST_SCAN_VID);
use pf::authentication;
use pf::Authentication::constants;
use pf::Portal::ProfileFactory;
use pf::access_filter::vlan;
use pf::person;
use pf::lookup::person;
use Time::HiRes;
use pf::util::statsd qw(called);
use pf::StatsD;
use Data::Thunk;

our $VERSION = 1.04;

=head1 SUBROUTINES

Warning: The list of subroutine is incomplete

=cut

=head2 new

Constructor.
Usually you don't want to call this constructor but use the pf::role::custom subclass instead.

=cut

sub new {
    my ( $class, %argv ) = @_;
    my $logger = $class->get_logger();
    $logger->debug("instantiating new pf::role object");
    my $self = bless {}, $class;
    return $self;
}

=head2 fetchRoleForNode

Answers the question: What VLAN should a given node be put into?

This sub is meant to be overridden in lib/pf/role/custom.pm if the default
version doesn't do the right thing for you. However it is very generic,
maybe what you are looking for needs to be done in getViolationRole,
getRegistrationRole or getRegisteredRole.

=cut

sub fetchRoleForNode {
    my ( $self, $args) = @_;
    my $logger = $self->logger;
    my $start = Time::HiRes::gettimeofday();

    my $node_info = $args->{'node_info'};

    if ($self->isInlineTrigger($args)) {
        $logger->info("Inline trigger match, the node is in inline mode");
        my $inline = $self->getInlineRole($args);
        $logger->info("PID: \"" .$node_info->{pid}. "\", Status: " .$node_info->{status}. ". Returned VLAN: $inline");
        $pf::StatsD::statsd->end(called() . ".timing" , $start, 0.25 );
        return ({ role => "inline", wasInline => 1 });
    }

    # radius floating device handling
    if( $args->{'switch'}->supportsMABFloatingDevices ){
        my $floatingDeviceManager = new pf::floatingdevice::custom();
        if (exists($ConfigFloatingDevices{$args->{'mac'}})){
            my $floating_config = $ConfigFloatingDevices{$args->{'mac'}};
            $logger->info("Floating device has plugged into $args->{'switch'}->{_ip} port $args->{'ifIndex'}. Returned VLAN : $floating_config->{pvid}");
            $pf::StatsD::statsd->end(called() . ".timing" , $start, 0.25 );
            return ({ vlan => $floating_config->{'pvid'}});
        }
        my $floating_mac = $floatingDeviceManager->portHasFloatingDevice($args->{'switch'}->{_ip}, $args->{'ifIndex'});
        if($floating_mac){
            $logger->debug("Device is plugged into a floating enabled port (Device $floating_mac). Determining if trunk.");
            my $floating_config = $ConfigFloatingDevices{$floating_mac};
            if( ! $floating_config->{'trunkPort'} ){
                $logger->info("PID: $node_info->{pid} has just plugged in an access floating device enabled port. Returned VLAN $floating_config->{pvid}");
                $pf::StatsD::statsd->end(called() . ".timing" , $start, 0.25 );
                return ({ vlan => $floating_config->{'pvid'}});
            }
        }
    }

    # violation handling
    my $answer = $self->getViolationRole($args);
    $answer->{wasInline} = 0;
    if (defined($answer->{role}) && $answer->{role} ne "0" ) {
        $pf::StatsD::statsd->end(called() . ".timing" , $start, 0.25 );
        return $answer;
    } elsif (!defined($answer->{role})) {
        return $answer;
    }

    # there were no violation, now onto registration handling
    $answer = $self->getRegistrationRole($args);
    if (defined($answer->{role}) && $answer->{role} ne "0") {
        if ( $args->{'connection_type'} && ($args->{'connection_type'} & $WIRELESS_MAC_AUTH) == $WIRELESS_MAC_AUTH ) {
            if (isenabled($node_info->{'autoreg'})) {
                $logger->info("Connection type is WIRELESS_MAC_AUTH and the device was coming from a secure SSID with auto registration");
                node_modify($args->{'mac'}, ('autoreg' => 'no'));
            }
        }
        $pf::StatsD::statsd->end(called() . ".timing" , $start, 0.25 );
        return $answer;
    }

    # no violation, not unregistered, we are now handling a normal vlan
    $answer = $self->getRegisteredRole($args);
    $logger->info("PID: \"" .$node_info->{pid}. "\", Status: " .$node_info->{status}. " Returned VLAN: ".(defined $answer->{vlan} ? $answer->{vlan} : "(undefined)").", Role: " . (defined $answer->{role} ? $answer->{role} : "(undefined)") );
    $pf::StatsD::statsd->end(called() . ".timing" , $start, 0.25 );
    return $answer;
}

=head2 doWeActOnThisTrap

Don't act on uplinks, unkown interface types or some traps we are not interested in.

This sub is meant to be overridden in lib/pf/role/custom.pm if the default
version doesn't do the right thing for you.

=cut

sub doWeActOnThisTrap {
    my ( $self, $switch, $ifIndex, $trapType ) = @_;
    my $logger = $self->logger;

    # TODO we should rethink the position of this code, it's in the wrong test but at the good spot in the flow
    my $weActOnThisTrap = 0;
    if ( $trapType eq 'desAssociate' || $trapType eq 'firewallRequest' || $trapType eq 'roaming') {
        return 1;
    }
    if ( $trapType eq 'dot11Deauthentication' ) {
        # we no longer act on dot11Deauth traps see bug #880
        # http://www.packetfence.org/mantis/view.php?id=880
        return 0;
    }

    # ifTypes: http://www.iana.org/assignments/ianaiftype-mib
    my $ifType = $switch->getIfType($ifIndex);
    # see ifType documentation in pf::Switch::constants
    if ( ( $ifType == $SNMP::ETHERNET_CSMACD ) || ( $ifType == $SNMP::GIGABIT_ETHERNET ) ) {
        my @upLinks = $switch->getUpLinks();
        if ( @upLinks && $upLinks[0] == -1 ) {
            $logger->warn("Can't determine Uplinks for the switch (" . $switch->{_id} . ") -> do nothing");
        } else {
            if ( grep( { $_ == $ifIndex } @upLinks ) == 0 ) {
                $weActOnThisTrap = 1;
            } else {
                $logger->info( "$trapType trap received on (" . $switch->{_id} . ") "
                    . "ifindex $ifIndex which is uplink and we don't manage uplinks"
                );
            }
        }
    } else {
        $logger->info( "$trapType trap received on (" . $switch->{_id} . ") "
            . "ifindex $ifIndex which is not ethernetCsmacd"
        );
    }
    return $weActOnThisTrap;
}

=head2 getViolationRole

Returns the violation role for a node (if any)

This sub is meant to be overridden in lib/pf/role/custom.pm if you have specific isolation needs.

Return values:

=head2 * -1 means kick-out the node (not always supported)

=head2 * 0 means no violation for this node

=head2 * undef means there was an error

=head2 * anything else is either a VLAN name string or a VLAN number

=cut

sub getViolationRole {
    # $args->{'switch'} is the switch object (pf::Switch)
    # $args->{'ifIndex'} is the ifIndex of the computer connected to
    # $args->{'mac'} is the mac connected
    # $args->{'connection_type'} is set to the connnection type expressed as the constant in pf::config
    # $args->{'user_name'} is set to the RADIUS User-Name attribute (802.1X Username or MAC address under MAC Authentication)
    # $args->{'ssid'} is the name of the SSID (Be careful: will be empty string if radius non-wireless and undef if not radius)
    my ($self, $args) = @_;
    my $logger = $self->logger;
    my $start = Time::HiRes::gettimeofday();

    my $open_violation_count = violation_count_reevaluate_access($args->{'mac'});
    if ($open_violation_count == 0) {
        $pf::StatsD::statsd->end(called() . ".timing", $start );
        return ({ role => 0});
    }

    $logger->debug("has $open_violation_count open violations(s) with action=trap; ".
                   "it might belong into another VLAN (isolation or other).");

    # Vlan Filter
    my $role = $self->filterVlan('ViolationRole',$args);
    if ($role) {
        $pf::StatsD::statsd->end(called() . ".timing" , $start, 0.25 );
        return ({role => $role});
    }

    # By default we assume that we put the user in isolation role unless proven otherwise
    $role = "isolation";

    # fetch top violation
    $logger->trace("What is the highest priority violation for this host?");
    my $top_violation = violation_view_top($args->{'mac'});
    # fetching top violation failed
    if (!$top_violation || !defined($top_violation->{'vid'})) {

        $logger->warn("Could not find highest priority open violation. ".
                      "Setting target role");
        $pf::StatsD::statsd->increment(called() . ".error" );
        $pf::StatsD::statsd->end(called() . ".timing" , $start, 0.25 );
        return ({role => $role});
    }

    # get violation id
    my $vid = $top_violation->{'vid'};

    # Scan violation that must be done in the production vlan
    if ($vid == $POST_SCAN_VID) {
        $pf::StatsD::statsd->end(called() . ".timing" , $start);
        return $FALSE;
    }

    # find violation class based on violation id
    require pf::class;
    my $class = pf::class::class_view($vid);
    # finding violation class based on violation id failed
    if (!$class || !defined($class->{'vlan'})) {

        $logger->warn("Could not find class entry for violation $vid. ".
                      "Setting target role to isolation");
        $pf::StatsD::statsd->increment(called() . ".error" );
        $pf::StatsD::statsd->end(called() . ".timing" , $start );
        return ({role => $role});
    }

    # override violation destination vlan
    $role = $class->{'vlan'};

    # example of a specific violation that packetfence should block instead of isolate
    # ex: block iPods / iPhones because they tend to overload controllers, radius and captive portal in isolation vlan
    # if ($vid == '1100004') { return -1; }

    # Asking the switch to give us its configured vlan number for the vlan returned for the violation
    if (defined($role)) {
        $logger->info("highest priority violation is $vid. Target Role for violation: $role");
    }

    $pf::StatsD::statsd->end(called() . ".timing" , $start);
    return ({role => $role});
}


=head2 getRegistrationRole

Returns the registration role for a node if registration is enabled and node is unregistered or pending.

This sub is meant to be overridden in lib/pf/role/custom.pm if you have specific registration needs.

Return values:

=head2 * 0 means node is already registered

=head2 * undef means there was an error

=head2 * anything else is either a VLAN name string or a VLAN number

=cut

sub getRegistrationRole {
    #$args->{'switch'} is the switch object (pf::Switch)
    #$args->{'ifIndex'} is the ifIndex of the computer connected to
    #$args->{'mac'} is the mac connected
    #$args->{'node_info'} is the node info hashref (result of pf::node's node_attributes on $args->{'mac'})
    #$args->{'connection_type'} is set to the connnection type expressed as the constant in pf::config
    #$args->{'user_name'} is set to the RADIUS User-Name attribute (802.1X Username or MAC address under MAC Authentication)
    #$args->{'ssid'} is the name of the SSID (Be careful: will be empty string if radius non-wireless and undef if not radius)
    my ($self, $args) = @_;
    my $logger = $self->logger;
    my $start = Time::HiRes::gettimeofday();

    # trapping on registration is enabled

    if (!isenabled($Config{'trapping'}{'registration'})) {
        $logger->debug("Registration trapping disabled: skipping node is registered test");
        return ({ role => 0});
    }

    if (!defined($args->{'node_info'})) {
        # Vlan Filter
        my $role = $self->filterVlan('RegistrationRole',$args);
        if ($role) {
            $logger->info("vlan filter match ; belongs into $role VLAN");
            $pf::StatsD::statsd->end(called() . ".timing" , $start, 0.25 );
            return ({role => $role});
        }
        $logger->info("doesn't have a node entry; belongs into registration VLAN");
        my $vlan = $args->{'switch'}->getVlanByName('registration');
        $pf::StatsD::statsd->end(called() . ".timing" , $start, 0.25 );
        return ({role => 'registration'});
    }

    my $n_status = $args->{'node_info'}->{'status'};
    if ($n_status eq $pf::node::STATUS_UNREGISTERED || $n_status eq $pf::node::STATUS_PENDING) {
        # Vlan Filter
        my $role = $self->filterVlan('RegistrationRole',$args);
        if ($role) {
            $logger->info("vlan filter match ; belongs into $role VLAN");
            $pf::StatsD::statsd->end(called() . ".timing" , $start, 0.25 );
            return ({role => $role});
        }
        $logger->info("is of status $n_status; belongs into registration VLAN");
        my $vlan = $args->{'switch'}->getVlanByName('registration');
        $pf::StatsD::statsd->end(called() . ".timing" , $start, 0.05 );
        return ({role => 'registration'});
    }
    $pf::StatsD::statsd->end(called() . ".timing" , $start, 0.25 );
    return ({ role => 0});
}

=head2 getRegisteredRole

Returns registered Role

This sub is meant to be overridden in lib/pf/role/custom.pm if the default version doesn't do the right thing for you.
It will try to match a role based on a username (if provided) or on the node MAC address and return the according
VLAN for the given switch.

Return values:

=head2 * -1 means kick-out the node (not always supported)

=head2 * 0 means node is already registered

=head2 * undef means there was an error

=head2 * anything else is either a VLAN name string or a VLAN number

=cut

sub getRegisteredRole {
    #$args->{'switch'} is the switch object (pf::Switch)
    #$args->{'ifIndex'} is the ifIndex of the computer connected to
    #$args->{'mac'} is the mac connected
    #$args->{'node_info'} is the node info hashref (result of pf::node's node_attributes on $args->{'mac'})
    #$args->{'connection_type'} is set to the connnection type expressed as the constant in pf::config
    #$args->{'user_name'} is set to the RADIUS User-Name attribute (802.1X Username or MAC address under MAC Authentication)
    #$args->{'ssid'} is the name of the SSID (Be careful: will be empty string if radius non-wireless and undef if not radius)
    my ($self, $args) = @_;
    my $logger = $self->logger;
    my $start = Time::HiRes::gettimeofday();

    my $options = {};
    $options->{'last_connection_type'} = connection_type_to_str($args->{'connection_type'}) if (defined( $args->{'connection_type'}));
    $options->{'last_switch'}          = $args->{'switch'}->{_id} if (defined($args->{'switch'}->{_id}));
    $options->{'last_port'}            = $args->{'ifIndex'} if (defined($args->{'ifIndex'}));
    $options->{'last_ssid'}            = $args->{'ssid'} if (defined($args->{'ssid'}));
    $options->{'last_dot1x_username'}  = $args->{'user_name'} if (defined($args->{'user_name'}));
    $options->{'realm'}                = $args->{'realm'} if (defined($args->{'realm'}));

    my $profile = pf::Portal::ProfileFactory->instantiate($args->{'mac'},$options);

    my ($vlan, $role, $result);

    my $provisioner = $profile->findProvisioner($args->{'mac'},$args->{'node_info'});
    if (defined($provisioner) && $provisioner->{enforce}) {
        $logger->info("Triggering provisioner check");
        violation_trigger($args->{'mac'}, $TRIGGER_ID_PROVISIONER, $TRIGGER_TYPE_PROVISIONER);
    }

    my $scan = $profile->findScan($args->{'mac'},$args->{'node_info'});
    if (defined($scan) && isenabled($scan->{'post_registration'})) {
        $logger->info("Triggering scan check");
        violation_add( $args->{'mac'}, $POST_SCAN_VID );
    }

    $role = _check_bypass($args);
    if( $role ) {
        $pf::StatsD::statsd->end(called() . ".timing" , $start, 0.25 );
        return $role;
    }

    $logger->debug("Trying to determine VLAN from role.");

    # Vlan Filter
    $role = $self->filterVlan('RegisteredRole',$args);
    if ( $role ) {
        $pf::StatsD::statsd->end(called() . ".timing" , $start, 0.25 );
        return ({ role => $role});
    }

    # Try MAC_AUTH, then other EAP methods and finally anything else.
    if ( $args->{'connection_type'} && ($args->{'connection_type'} & $WIRED_MAC_AUTH) == $WIRED_MAC_AUTH ) {
        $logger->info("Connection type is WIRED_MAC_AUTH. Getting role from node_info" );
        $role = $args->{'node_info'}->{'category'};
    } elsif ( $args->{'connection_type'} && ($args->{'connection_type'} & $WIRELESS_MAC_AUTH) == $WIRELESS_MAC_AUTH ) {
        $logger->info("Connection type is WIRELESS_MAC_AUTH. Getting role from node_info" );
        $role = $args->{'node_info'}->{'category'};
    }

    # If it's an EAP connection with a username, we try to match that username with authentication sources to calculate
    # the role based on the rules defined in the different authentication sources.
    # FIRST HIT MATCH
    elsif ( defined $args->{'user_name'} && $args->{'connection_type'} && ($args->{'connection_type'} & $EAP) == $EAP ) {
        if ( (isenabled($args->{'node_info'}->{'autoreg'}) && $args->{'autoreg'}) or isdisabled($profile->dot1xRecomputeRoleFromPortal) ) {
            $logger->info("Role has already been computed and we don't want to recompute it. Getting role from node_info" );
            $role = $args->{'node_info'}->{'category'};
        } else {
            my @sources = ($profile->getInternalSources, $profile->getExclusiveSources );
            my $stripped_user = '';
            $stripped_user = $args->{'stripped_user_name'} if(defined($args->{'stripped_user_name'}));
            my $params = {
                username => $args->{'user_name'},
                connection_type => connection_type_to_str($args->{'connection_type'}),
                SSID => $args->{'ssid'},
                stripped_user_name => $stripped_user,
                rule_class => 'authentication',
            };
            my $source;
            $role = &pf::authentication::match([@sources], $params, $Actions::SET_ROLE, \$source);
            # create a person entry for pid if it doesn't exist
            if ( !pf::person::person_exist($args->{'user_name'}) ) {
                $logger->info("creating person $args->{'user_name'} because it doesn't exist");
                pf::person::person_add($args->{'user_name'});
                pf::lookup::person::lookup_person($args->{'user_name'},$source);
            } else {
                $logger->debug("person $args->{'user_name'} already exists");
            }
            pf::person::person_modify($args->{'user_name'},
                'source'  => $source,
                'portal'  => $profile->getName,
            );
            my %info = (
                'autoreg' => 'no',
                'pid' => $args->{'user_name'},
            );
            if (defined $role) {
                %info = (%info, (category => $role));
            }
            node_modify($args->{'mac'},%info);
        }
    }
    # If a user based role has been found by matching authentication sources rules, we return it
    if ( defined($role) && $role ne '' ) {
        $logger->info("Username was defined \"$args->{'user_name'}\" - returning role '$role'");
    # Otherwise, we return the node based role matched with the node MAC address
    } else {
        $role = $args->{'node_info'}->{'category'};
        $logger->info("Username was NOT defined or unable to match a role - returning node based role '$role'");
    }
    $pf::StatsD::statsd->end(called() . ".timing" , $start, 0.25 );
    return ({role => $role});
}

=head2 getInlineRole

Handling the Inline VLAN Assignment

=head2 * -1 means kick-out the node (not always supported)

=head2 * 0 means use native vlan

=head2 * undef means there was an error

=head2 * anything else is either a VLAN name string or a VLAN number

=cut

sub getInlineRole {
    #$args->{'switch'} is the switch object (pf::Switch)
    #$args->{'ifIndex'} is the ifIndex of the computer connected to
    #$args->{'mac'} is the mac connected
    #$node_info is the node info hashref (result of pf::node's node_attributes on $args->{'mac'})
    #$conn_type is set to the connnection type expressed as the constant in pf::config
    #$args->{'user_name'} is set to the RADIUS User-Name attribute (802.1X Username or MAC address under MAC Authentication)
    #$args->{'ssid'} is the name of the SSID (Be careful: will be empty string if radius non-wireless and undef if not radius)
    my ($self, $args) = @_;
    my $logger = $self->logger;
    my $start = Time::HiRes::gettimeofday();

    my $role = $self->filterVlan('InlineRole',$args);
    if ( $role ) {
        $pf::StatsD::statsd->end(called() . ".timing" , $start, 0.25 );
        return ({role => $role});
    }

    $pf::StatsD::statsd->end(called() . ".timing" , $start, 0.25 );
    return ({role => 'inline'});
}

=head2 getNodeInfoForAutoReg

Basic information returned for an auto-registered node

This sub is meant to be overridden in lib/pf/role/custom.pm if the default
version doesn't do the right thing for you.

Returns an anonymous hash that is meant for node_register()

=cut

sub getNodeInfoForAutoReg {
    #$args->{'switch'}_in_autoreg_mode is set to 1 if switch is in registration mode
    #$violation_autoreg is set to 1 if called from a violation with autoreg action
    #$isPhone is set to 1 if device is considered an IP Phone.
    #$conn_type is set to the connnection type expressed as the constant in pf::config
    #$args->{'user_name'} is set to the RADIUS User-Name attribute (802.1X Username or MAC address under MAC Authentication)
    #$args->{'ssid'} is set to the wireless ssid (will be empty if radius and not wireless, undef if not radius)
    my ($self, $args) = @_;
    my $logger = $self->logger;
    my $start = Time::HiRes::gettimeofday();

    #define the current connection value to instantiate the correct portal
    my $options = {};

    $options->{'last_connection_type'} = connection_type_to_str($args->{'connection_type'}) if (defined( $args->{'connection_type'}));
    $options->{'last_switch'}          = $args->{'switch'}->{_id} if (defined($args->{'switch'}->{_id}));
    $options->{'last_port'}            = $args->{'switch'}->{switch_port} if (defined($args->{'switch'}->{switch_port}));
    $options->{'last_vlan'}            = $args->{'vlan'} if (defined($args->{'vlan'}));
    $options->{'last_ssid'}            = $args->{'ssid'} if (defined($args->{'ssid'}));
    $options->{'last_dot1x_username'}  = $args->{'user_name'} if (defined($args->{'user_name'}));
    $options->{'realm'}                = $args->{'realm'} if (defined($args->{'realm'}));

    my $profile = pf::Portal::ProfileFactory->instantiate($args->{'mac'},$options);

    my $role = $self->filterVlan('NodeInfoForAutoReg', $args);

    # we do not set a default VLAN here so that node_register will set the default normalVlan from switches.conf
    my %node_info = (
        pid             => $default_pid,
        notes           => 'AUTO-REGISTERED',
        status          => 'reg',
        auto_registered => 1, # tells node_register to autoreg
        autoreg         => 'yes',
        voip            => 'no',
    );
    if (defined($role)) {
        $node_info{'category'} = $role;
    }

    # if we are called from a violation with action=autoreg, say so
    if (defined($args->{'violation_autoreg'}) && $args->{'$violation_autoreg'}) {
        $node_info{'notes'} = 'AUTO-REGISTERED by violation';
        $node_info{'autoreg'} = 'no'; # This flag has not to be used for violation autoreg
    }

    # this might look circular but if a VoIP dhcp fingerprint was seen, we'll set node.voip to VOIP
    if ($args->{'isPhone'}) {
        $node_info{'voip'} = $VOIP;
    }

    # under 802.1X EAP, we trust the username provided since it authenticated
    if (defined($args->{'connection_type'}) && (($args->{'connection_type'} & $EAP) == $EAP) && defined($args->{'user_name'})) {
        $logger->debug("EAP connection with a username \"$args->{'user_name'}\". Trying to match rules from authentication sources.");
        my @sources = ($profile->getInternalSources, $profile->getExclusiveSources );
        my $stripped_user = '';
        $stripped_user = $args->{'stripped_user_name'} if(defined($args->{'stripped_user_name'}));
        my $params = {
            username => $args->{'user_name'},
            connection_type => connection_type_to_str($args->{'connection_type'}),
            SSID => $args->{'ssid'},
            stripped_user_name => $stripped_user,
        };

        my $source;
        # Don't override vlan filter role
        if (!defined($role)) {
            $role = &pf::authentication::match([@sources], $params, $Actions::SET_ROLE, \$source);
        }
        my $value = &pf::authentication::match([@sources], $params, $Actions::SET_UNREG_DATE);

        if (defined $value) {
            $node_info{'unregdate'} = $value;
            if (defined $role) {
                %node_info = (%node_info, (category => $role));
            }
            %node_info = (%node_info, (source  => $source, portal => $profile->getName));
        }
        $node_info{'pid'} = $args->{'user_name'};
    }

    # set the eap_type if it exist
    if (defined($args->{'eap_type'})) {
        $node_info{'eap_type'} = $args->{'eap_type'};
    }

    $pf::StatsD::statsd->end(called() . ".timing" , $start, 0.25 );
    return %node_info;
}

=head2 shouldAutoRegister

Do we auto-register this node?

By default we register automatically when the switch is configured to (registration mode),
when there is a violation with action autoreg and when the device is a phone.

This sub is meant to be overridden in lib/pf/role/custom.pm if the default
version doesn't do the right thing for you.

returns 1 if we should register, 0 otherwise

=cut

sub shouldAutoRegister {
    #$args->{'mac'} is MAC address
    #$args->{'switch'}_in_autoreg_mode is set to 1 if switch is in registration mode
    #$args->{'violation_autoreg'} is set to 1 if called from a violation with autoreg action
    #$args->{'isPhone'} is set to 1 if device is considered an IP Phone.
    #$args->{'connection'}_type is set to the connnection type expressed as the constant in pf::config
    #$args->{'user_name'} is set to the RADIUS User-Name attribute (802.1X Username or MAC address under MAC Authentication)
    #$args->{'ssid'} is set to the wireless ssid (will be empty if radius and not wireless, undef if not radius)
    my ($self, $args) = @_;
    my $logger = $self->logger;
    my $start = Time::HiRes::gettimeofday();

    $logger->trace("[$args->{'mac'}] asked if should auto-register device");

    # handling switch-config first because I think it's the most important to honor
    if (defined($args->{'switch'}->{switch_in_autoreg_mode}) && $args->{'switch'}->{switch_in_autoreg_mode}) {
        $logger->trace("returned yes because it's from the switch's config (" . $args->{'switch'}->{_id} . ")");
        $pf::StatsD::statsd->end(called() . ".timing" , $start, 0.25 );
        return 1;

    # if we have a violation action set to autoreg
    } elsif (defined($args->{'violation_autoreg'}) && $args->{'violation_autoreg'}) {
        $logger->trace("returned yes because it's from a violation with action autoreg");
        $pf::StatsD::statsd->end(called() . ".timing" , $start, 0.25 );
        return 1;
    }

    if ($args->{'isPhone'}) {
        $logger->trace("returned yes because it's an ip phone");
        $pf::StatsD::statsd->end(called() . ".timing" , $start, 0.25 );
        return $args->{'isPhone'};
    }
    my $role = $self->filterVlan('AutoRegister',$args);
    if ($role) {
        if ($args->{'switch'}->getVlanByName($role) eq -1) {
            return 0;
        } else {
            return $role;
        }
    }

    # custom example: auto-register 802.1x users
    # Since they already have validated credentials through EAP to do 802.1X
    #if (defined($conn_type) && (($conn_type & $EAP) == $EAP)) {
    #    $logger->trace("returned yes because it's a 802.1X client that successfully authenticated already");
    #    $pf::StatsD::statsd->end(called() . ".timing" , $start, 0.25 );
    #    return 1;
    #}

    # otherwise don't autoreg
    $pf::StatsD::statsd->end(called() . ".timing" , $start, 0.25 );
    return 0;
}

=head2 isInlineTrigger

Return true if a radius properties match with the inline trigger

=cut

sub isInlineTrigger {
    my ($self, $args) = @_;
    my $logger = $self->logger;
    if (defined($args->{'switch'}->{_inlineTrigger}) && $args->{'switch'}->{_inlineTrigger} ne '') {
        foreach my $trigger (@{$args->{'switch'}->{_inlineTrigger}})  {

            # TODO we should refactor this into objects where trigger types provide their own matchers
            # at first, we are liberal in what we accept
            if ($trigger !~ /^\w+::(.*)$/) {
                $logger->warn("[$args->{'mac'}] Invalid trigger id ($trigger)");
                return $FALSE;
            }

            my ( $type, $tid ) = split( /::/, $trigger );
            $type = lc($type);
            $tid =~ s/\s+$//; # trim trailing whitespace

            return $TRUE if ($type eq $ALWAYS);

            # make sure trigger is a valid trigger type
            # TODO refactor into an ListUtil test or an hash lookup (see Perl Best Practices)
            if ( !grep( { lc($_) eq $type } $args->{'switch'}->inlineCapabilities ) ) {
                $logger->warn("Invalid trigger type ($type), this is not supported by this switch (" . $args->{'switch'}->{_id} . ")");
                return $FALSE;
            }
            return $TRUE if (($type eq $MAC) && ($args->{'mac'} eq $tid));
            return $TRUE if (($type eq $PORT) && ($args->{'port'} eq $tid));
            return $TRUE if (($type eq $SSID) && ($args->{'ssid'} eq $tid));
        }
    }
}

sub _check_bypass {
    my ( $args ) = @_;
    my $logger = get_logger();

    # Bypass VLAN/role is configured in node record so we return accordingly
    if ( defined( $args->{'node_info'}->{'bypass_vlan'} ) && ( $args->{'node_info'}->{'bypass_vlan'} ne '' ) ) {
        $logger->info( "A bypass VLAN is configured. Returning VLAN: " . $args->{'node_info'}->{'bypass_vlan'} );
        return ({vlan => $args->{'node_info'}->{'bypass_vlan'}});
    }
    elsif ( defined( $args->{'node_info'}->{'bypass_role'} ) && ( $args->{'node_info'}->{'bypass_role'} ne '' ) ) {
        $logger->info( "A bypass Role is configured. Returning Role: " . $args->{'node_info'}->{'bypass_role'} );
        return ({role => $args->{'node_info'}->{'bypass_role'}});
    }
    else {
        return undef;
    }
}

=head2 logger

Return the current logger for the switch

=cut

sub logger {
    my ($proto) = @_;
    return get_logger( ref($proto) || $proto );
}


=head2 filterVlan

Filter the vlan based off vlan filters

=cut

sub filterVlan {
    my ($self, $scope, $args) = @_;
    my $start = Time::HiRes::gettimeofday();
    my $filter = pf::access_filter::vlan->new;
    $args->{'owner'}= lazy { person_view($args->{'node_info'}->{'pid'}) };
    my $role = $filter->filter($scope, $args);
    $pf::StatsD::statsd->end(called() . ".timing" , $start, 0.1 );
    return $role;
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

# vim: set shiftwidth=4:
# vim: set expandtab:
# vim: set backspace=indent,eol,start:
