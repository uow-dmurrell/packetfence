package captiveportal::PacketFence::Controller::Authenticate;

use Moose;
use namespace::autoclean;
use pf::constants;
use pf::constants::eap_type qw($EAP_TLS);
use pf::config;
use pf::web qw(i18n i18n_format);
use pf::node;
use pf::util;
use pf::config::util;
use pf::locationlog;
use pf::authentication;
use pf::Authentication::constants;
use HTML::Entities;
use List::MoreUtils qw(any uniq);
use pf::config;
use pf::person qw(person_modify);
use Email::Valid;

our @PERSON_FIELDS = grep {
    $_ ne 'pid'
    && $_ ne 'notes'
    && $_ ne 'portal'
    && $_ ne 'source'
} @pf::person::FIELDS;

BEGIN { extends 'captiveportal::Base::Controller'; }

=head1 NAME

captiveportal::PacketFence::Controller::Authenticate - Catalyst Controller

=head1 DESCRIPTION

Catalyst Controller.

=cut

__PACKAGE__->config(
    {   action_args => {
            index => {
                valid_modes => {
                    aup        => 'aup',
                    status     => 'status',
                    release    => 'release',
                    next_page  => 'next_page',
                    deregister => 'deregister',
                }
            }
        }
    }
);

=head1 METHODS

=head2 begin

=cut

sub begin : Private {
    my ( $self, $c ) = @_;
    $c->forward(CaptivePortal => 'validateMac');
}

=head2 index

=cut

sub index : Path : Args(0) {
    my ( $self, $c ) = @_;
    my $mode   = $c->request->param('mode');
    if ( defined $mode ) {
        my $path = $self->modeToPath( $c, $mode );
        $c->go($path);
    } else {
        $c->detach('login');
    }
}

sub modeToPath {
    my ( $self, $c, $mode ) = @_;
    my $action = $c->action;
    my $path   = 'default';
    if ( exists $action->{valid_modes}{$mode} ) {
        $path = $action->{valid_modes}{$mode};
    }
    return $path;
}

sub default : Path {
    my ( $self, $c ) = @_;
    $self->showError($c,"error: incorrect mode");
}

sub next_page : Local : Args(0) {
    my ( $self, $c ) = @_;
    my $profile = $c->profile;
    my $pagenumber = $c->request->param('page');

    $pagenumber = 1 if ( !defined($pagenumber) );
    my $last_page = $profile->nbregpages;

    if (   ( $pagenumber >= 1 )
        && ( $pagenumber <= $last_page ) ) {

        $c->stash( reg_page_content_file => "register_$pagenumber.html", );

        # generate list of locales
        my $authorized_locale_txt = $Config{'general'}{'locale'};
        my @authorized_locale_array = split( /,/, $authorized_locale_txt );
        my @locales;
        if ( scalar(@authorized_locale_array) == 1 ) {
            push @locales,
              { name => 'locale', value => $authorized_locale_array[0] };
        } else {
            foreach my $authorized_locale (@authorized_locale_array) {
                push @locales,
                  { name => 'locale', value => $authorized_locale };
            }
        }
        $c->stash->{'list_locales'} = \@locales;

        if ( $pagenumber == $last_page ) {
            $c->stash->{'button_text'} =
              $Config{'registration'}{'button_text'};
            if($profile->guestRegistrationOnly) {
                $c->stash->{'form_action'} = '/signup';
            } else {
                $c->stash->{'form_action'} = '/authenticate';
            }
        } else {
            $c->stash->{'button_text'} = "Next page";
            $c->stash->{'form_action'} =
              '/authenticate?mode=next_page&page=' . ( int($pagenumber) + 1 );
        }

        $c->stash->{template} = 'register.html';
    } else {
        $self->showError($c,"error: invalid page number" );
    }
}

sub deregister : Local : Args(0) {
    my ( $self, $c ) = @_;
    $c->forward('authenticationLogin');
    unless ( $c->has_errors ) {
        my $portalSession = $c->portalSession;
        my $mac           = $portalSession->clientMac;
        my $node_info     = node_view($mac);
        my $pid           = $node_info->{'pid'};
        if ( $c->session->{username} eq $pid ) {
            pf::node::node_deregister($mac);
        } else {
            $self->showError($c,"error: access denied not owner" );
        }
    } else {
        $c->forward('login');
    }
}

