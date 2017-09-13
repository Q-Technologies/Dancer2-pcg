#!/usr/bin/env perl

################################################################################
#                                                                              #
# PCG - Puppet Cloud Gateway - use Puppet to provision the cloud               #
#                                                                              #
# This web service creates an API gateway to make it easier to use Puppet to   #
# provision in the cloud.                                                      #
#                                                                              #
# It is written in Perl using the Dancer2 Web Framework (a lightweight         #
# framework based on Sinatra for Ruby).  It does not provide a web             #
# browser interface, but JSON can be sent and received as XMLHttpRequest       #
# object                                                                       #
#                                                                              #
#          see https://github.com/Q-Technologies/PCG for full details          #
#                                                                              #
#                                                                              #
# Copyright 2017 - Q-Technologies (http://www.Q-Technologies.com.au            #
#                                                                              #
#                                                                              #
# Revision History                                                             #
#                                                                              #
#    Aug 2017 - Initial release                                                #
#                                                                              #
# Issues                                                                       #
#   *                                                                          #
#                                                                              #
################################################################################

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Plack::Builder;

use PCG::api;

builder {
    mount '/api' => PCG::api->to_app;
};


