package PCG::api;
################################################################################
#                                                                              #
# PCG - Puppet Cloud Gateway                                                   #
#                                                                              #
#          see https://github.com/Q-Technologies/PCG for project info          #
#                                                                              #
# Copyright 2017 - Q-Technologies (http://www.Q-Technologies.com.au)           #
#                                                                              #
#                                                                              #
# Revision History                                                             #
#                                                                              #
#    Aug 2017 - Initial release.                                               #
#                                                                              #
################################################################################

use Dancer2;
use Dancer2::Plugin::Ajax;
use PCG;
use qutil;
use Data::Dumper;
use File::Basename;
use POSIX qw(strftime);
use 5.10.0;

use constant SUCCESS => "success";
use constant FAILED => "failed";

set serializer => 'JSON';

our $VERSION = '0.1';

ajax '/login' => sub {
    my ( $result, $msg ) = check_login();
    { result => $result, message=> $msg };
};

ajax '/logout' => sub {
    session->destroy;
    { result => SUCCESS, message=> "Successfully logged out and session destroyed" };
};

ajax '/do' => sub {
    # Process inputs
    my %allparams = params;
    my $payload = param "PayLoad";
    my $action = param "Action";
    my $event = param "Event";

    my $function = "do";
    my $result = FAILED;
    my $msg = "";
    my $data;

    #debug (Dumper( \%allparams ) );

    # Check whether the user is logged in
    ( $result, $msg ) = check_login();
    return { result => $result, function => $function, message=> $msg } if( $result ne SUCCESS );

    # perform the requested action
    if( ref($payload) eq 'ARRAY' ){
        ( $result, $msg, $data ) = do_action( $payload, $action, $event ); 
    } else {
        $msg = "Invalid payload";
        $result = FAILED;
    }
    { result => $result, function => $function, message=> $msg, data => $data };


};

ajax '/list' => sub {
    # Process inputs
    my %allparams = params;
    my $query = param "Query";

    my $function = 'list';
    my $result = SUCCESS;
    my $msg = "";
    my $data;

    # Check whether the user is logged in
    ( $result, $msg ) = check_login();
    return { result => $result, function => $function, message=> $msg } if( $result ne SUCCESS );

    # perform the requested action and return result
    if( ref($query) eq 'HASH' ){
        ( $result, $msg, $data ) = list_options( $query ); 
    } else {
        $msg = "Invalid query command";
        $result = FAILED;
    }
    { result => $result, function => $function, message=> $msg, data => $data };

};

ajax '/check' => sub {
    # Process inputs
    my %allparams = params;
    my $hostname = param "hostname";
    say Dumper( \%allparams );

    my $function = 'check';
    my $result = SUCCESS;
    my $msg = "";
    my $data;

    # Check whether the user is logged in
    ( $result, $msg ) = check_login();
    return { result => $result, function => $function, message=> $msg } if( $result ne SUCCESS );

    # perform the requested action and return result
    if( $hostname ){
        ( $result, $msg, $data ) = check_host( $hostname ); 
    } else {
        $msg = "Invalid hostname to check";
        $result = FAILED;
    }
    { result => $result, function => $function, message=> $msg, data => $data };

};

1;