sub authenticateUser {
    my ( $self, $portalSession ) = @_;
}

sub aup : Local : Args(0) {
    my ( $self, $c ) = @_;
    $c->detach( 'Aup', 'index' );
}

sub status : Local : Args(0) {
    my ( $self, $c ) = @_;
    $c->detach( 'Status', 'index' );
}

sub login : Local : Args(0) {
    my ( $self, $c ) = @_;
    if ( $c->request->method eq 'POST' ) {

        # External authentication
        $c->forward('validateLogin');
        $c->forward('enforceLoginRetryLimit');
        $c->forward('authenticationLogin');
        $c->detach('showLogin') if $c->has_errors;
        $c->forward('validateMandatoryFields');
        $c->forward('postAuthentication');
        $c->forward( 'CaptivePortal' => 'webNodeRegister', [$c->stash->{info}->{pid}, %{$c->stash->{info}}] );
        $c->forward( 'CaptivePortal' => 'endPortalSession' );
    }

    # Return login
    $c->forward('showLogin');

}

=head2 enforceLoginRetryLimit

Limit the amount of time a user can retry a password

=cut

sub enforceLoginRetryLimit : Private {
    my ($self, $c) = @_;
    my $username = $c->request->param("username");
    if ($username) {
        if ($self->reached_retry_limit($c, "login_retries", $c->profile->{'_login_attempt_limit'})) {
            $c->log->info("Max tries reached login code for $username");
            $c->stash(txt_auth_error => i18n_format($GUEST::ERRORS{$GUEST::ERROR_MAX_RETRIES}));
            $c->detach('showLogin');
        }
    }
}

=head2 postAuthentication

TODO: documention

=cut

sub postAuthentication : Private {
    my ( $self, $c ) = @_;
    my $logger = $c->log;
    $c->detach('showLogin') if $c->has_errors;
    $c->forward("checkIfChainedAuth");
    my $portalSession = $c->portalSession;
    my $session = $c->session;
    my $profile = $c->profile;
    my $source_id = $session->{source_id};
    my $info = $c->stash->{info} ||= {};
    my $pid = $session->{"username"};
    $pid = $default_pid if !defined $pid && $c->profile->noUsernameNeeded;
    $info->{pid} = $pid;
    $c->stash->{info} = $info;
    # We make sure the person exists and assign it to the device
    if ( !pf::person::person_exist($pid) ) {
        person_add($pid);
    }

    # if PID is a valid e-mail we add it to the appropriate field
    if(Email::Valid->address($pid)){
        person_modify($pid, email => $pid);
    }

    node_modify($portalSession->clientMac, (pid => $pid));

    $c->forward('setupMatchParams');
    $c->forward('setRole');
    $c->forward('setUnRegDate');
    $c->log->trace("Just finished seting the node up");
    $info->{source} = $source_id;
    $info->{portal} = $profile->getName;
    $c->forward('checkIfProvisionIsNeeded');
    $c->log->trace("Passed by the provisioning");
}

=head2 checkIfChainedAuth

Checked to see if source that was authenticated with is chained

=cut

sub checkIfChainedAuth : Private {
    my ($self, $c) = @_;
    my $source_id = $c->session->{source_id};
    my $source = getAuthenticationSource($source_id);
    #if not chained then leave
    return unless $source->type eq 'Chained';
    my $chainedSource = $source->getChainedAuthenticationSourceObject();
    if( $chainedSource && $self->isGuestSigned($c,$chainedSource)) {
        $c->session->{chained_source} = $source->id;
        $self->setAllowedGuestModes($c,$chainedSource);
        $c->detach(Signup => 'showSelfRegistrationPage');
    }
}

our %GUEST_SOURCE_TYPES = (
    SMS          => 'sms_guest_allowed',
    Email        => 'email_guest_allowed',
    SponsorEmail => 'sponsored_guest_allowed',
);

