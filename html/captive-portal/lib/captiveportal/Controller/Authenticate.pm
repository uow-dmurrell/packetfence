package captiveportal::Controller::Authenticate;
use Moose;

use pf::util;

BEGIN {extends 'captiveportal::PacketFence::Controller::Authenticate';}

use pf::util;
use pf::authentication;

=head1 NAME

captiveportal::Controller::Root - Root Controller for captiveportal

=head1 DESCRIPTION

[enter your description here]

=cut

before postAuthentication => sub {
    my ($self, $c) = @_;
    my $session   = $c->session;
    my $source_id = $session->{source_id};
    return unless defined $source_id;
    my $source = getAuthenticationSource($source_id);
    return unless defined $source && $source->can("post_auth_step");
    my $continue_post_auth = $session->{continue_post_auth};
    unless ($continue_post_auth || isdisabled($source->post_auth_step)) {
        $c->stash({template => 'post-auth-page.html'});
        $c->detach();
    }
};

sub continue_post_auth : Local {
    my ($self, $c) = @_;
    $c->session->{continue_post_auth} = 1;
    $c->forward('postAuthentication');
    $c->forward( 'CaptivePortal' => 'webNodeRegister', [$c->stash->{info}->{pid}, %{$c->stash->{info}}] );
    $c->forward( 'CaptivePortal' => 'endPortalSession' );
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

__PACKAGE__->meta->make_immutable;

1;