=head2 isGuestSigned

Checks to see if the source is a signup source

=cut

sub isGuestSigned {
    my ($self, $c, $chainedSource) = @_;
    return exists $GUEST_SOURCE_TYPES{$chainedSource->type};
}

=head2 setAllowedGuestModes

Overrides the default guest_modes

=cut

sub setAllowedGuestModes {
    my ($self, $c, $chainedSource) = @_;
    my $modes = {
        sms_guest_allowed       => 0,
        email_guest_allowed     => 0,
        sponsored_guest_allowed => 0,
    };
    $modes->{$GUEST_SOURCE_TYPES{$chainedSource->type}} = 1;
    $c->session->{allowed_guest_modes} = $modes;
}

=head2 setupMatchParams

setup the parameters to match against the rules in the sources to apply actions

=cut

sub setupMatchParams : Private {
    my ( $self, $c ) = @_;
    my $portalSession = $c->portalSession;
    my $pid = $c->stash->{info}->{pid};
    my $mac = $portalSession->clientMac;
    my $params = { username => $pid, mac => $mac };

    # TODO : add current_time and computer_name
    my $locationlog_entry = locationlog_view_open_mac($mac);
    if ($locationlog_entry) {
        $params->{connection_type} = $locationlog_entry->{'connection_type'};
        $params->{SSID}            = $locationlog_entry->{'ssid'};
    }
    $c->stash->{matchParams} = $params;
}

sub setRole : Private {
    my ( $self, $c ) = @_;
    my $logger = $c->log;
    my $session = $c->session;
    my $params = $c->stash->{matchParams};
    my $info = $c->stash->{info};
    my $pid = $info->{pid};
    my $mac = $c->portalSession->clientMac;
    my $source_match = $session->{source_match} || $session->{source_id};

    # obtain node information provided by authentication module. We need to get the role (category here)
    # as web_node_register() might not work if we've reached the limit
    my $value = &pf::authentication::match( $source_match, { %$params, rule_class => 'authentication' }, $Actions::SET_ROLE );

    # This appends the hashes to one another. values returned by authenticator wins on key collision
    if ( defined $value ) {
        $logger->debug("Got role '$value' for username \"$pid\"");
        $info->{category} = $value;
    } else {
        $logger->info("Got no role for username \"$pid\"");
        $self->showError($c, "You do not have the permission to register a device with this username.");
    }
    $c->stash(
        role => $value,
    );
    node_modify($mac, (category => $value));
}

sub setUnRegDate : Private {
    my ( $self, $c ) = @_;
    my $logger = $c->log;
    my $session = $c->session;
    my $params = $c->stash->{matchParams};
    my $info = $c->stash->{info};
    my $pid = $info->{pid};
    my $mac = $c->portalSession->clientMac;
    my $source_match = $session->{source_match} || $session->{source_id};
    # If an access duration is defined, use it to compute the unregistration date;
    # otherwise, use the unregdate when defined.
    my $value = &pf::authentication::match( $source_match, $params, $Actions::SET_UNREG_DATE );
    if ( defined $value ) {
        $logger->debug("Got unregdate $value for username \"$pid\"");
        $info->{unregdate} = $value;
    }
    else {
        $logger->info("Got no unregdate for username \"$pid\"");
        $self->showError($c, "The username you have used does not match any configured unregistration date.");
    }

    # We put the unregistration date in session since we may want to use it later in the flow
    $c->session->{unregdate} = $info->{unregdate};
    node_modify($mac, (unregdate => $info->{unregdate}));
}

sub createLocalAccount : Private {
    my ( $self, $c, $auth_params ) = @_;
    my $logger = $c->log;

    $logger->debug("External source local account creation is enabled for this source. We proceed");

    # We create a "password" (also known as a user account) using the pid
    # with different parameters coming from the authentication source (ie.: expiration date)
    my $actions = &pf::authentication::match( $c->session->{source_id}, $auth_params );

    # We push an unregistration date that was previously calculated (setUnRegDate) that handle dynamic unregistration date and access duration
    my $action = pf::Authentication::Action->new({
        type    => $Actions::SET_UNREG_DATE, 
        value   => $c->session->{unregdate},
        class   => pf::Authentication::Action->getRuleClassForAction($Actions::SET_UNREG_DATE),
    });
    # Hack alert: We may already have a "SET_UNREG_DATE" action in the array and since the way the authentication framework is working is by going
    # through the actions on a first hit match, we want to make sure the unregistration date we computed (because we are taking care of the access duration,
    # dynamic date, ...) will be the first in the actions array.
    unshift (@$actions, $action);

    my $password = pf::password::generate($auth_params->{username}, $actions, $c->stash->{sms_pin});

    # We send the guest and email with the info of the local account
    my %info = (
        'pid'       => $auth_params->{username},
        'password'  => $password,
        'email'     => $auth_params->{user_email},
        'subject'   => i18n_format(
            "%s: Guest account creation information", $Config{'general'}{'domain'}
        ),
    );
    pf::web::guest::send_template_email(
            $pf::web::guest::TEMPLATE_EMAIL_LOCAL_ACCOUNT_CREATION, $info{'subject'}, \%info
    );

    # We put some value in stash for web portal consumption
    # Note: Only used on email on-site registration
    $c->stash (
        local_account_creation  => $TRUE,
        pid                     => $auth_params->{username},
        password                => $password,
    );

    $logger->info("Local account for external source " . $c->session->{source_id} . " created with PID " . $auth_params->{username});
}

sub checkIfProvisionIsNeeded : Private {
    my ( $self, $c ) = @_;
    my $portalSession = $c->portalSession;
    my $mac = $portalSession->clientMac;
    my $profile = $c->profile;
    if (defined( my $provisioner = $profile->findProvisioner($mac))) {
        $c->log->info("Found provisioner " . $provisioner->id . " for $mac");
        my $info = $c->stash->{info};
        if($provisioner->getPkiProvider && ($provisioner->{eap_type} eq $EAP_TLS) ) {
            $c->log->info("Detected PKI provider for $mac.");
            $c->session->{info} = $c->stash->{info};
            $c->response->redirect('/tlsprofile');
            $c->detach();
        }
        elsif ($provisioner->authorize($mac) == 0) {
            $info->{status} = $pf::node::STATUS_PENDING;
            node_modify($mac, %$info);
            $c->stash(
                template    => $provisioner->template,
                provisioner => $provisioner,
            );
            $c->detach();
        }
    }
}

sub validateLogin : Private {
    my ( $self, $c ) = @_;
    my $logger  = $c->log;
    my $profile = $c->profile;
    $logger->debug("form validation attempt");

    my $request = $c->request;
    my $no_password_needed = $profile->noPasswordNeeded;
    my $no_username_needed = $profile->noUsernameNeeded;

    if (   ( $request->param("username") || $no_username_needed )
        && ( $request->param("password") || $no_password_needed ) ) {

        # acceptable use pocliy accepted?
        my $aup_signed = $request->param("aup_signed");
        if (   !defined($aup_signed)
            || !$aup_signed ) {
            $self->showError($c,'You need to accept the terms before proceeding any further.');
            $c->detach('showLogin');
        }
    } else {
        $c->detach('showLogin');
    }
}

sub authenticationLogin : Private {
    my ( $self, $c ) = @_;
    my $logger  = $c->log;
    my $request = $c->request;
    my $profile = $c->profile;
    my $portalSession = $c->portalSession;
    my $mac           = $portalSession->clientMac;
    my ( $return, $message, $source_id );
    $logger->debug("authentication attempt");
    if ($request->{'match'} eq "status/login") {
        use pf::person;
        my $person_info = pf::person::person_view($request->param("username"));
        my $source = pf::authentication::getAuthenticationSource($person_info->{source});
        if (defined($source) && $source->{'class'} eq 'external') {
            # Source is external, we have to use local source to authenticate
            $c->stash( use_local_source => 1 );
        }
        my $options = {
            'portal' => $person_info->{portal},
        };
        $profile = pf::Portal::ProfileFactory->instantiate( $mac, $options);
    }
    $c->stash( profile => $profile );


    my $username = _clean_username($request->param("username"));
    my $realm;
    ($username, $realm) = strip_username($username);
    my $password = $request->param("password");

    my @sources = $self->getSources($c, $username, $realm);

    if(isenabled($profile->reuseDot1xCredentials)) {
        my $mac       = $portalSession->clientMac;
        my $node_info = node_view($mac);
        my $username = $node_info->{'last_dot1x_username'};
        if ($username =~ /^(.*)@/ || $username =~ /^[^\/]+\/(.*)$/ ) {
            $username = $1;
        }
        $c->session(
            "username"  => $username,
            "source_id" => $sources[0]->id,
            "source_match" => \@sources,
        );
    } else {
        # validate login and password
        ( $return, $message, $source_id ) =
          pf::authentication::authenticate( { 'username' => $username, 'password' => $password, 'rule_class' => $Rules::AUTH }, @sources );
        if ( defined($return) && $return == 1 ) {
            pf::auth_log::record_auth($source_id, $portalSession->clientMac, $username, $pf::auth_log::COMPLETED);
            # save login into session
            $c->session(
                "username"  => $username // $default_pid,
                "source_id" => $source_id,
                "source_match" => $source_id,
            );
            # Logging USER/IP/MAC of the just-authenticated user
            $logger->info("Successfully authenticated ".$username."/".$portalSession->clientIp."/".$portalSession->clientMac);
        } else {
            pf::auth_log::record_auth(join(',',map { $_->id } @sources), $portalSession->clientMac, $username, $pf::auth_log::FAILED);
            $c->error($message);
        }
    }
}

=head2 getSources

Return the source to use to login

=cut

sub getSources : Private {
    my ($self,$c,$stripped_username,$realm) = @_;
    my @sources;
    my $use_local_source = $c->stash->{use_local_source};
    my $profile = $c->stash->{profile};

    if ($use_local_source) {
        @sources = pf::authentication::getAuthenticationSource('local');
    } else {
        #If we try to validate a sponsor access then use all Internal Sources
        if ($c->request->{'match'} =~ "activate/email") {
            @sources = @{pf::authentication::getInternalAuthenticationSources()};
        } else {
            @sources =
                ( $profile->getInternalSources, $profile->getExclusiveSources );
        }
    }

    my $realm_source = get_realm_source($stripped_username, $realm);
    if( $realm_source && any { $_ eq $realm_source} @sources ){
        $c->log->info("Realm source is part of the portal profile sources. Using it as the only auth source.");
        return ($realm_source);
    }
    elsif ( $realm_source ) {
        $c->log->info("Realm source ".$realm_source->id." is configured in the realm $realm but is not in the portal profile. Ignoring it and using the portal profile sources.");
    }
    return @sources;
}

sub showLogin : Private {
    my ( $self, $c ) = @_;
    my $profile    = $c->profile;
    my $guestModes = $profile->getGuestModes;
    my $guest_allowed =
      any { is_in_list( $_, $guestModes ) } $SELFREG_MODE_EMAIL,
      $SELFREG_MODE_SMS, $SELFREG_MODE_SPONSOR;
    my @sources = $profile->getInternalSources;
    my $request = $c->request;
    if ( $c->has_errors ) {
        $c->stash->{txt_auth_error} = join(' ', grep { ref ($_) eq '' } @{$c->error});
        $c->clear_errors;
    }
    $c->stash(
        template        => 'login.html',
        username        => $request->param_encoded("username") ,
        null_source     => is_in_list( $SELFREG_MODE_NULL, $guestModes ) || is_in_list( $SELFREG_MODE_KICKBOX, $guestModes ),
        oauth2_github   => is_in_list( $SELFREG_MODE_GITHUB, $guestModes ),
        oauth2_google   => is_in_list( $SELFREG_MODE_GOOGLE, $guestModes ),
        no_username     => $profile->noUsernameNeeded,
        no_password     => $profile->noPasswordNeeded,
        oauth2_facebook => is_in_list( $SELFREG_MODE_FACEBOOK, $guestModes ),
        oauth2_linkedin => is_in_list( $SELFREG_MODE_LINKEDIN, $guestModes ),
        oauth2_win_live => is_in_list( $SELFREG_MODE_WIN_LIVE, $guestModes ),
        oauth2_twitter  => is_in_list( $SELFREG_MODE_TWITTER, $guestModes ),
        billing         => $c->profile->hasBilling(),
        guest_allowed   => $guest_allowed,
    );

    # When in a chained source, we prompt mandatory fields on the second source
    my $chain_activated = any { $_->type eq 'Chained' } @sources;
    unless($chain_activated){
        my @mandatory_fields = $profile->getFieldsForSources(@sources);
        $c->stash( mandatory_fields => \@mandatory_fields );
    }

}

sub _clean_username {
    my ($username) = @_;
    return $username unless defined $username;
    # Do cleaning that could be related to a human error input ( like a space after the username )

    # This removes trailing and leading whitespaces
    $username =~ s/^\s+|\s+$//g ;

    return $username;
}

sub validationError {
    my ( $self, $c, $error_code, @error_args ) = @_;
    $self->createValidationErrorMessage( $c, $error_code, @error_args );
    $c->detach('showLogin');
}

sub createValidationErrorMessage {
    my ( $self, $c, $error_code, @error_args ) = @_;
    $c->stash->{'txt_validation_error'} =
      i18n_format( $GUEST::ERRORS{$error_code}, @error_args );
    utf8::decode($c->stash->{'txt_validation_error'});
}

sub validateMandatoryFields : Private {
    my ( $self, $c, %options ) = @_;
    # we detach by default
    $options{detach} = defined($options{detach}) ? $options{detach} : 1;
    my $request = $c->request;
    my $session = $c->session;
    my $profile    = $c->profile;
    my ( $error_code, @error_args );

    my $source = getAuthenticationSource($session->{source_id});

    $c->log->info("Finding mandatory fields for source : ".$source->id);

    # When in a chained source, we prompt mandatory fields on the second source
    if($source->type eq "Chained"){
        return;
    }

    my @mandatory_fields = $profile->getFieldsForSources($source);
    my %mandatory_fields = map { $_ => undef } @mandatory_fields;
    my @missing_fields = grep { !$request->param($_) } @mandatory_fields;

    if (@missing_fields) {
        $error_code = $GUEST::ERROR_MISSING_MANDATORY_FIELDS;
        @error_args = ( join( ", ", map { i18n($_) } @missing_fields ) );
    } elsif ( exists $mandatory_fields{email}
              && !pf::web::util::is_email_valid( $request->param('email') ) ) {
        $error_code = $GUEST::ERROR_ILLEGAL_EMAIL;
    } elsif ( exists $mandatory_fields{phone}
              && !pf::web::util::validate_phone_number( $request->param('phone') ) ) {
        $error_code = $GUEST::ERROR_ILLEGAL_PHONE;
    } elsif ( !length( $request->param("aup_signed") ) ) {
        $error_code = $GUEST::ERROR_AUP_NOT_ACCEPTED;
    }

    if ( defined $error_code && $error_code != 0 ) {
        if($options{detach}){
            $self->validationError( $c, $error_code, @error_args );
        }
        else {
            $self->createValidationErrorMessage( $c, $error_code, @error_args );
        }
    } else {
        $c->forward('setupSession');
        _update_person($session,$profile);
    }
}

sub setupSession : Private {
    my ( $self, $c ) = @_;
    my $request = $c->request;
    foreach my $field (@PERSON_FIELDS) {
        $c->session->{$field} = $request->param($field);
    }
    my $phone = $request->param("phone");
    $c->session->{telephone} =
      pf::web::util::validate_phone_number( $phone );
    $c->session->{phone} =
      pf::web::util::validate_phone_number( $phone );
}

sub _update_person {
  my ($session,$profile) = @_;
  my @info = (
      (map { my $v = $session->{$_}; defined $v ? ($_ => $session->{$_}) :() } @PERSON_FIELDS),
      'portal'    => $profile->getName,
      'source'    => $session->{source_id},
  );
  person_modify($session->{username}, @info);
}

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

__PACKAGE__->meta->make_immutable;

1;
