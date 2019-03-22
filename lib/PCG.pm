package PCG;
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

use strict;
use Data::Dumper;
use YAML::XS qw(Dump Load LoadFile);
use POSIX qw/strftime/;
use Capture::Tiny ':all';
use JSON;
use 5.10.0;
use File::Spec::Functions;
use Dancer2::Plugin;
use Dancer2::Plugin::DBIC;
use qutil;
use DBI qw(:sql_types);
use Type::Tiny;
use Net::SSH::Perl;
use POSIX ":sys_wait_h";

use constant SUCCESS => "success";
use constant FAILED => "failed";
use constant WAITING => 0;
use constant PROCESSING => 1;
use constant COMPLETED_OK => 2;
use constant COMPLETED_WITH_ERRORS => 3;

# Define globals
our $VERSION = '0.1';
my @log;

# Define variables to hold settings
has 'clouds' => (
    is                     => 'rw',
    required               => 1,
    default                => sub { {} },
);
has 'app_sub_envs' => (
    is                     => 'rw',
    required               => 1,
    default                => sub { {} },
);
has 'default_cloud' => (
    is                     => 'rw',
    required               => 1,
    default                => sub { {} },
);
has 'records_db_file' => (
    is => 'rw', 
    required => 1,
    default => 'records.sqlite',
    predicate => 'has_records_db_file',
);
has 'installed_by_user' => (
    is => 'rw', 
    required => 1,
    default => 'pcg',
    predicate => 'has_installed_by_user',
);
has 'puppet_master' => (
    is => 'rw', 
    required => 1,
    default => 'puppet',
    predicate => 'has_puppet_master',
);

has 'hostname_naming' => (
    is => 'rw', 
    required => 1,
    #default => '[a-z0-9]+',
    default                => sub { {} },
    predicate => 'has_hostname_naming',
);

has 'agent_script_uri' => (
    is => 'rw', 
    required => 1,
    default => 'localhost',
    predicate => 'has_agent_script_uri',
);

plugin_keywords qw/
    do_action
    check_hostname_is_ok
    check_host_exists
    list_options
    hiera_lookup
/;

sub BUILD {
    my $self = shift;
    # The following settings must be set - we can easily check there is a hash, but no much else
    if( keys %{ $self->app->config->{clouds} } ){
        $self->clouds( $self->app->config->{clouds} );
    } else {
        die "You need to set the clouds hash in the config file";
    }
    if( keys %{ $self->app->config->{app_sub_envs} } ){
        $self->app_sub_envs( $self->app->config->{app_sub_envs} );
    } else {
        die "You need to set the app_sub_envs hash in the config file";
    }
    if( keys %{ $self->app->config->{hostname_naming} } ){
        $self->hostname_naming( $self->app->config->{hostname_naming} );
    } else {
        die "You need to set the hostname_naming hash in the config file";
    }

    # The following settings have reasonable defaults (will not break the program,
    # but will probably not make sense for the business context)
    if( keys %{ $self->app->config->{default_cloud} } ){
        $self->default_cloud( $self->app->config->{default_cloud} );
    }
    if( defined( $self->app->config->{records_db_file}) ){
        $self->records_db_file( $self->app->config->{records_db_file} );
    }
    if( defined( $self->app->config->{installed_by_user}) ){
        $self->installed_by_user( $self->app->config->{installed_by_user} );
    }
    if( defined( $self->app->config->{puppet_master}) ){
        $self->puppet_master( $self->app->config->{puppet_master} );
    }
    if( defined( $self->app->config->{agent_script_uri}) ){
        $self->agent_script_uri( $self->app->config->{agent_script_uri} );
    }

}

################################################################################
#
# The following subs are used by the API
#
################################################################################

# Perform an action
sub do_action {
    my $self = shift;
    #say Dumper( $self );
    my $action = shift;
    #say $action;
    my $event = shift;
    my $payload = shift;

    my $data = {};
    my $result = SUCCESS;
    my $msg;
        my @stacks;

    if( $action eq 'list_stacks'){
        return $result, $msg, { stacks => $self->list_stacks_in_db };
    }

    # Process stacks - resubmit to this sub as instances
    if( $action eq 'create_stack' and ref($payload) eq 'ARRAY' ){
        my $roles;
        # get all the roles - perform at each run so new ones are picked up
        ( $result, $msg, $roles ) = $self->get_roles();
        return ( $result, $msg ) if $result ne SUCCESS;
        my $stacks;
        my $new_payload = [];
        # get all the stacks - perform at each run so new ones are picked up
        ( $result, $msg, $stacks ) = $self->get_stacks();
        return ( $result, $msg ) if $result ne SUCCESS;
        $self->dsl->debug( Dumper( $stacks, $payload, $roles ) );
        for my $req ( @$payload ){
            $self->get_defaults( $req );
            my $stack = $req->{name};
            $stack = $self->get_unique_stack_name( $stack, $req->{app_sub_env} );
            push @stacks, $stack;
            my $stack_id = $self->add_stack_to_db( $stack );
            $self->dsl->debug( "We are using stack id: $stack_id" );
            my $stack_roles = $stacks->{$req->{name}};
            for my $role (keys %$stack_roles){
                for my $instance ( @{ $stack_roles->{$role} } ){
                    my $new_req = { %$req };
                    my $name4hostname = $roles->{$role}{name4hostname};
                    $name4hostname = $instance->{name4hostname} if $instance->{name4hostname};
                    $new_req->{name} = $self->get_hostname( $new_req->{app_sub_env}, $name4hostname, $stack_id );
                    $new_req->{role} = $role;
                    $new_req->{os} = $instance->{os} if $instance->{os};
                    $new_req->{size} = $instance->{size} if $instance->{size};
                    $new_req->{stack} = $stack;
                    $self->dsl->debug( "Hostname: ".$new_req->{name}.", OS: ". $new_req->{os});
                    push @$new_payload, $new_req;
                }
            }
        }
        #return $result, $msg, $new_payload;
        ( $result, $msg, $data ) = $self->create_or_destroy_instances( 'create', $event, $new_payload );
        if( $result eq SUCCESS ){
            return ( $result, $msg, { result => 'stacks added successfully', stacks => \@stacks } );
        } else {
            return $result, $msg;
        }
        #$data = "Processing stacks";
        #return $result, $msg, $data;
    } elsif( $action =~ /^(destroy_stack|show_stack)$/ and ref($payload) eq 'ARRAY' ){
        # get all the stacks - perform at each run so new ones are picked up
        my $new_full_payload = [];
        my $show_data = [];
        for my $req ( @$payload ){
            my $new_payload = [];
            $self->get_defaults( $req );
            my $stack = $req->{name};
            push @stacks, $stack;
            my $instances = $self->list_stack_instances_in_db( $stack );
            for my $instance ( @{ $instances } ){
                my $new_req = { %$req };
                $new_req->{name} = $instance;
                $self->dsl->debug( "Adding stack: ".$new_req->{name}." to payload" );
                push @$new_payload, $new_req;
            }
            if( $action =~ /show/ ){
                if( @$new_payload ){
                    ( $result, $msg, $data ) = $self->show_instances( $action, $event, $new_payload );
                    return $result, $msg if $result ne SUCCESS;
                }
                push @$show_data, { stack_name => $stack, instances => $data };
            }
            push @$new_full_payload, @$new_payload;
            #return $result, $msg, $new_payload;
        }

        if( @$new_full_payload ){
            return $result, $msg, $show_data if $action =~ /show/;
            ( $result, $msg ) = $self->create_or_destroy_instances( "destroy", $event, $new_full_payload );
            if( $result eq SUCCESS ){
                # Ideally we should wait until all child processes have finished before we remove the definition
                # but no time to code that now
                ( $result, $msg, $data ) = $self->remove_stack_from_db( \@stacks );
                if( $result eq SUCCESS ){
                    return $result, $msg, { result => "stacks action ($action) successfully issued", stacks => \@stacks };
                } else {
                    return $result, $msg;
                }
            } else {
                return $result, $msg;
            }
        } else {
            $msg = "There do not appear to be any instances in those stacks";
            $result = FAILED; 
        }
    } elsif( ref($payload) ne 'ARRAY' or not @$payload ){
        $msg = "The payload needs to be an array of requests";
        $result = FAILED; 
    }
    return $result, $msg if $result ne SUCCESS;

    # The following catches individual instances (i.e. non-stacks)

    #For a simple show we can return the data straight away
    if( $action =~ /^(show_*all|show)$/ ){
        return $self->show_instances( $action, $event, $payload );
    } else {
        # For a destroy/create we use a background process
        return $self->create_or_destroy_instances( $action, $event, $payload );
    }
}

# Check whether a hostname is available for use and conforms to the naming standard
sub check_hostname_is_ok {
    my $self = shift;
    my $hostname = shift;
    my $hostname_std = $self->hostname_naming->{standard};
    $hostname_std = qr/^${hostname_std}$/;
    #my $hostname_std = qr/^[a-z0-9]+$/;

    my $result;
    my $msg;

    ( $result, $msg ) = $self->check_host_exists( $hostname );

    if( $result eq SUCCESS ){
        $result = FAILED;
    } else {
        if( $hostname !~ /$hostname_std/ ){
            $msg = "The hostname ($hostname) does not match the naming standard";
        } else {
            $result = SUCCESS; 
        }
    }
    return $result, $msg;
}


# Provide a list of valid options back to the end user to help them construct requests properly
sub list_options {
    my $self = shift;
    my $req = shift;
    my $data = shift;
    my $result = SUCCESS;
    my $msg;
    #say Dumper( $req );

    # set defaults if fields are empty
    $req->{cloud} = $self->default_cloud->{name} unless $req->{cloud};
    $req->{region} = $self->default_cloud->{region} unless $req->{region};
    $req->{size} = $self->default_cloud->{instance_size} unless $req->{size};
    $req->{subnet} = $self->default_cloud->{subnet} unless $req->{subnet};
    $req->{account} = $self->default_cloud->{account} unless $req->{account};
    $req->{os} = $self->default_cloud->{os} unless $req->{os};
    $req->{app_sub_env} = $self->default_cloud->{app_sub_env} unless $req->{app_sub_env};
    $req->{role} = $self->default_cloud->{role} unless $req->{role};

    ( $result, $msg ) = $self->validate_property( $req, "option" ) if $result eq SUCCESS;
    if( $result eq SUCCESS ){
        my $option = $req->{option};
        if( $option =~ /^os(es)*$/ ){
            ( $result, $msg ) = $self->validate_property( $req, "cloud" ) if $result eq SUCCESS;
            ( $result, $msg ) = $self->validate_property( $req, "region" ) if $result eq SUCCESS;
            if( $result eq SUCCESS ){
                $data = [ sort keys %{$self->clouds->{$req->{cloud}}{regions}{$req->{region}}{image_ids}} ];
            }
        } elsif( $option =~ /^role(s)*$/ ){
            my $roles;
            ( $result, $msg, $roles ) = $self->get_roles();
            $data = [ sort keys %{$roles} ];
        } elsif( $option =~ /^account(s)*$/ ){
            ( $result, $msg ) = $self->validate_property( $req, "cloud" ) if $result eq SUCCESS;
            $data = [ sort keys %{$self->clouds->{$req->{cloud}}{accounts}} ];
        } elsif( $option =~ /^region(s)*$/ ){
            ( $result, $msg ) = $self->validate_property( $req, "cloud" ) if $result eq SUCCESS;
            $data = [ sort keys %{$self->clouds->{$req->{cloud}}{regions}} ];
        } elsif( $option =~ /^app_sub_env(s)*$/ ){
            $data = [ sort keys %{ $self->app_sub_envs } ];
        } elsif( $option =~ /^cloud(s)*$/ ){
            $data = [ sort keys %{$self->clouds} ];
        } elsif( $option =~ /^size(s)*$/ ){
            ( $result, $msg ) = $self->validate_property( $req, "cloud" ) if $result eq SUCCESS;
            if( $result eq SUCCESS ){
                $data = $self->clouds->{$req->{cloud}}{sizes};
            }
        } elsif( $option =~ /^zone(s)*$/ ){
            ( $result, $msg ) = $self->validate_property( $req, "region" ) if $result eq SUCCESS;
            ( $result, $msg ) = $self->validate_property( $req, "cloud" ) if $result eq SUCCESS;
            if( $result eq SUCCESS ){
                $data = [ sort keys %{ $self->clouds->{$req->{cloud}}{regions}{$req->{region}}{zones} } ];
            }
        } elsif( $option =~ /^subnet(s)*$/ ){
            ( $result, $msg ) = $self->validate_property( $req, "region" ) if $result eq SUCCESS;
            ( $result, $msg ) = $self->validate_property( $req, "cloud" ) if $result eq SUCCESS;
            ( $result, $msg ) = $self->validate_property( $req, "zone" ) if $result eq SUCCESS;
            if( $result eq SUCCESS ){
                $data = $self->clouds->{$req->{cloud}}{regions}{$req->{region}}{zones}{$req->{zone}}{subnets};
            }
        } else {
            $msg = "Unknown option: $option";
            $result = FAILED; 
        }
    } else {
        $msg = "The request needs to include the option to list";
        $result = FAILED; 
    }
    return $result, $msg, $data;

}

# Perform a lookup of data via a key for Hiera
sub hiera_lookup {
    my $self = shift;
    my %args = @_;
    my $type = "";
    my $name = "";
    
    my $key_found = 0;

    if( $args{stack} ){
        $type = 'stack';
        $name = $args{stack};
    } elsif( $args{host} ){
        $type = 'host';
        $name = $args{host};
    }
    my $hiera_rs;
    eval { $hiera_rs = schema->resultset('HieraData')->find( $type, $name, $args{key}, 
                                                             { key => 'lookup_type_lookup_name_key_unique' },
                                                           ) }; 
    my $result = $self->check_db_result( $@, __LINE__ );
    die $@ if $result ne SUCCESS;

    if( $hiera_rs ){
        return { $args{key} => $hiera_rs->value };
    }

}

################################################################################
#
# The following subs are just used internally
#
################################################################################

# Uses puppet to find out what instances are running and provides all the info Puppet knows about them
sub show_instances {
    my $self = shift;
    my $action = shift;
    my $event = shift;
    my $payload = shift;

    my $data = {};
    my $result = SUCCESS;
    my $msg;

    #say Dumper( $payload );
    my $req = $payload->[0];
    $self->get_defaults( $req );
    #say Dumper( $req );
    $ENV{AWS_REGION} = $req->{region};
    $ENV{AWS_SECRET_ACCESS_KEY} = $req->{secret_access_key};
    $ENV{AWS_ACCESS_KEY_ID} = $req->{access_key_id};
    my $ans = $self->run_puppet( 'generic' );
    if( $action =~ /^show_*all$/ ){
        $data = $ans;
    } else {
        for my $req ( @$payload ){
            if( $ans->{$req->{name}} ){
                $data->{$req->{name}} =  $ans->{$req->{name}};
            } else {
                $data->{$req->{name}} =  { ensure => 'absent' };
            }
        }
    }
    return ( $result, $msg, $data );
}

# Build Puppet manifest and apply it
#
# We will background all create and destroy operations so we can return quicker.  The show
# command can be sent by the client to find the creation/destruction status
sub create_or_destroy_instances {
    my $self = shift;
    my $action = shift;
    my $event = shift;
    my $payload = shift;

    my $data = {};
    my $tpl_data_list = [];
    my $result = SUCCESS;
    my $msg;
    my $roles;
    
    # get all the roles - perform at each run so new ones are picked up
    ( $result, $msg, $roles ) = $self->get_roles();

    #say Dumper( $payload );
    for my $req ( @$payload ){

        # set defaults if fields are empty
        #say Dumper( $req );
        #say Dumper( $self->app->config );
        $self->get_defaults( $req );
        #say Dumper( $req );
        
        # validate the payload
        ( $result, $msg ) = $self->validate_property( $req, "name" ) if $result eq SUCCESS and $action !~ /^show_*all$/;
        ( $result, $msg ) = $self->validate_property( $req, "cloud" ) if $result eq SUCCESS;
        ( $result, $msg ) = $self->validate_property( $req, "region" ) if $result eq SUCCESS;
        ( $result, $msg ) = $self->validate_property( $req, "subnet" ) if $result eq SUCCESS;
        ( $result, $msg ) = $self->validate_property( $req, "secret_access_key" ) if $result eq SUCCESS;
        ( $result, $msg ) = $self->validate_property( $req, "access_key_id" ) if $result eq SUCCESS;
        if( $action eq 'create' ){
            ( $result, $msg ) = $self->validate_property( $req, "size" ) if $result eq SUCCESS;
            ( $result, $msg ) = $self->validate_property( $req, "role", keys %$roles ) if $result eq SUCCESS;
            ( $result, $msg ) = $self->validate_property( $req, "os" ) if $result eq SUCCESS;
            ( $result, $msg ) = $self->validate_property( $req, "app_sub_env" ) if $result eq SUCCESS;
            #( $result, $msg ) = $self->validate_property( $req, "availability_zone", @availability_zones ) if $result eq SUCCESS;
        }
        return ( $result, $msg ) if $result ne SUCCESS;

        my @availability_zones = keys %{ $self->clouds->{$req->{cloud}}{regions}{$req->{region}}{zones} };
        push @availability_zones, 'random';
        $req->{Action} = $action;
        $req->{Event} = $event;
        $ENV{AWS_REGION} = $req->{region};
        $ENV{AWS_SECRET_ACCESS_KEY} = $req->{secret_access_key};
        $ENV{AWS_ACCESS_KEY_ID} = $req->{access_key_id};

        # Transform the data for the Puppet template
        my $tpl_data = {};
        my $role = $roles->{$req->{role}};
        my $tags = {};
        $tags = $role->{tags} if $role->{tags};
        $tpl_data->{certname} = join( '.', $req->{name}, $role->{domain} );
        $tags->{role} = $req->{role};
        $tags->{os} = $req->{os};
        $tags->{stack} = $req->{stack};
        $tags->{hostname} = $req->{name};
        $tags->{provisioner} = "PuppetProvisioning";
        $tags->{fqdn} = join( '.', $req->{name}, $role->{domain} );

        $tpl_data->{name}                        = $req->{name};
        $tpl_data->{user}                        = $self->installed_by_user;
        $tpl_data->{provisioner}                 = $tags->{provisioner};
        $tpl_data->{puppet_master}               = $self->puppet_master;
        $tpl_data->{agent_script_uri}            = $self->agent_script_uri;
        $tpl_data->{image_id}                    = $self->clouds->{$req->{cloud}}{regions}{$req->{region}}{image_ids}{$req->{os}};
        $tpl_data->{location}                    = $self->clouds->{$req->{cloud}}{location};
        $tpl_data->{key_name}                    = $self->clouds->{$req->{cloud}}{access_key_name};
        $tpl_data->{tags}                        = $tags;

        #say $req->{availability_zone};
        if( $req->{availability_zone} eq 'random' or not $req->{availability_zone} ){
            #say "looking for zone";
            $req->{availability_zone} = $self->get_zone($req->{cloud}, $req->{region}, $req->{subnet});
        }
        $tpl_data->{network_zone}                = $role->{network_zone};
        $tpl_data->{network_type}                = $role->{network_type};
        $tpl_data->{domain}                      = $role->{domain};
        $tpl_data->{app_name}                    = $role->{app_name};
        $tpl_data->{puppet_role}                 = $role->{puppet_role};
        $tpl_data->{puppet_env}                  = $req->{puppet_branch} || 'development';
        $tpl_data->{associate_public_ip_address} = $role->{associate_public_ip_address};
        $tpl_data->{security_groups}             = $role->{security_groups};
        $tpl_data->{subnet}                      = $req->{subnet};
        $tpl_data->{availability_zone}           = $req->{availability_zone};
        $tpl_data->{app_sub_env}                 = $req->{app_sub_env};
        $tpl_data->{instance_type}               = $req->{size};
        $tpl_data->{region}                      = $req->{region};
        $tpl_data->{stack}                       = $req->{stack};
        $tpl_data->{extra_volumes}               = $role->{extra_volumes};
        $tpl_data->{root_volume_size}            = $role->{root_volume_size};

        push @{ $tpl_data_list }, $tpl_data;
    }

    my @instances;

    for my $tpl_data ( @$tpl_data_list ){
        my $hostname = $tpl_data->{name};
        push @instances, $hostname;
        # We need fork each instance operation as they can be time consuming. We are relying on the requestor checking
        # back later to make sure everything they requested has been created/destoryed (through the show command)
        $SIG{CHLD}='IGNORE';
        my $pid = fork;
        return (FAILED, "Unable to fork: $!.") unless defined $pid;
        unless ( $pid ) {
            # in child

            if( $action eq 'create' ){
                my $tt = Template->new;
                #$tt->process( catfile( 'templates', 'create_ec2_instance.pp.tt'), $data ) || die $tt->error;
                #return;
                
                my $dir = '/var/tmp/pcg';
                if( ! -e $dir ){
                    mkdir $dir or die $!;
                }
                my $tmp = File::Temp->new( TEMPLATE => 'create_instance.XXXXX',
                                           DIR => $dir,
                                           UNLINK => 0,
                                           SUFFIX => '.pp' );
                $tt->process( catfile( 'templates', 'create_ec2_instance.pp.tt'), $tpl_data, $tmp->filename ) || die $tt->error;
                $self->dsl->debug( "$hostname -> Contents written to ".$tmp->filename );

                # run the puppet apply operation
                ( $result, $msg ) = $self->run_puppet_apply( $hostname, $tmp->filename );
                # Check what was created
                my $ans = $self->run_puppet( $hostname );
                if( $ans->{$hostname} ){
                    $data->{$hostname} =  $ans->{$hostname};
                    $self->update_instance_in_db( $action, $hostname );
                } else {
                    $data->{$hostname} =  { ensure => 'absent' };
                }
            } elsif( $action =~ /^(stop|start|destroy)$/ ){
                my $mode = 'stopped';
                $mode = 'running' if $action =~ /^start$/;
                $mode = 'absent' if $action =~ /^destroy$/;
                my $ans = $self->run_puppet( $hostname, $hostname, "ensure=$mode", "region=".$tpl_data->{region});
                #say Dumper( $ans );
                if( $ans->{$hostname}{ensure} eq $mode 
                        or ( $mode eq 'running' and $ans->{$hostname}{ensure} =~ /pending|present/ ) ){
                    $msg = $hostname." is $mode";
                    $data->{$hostname} =  $ans->{$hostname};
                    $self->update_instance_in_db( $action, $hostname ) if $action =~ /^destroy$/;
                } else {
                    $msg = "unexpected error for ".$hostname;
                    $result = FAILED; 
                }

                if( $action eq 'destroy' ){
                    my $ssh = Net::SSH::Perl->new($self->puppet_master, debug => 0 );
                    $self->dsl->debug( "$hostname -> Logging into Puppet master (".$self->puppet_master.")" );
                    $ssh->login('pcg');
                    my $cmd = "sudo -i /usr/local/bin/puppet_db.pl -a certname_from_hostname ".$hostname;
                    $self->dsl->debug( "$hostname -> Running '$cmd' on the Puppet master (".$self->puppet_master.")" );
                    my($stdout, $stderr, $exit) = $ssh->cmd($cmd);
                    chomp( $stdout, $stderr);
                    $self->dsl->debug( "$hostname -> Got this back: $stdout (stderr: $stderr)" );
                    if( ! $exit ){
                        my $certname = $stdout;
                        my $cmd = "sudo /usr/local/bin/puppet node purge $certname";
                        $self->dsl->debug( "$hostname -> Running '$cmd' on the Puppet master (".$self->puppet_master.")" );
                        my($stdout, $stderr, $exit) = $ssh->cmd($cmd);
                        chomp( $stdout, $stderr);
                        $self->dsl->debug( "$hostname -> Got this back: $stdout (stderr: $stderr)" );
                    }
               }
            } else {
                $msg = "Unknown command: $action";
                $result = FAILED; 
            }

            exit 0;
        }
    }

    return $result, $msg, { result => "instance action ($action) successfully issued", instances => \@instances };

}

# Use the default_cloud hash from the settings to set any missing data
sub get_defaults {
    my $self = shift;
    my $req = shift;
    $req->{cloud}       = $self->default_cloud->{name}          unless $req->{cloud};
    $req->{region}      = $self->default_cloud->{region}        unless $req->{region};
    $req->{size}        = $self->default_cloud->{instance_size} unless $req->{size};
    $req->{subnet}      = $self->default_cloud->{subnet}        unless $req->{subnet};
    $req->{account}     = $self->default_cloud->{account}       unless $req->{account};
    $req->{os}          = $self->default_cloud->{os}            unless $req->{os};
    $req->{app_sub_env} = $self->default_cloud->{app_sub_env}   unless $req->{app_sub_env};
    $req->{role}        = $self->default_cloud->{role}          unless $req->{role};
}

# generic sub to vaildate properties within a hash
# 1. check whether it's in a list, or
# 2. check it matches a regex, or
# 3. check it is set
sub validate_property {
    my $self = shift;
    my $data = shift;
    my $prop = shift;
    my $compare = shift;
    my ($result, $msg ) = ( SUCCESS, "" );
    if( ref($compare) eq 'ARRAY' ){
        my $found;
        for my $cmp ( @$compare ){
            $found = 1 if( $cmp eq $data->{$prop} );
        }
        if( not $found ){
            $msg = "The '$prop' property of one of the request is not one of the valid values: [". join(',', @$compare)."]";
            $result = FAILED; 
        }
    } elsif( $compare =~ /^\(\?/ ) {
        if( $data->{$prop} !~ /$compare/ ){
            $msg = "The '$prop' property of one of the request is not matching the regular expression: $compare";
            $result = FAILED; 
        }
    } elsif( ! $data->{$prop} ){
        $msg = "The request is missing the $prop property";
        $result = FAILED; 
    }
    return $result, $msg;
}

# Run the puppet command with command line parameters only
sub run_puppet {
    my $self = shift;
    my $label = shift;
    my @args = @_;
    #open IN, "/usr/local/bin/puppet resource --to_yaml ec2_instance ${instance} 2>/dev/null |" or die $!;
    my $cmd = "/usr/local/bin/puppet";
    unshift @args, 'ec2_instance';
    unshift @args, '--to_yaml';
    unshift @args, '--modulepath=/etc/puppetlabs/code/environments/production/modules:/etc/puppetlabs/code/modules:/opt/puppetlabs/puppet/modules';
    unshift @args, 'resource';
    my ($stdout, $stderr, $exit) = capture {
        #say Dumper( \%ENV );
        system( $cmd, @args );
    };
    if( $exit ){
        $self->dsl->debug( $label." -> Exit code: $exit, STDERR:".$stderr );
        for( $stderr ){
            die "Could not load Puppet modules" if /Could not find type/;
            die $1 if /(Error:\s+.*)\nRather/s;
        }
    }
    my @output = ( "---", split /\n/, $stdout );
    for( @output ){
        s/ =>/:/g;
        s/^(\s*)(\w+[a-zA-Z0-9- ]*\w+)(\s*:.*$)/$1'$2'$3/g;
    }
    my $output = join( "\n", grep !/Notice/, @output );
    #print $output;
    my $data = Load( $output );
    #say Dumper( $data );
    return $data->{ec2_instance};
}

# Run the puppet command with a manifest
sub run_puppet_apply {
    my $self = shift;
    my $label = shift;
    my @args = @_;
    my $cmd = "/usr/local/bin/puppet";
    unshift @args, '--test';
    unshift @args, '--modulepath=/etc/puppetlabs/code/environments/production/modules:/etc/puppetlabs/code/modules:/opt/puppetlabs/puppet/modules';
    unshift @args, 'apply';

    my ($stdout, $stderr, $exit) = capture {
        #say Dumper( \%ENV );
        system( $cmd, @args );
    };
    if( $exit ){
        $self->dsl->debug( $label." -> Exit code: $exit, STDERR:".$stderr );
        for( $stderr ){
            die "Could not load Puppet modules" if /Could not find type/;
            die $1 if /(Error:\s+.*)\nRather/s;
        }
    }
    $self->dsl->debug( $label." -> ".$stdout );
    return ( SUCCESS, "Successfully ran apply command" );
}

# find the roles defined in the roles directory
sub get_roles {
    my $self = shift;
    return $self->get_data_from_yaml_files('roles');
}

# find the stacks defined in the stacks directory
sub get_stacks {
    my $self = shift;
    return $self->get_data_from_yaml_files('stacks');
}

# generic routine to load data from YAML files in a directory and return all the data as a single hash
sub get_data_from_yaml_files {
    my $self = shift;
    my $type = shift;
    my $result = SUCCESS;
    my $msg;
    # Find the data
    my $data_dir = catfile( top_level_dir, $type );
    # say $data_dir;
    my $data = {};
    opendir DIR, $data_dir or die $!;
    while(readdir DIR){
        #say $_;
        if( /([^.].+)\.ya?ml$/ ){
            my $role_file = catfile( $data_dir, $_ );
            my $role_name = $1;
            if( -r $role_file ){
                $data->{$role_name} = LoadFile( $role_file );
                # we should validate the content of each yaml file - todo
            } else {
                $msg = "Could not read role configuration file: $role_file.  Check permissions.";
                $result = FAILED; 
                last;
            }
        }
    }
    #say Dumper( $data );
    return $result, $msg, $data;
}

# Lookup a zone from the cloud config
sub get_zone {
    my $self = shift;
    my $cloud = shift;
    my $region = shift;
    my $subnet = shift;
    for my $zone ( keys %{ $self->clouds->{$cloud}{regions}{$region}{zones} } ){
        for my $_subnet ( @{ $self->clouds->{$cloud}{regions}{$region}{zones}{$zone}{subnets} } ){
            $self->dsl->debug(  "Zone: $zone, Subnet: $subnet, _Subnet: $_subnet" );
            return $zone if $subnet eq $_subnet;
        }
    }
}

sub list_stacks_in_db {
    my $self = shift;

    my $query;
    my $stack_rs;
    eval { 
        $stack_rs = schema->resultset('Stack')->search( $query ); 
    };
    my $result = $self->check_db_result( $@, __LINE__ );
    die $@ if $result ne SUCCESS;

    my @stacks;
    while (my $rs = $stack_rs->next) {
        push @stacks, $rs->name;
    }
    return \@stacks;

}

sub remove_stack_from_db {
    my $self = shift;
    my $stack = shift;
    my $stack_names = $stack;

    my $query;
    if( ref($stack) eq 'ARRAY' ){
        $query = [];
        for my $s ( @{ $stack } ){
            push @$query, { name => $s };
        }
        $stack_names = join( ', ', @{ $stack } );
    } else {
        $query = { name => $stack };
    }
    $self->dsl->debug(  "Removing stack: $stack_names from database" );

    my $stack_rs;
    eval { 
        $stack_rs = schema->resultset('Stack')->search( $query ); 
    };
    my $result = $self->check_db_result( $@, __LINE__ );
    die $@ if $result ne SUCCESS;

    eval { 
        $stack_rs->delete;
    };
    my $result = $self->check_db_result( $@, __LINE__ );
    die $@ if $result ne SUCCESS;

    return SUCCESS, 'stacks removed', { result => 'stacks removed' };

}

sub add_stack_to_db {
    my $self = shift;
    my $stack = shift;
    $self->dsl->debug(  "Adding stack: $stack to database" );

    my $stack_rs;
    eval { 
        $stack_rs = schema->resultset('Stack')->create( { name => $stack } ); 
    };
    my $result = $self->check_db_result( $@, __LINE__ );
    die $@ if $result ne SUCCESS;

    return $stack_rs->id;
}

sub list_stack_instances_in_db {
    my $self = shift;
    my $stack = shift;
    $self->dsl->debug(  "Listing stack: $stack in database" );

    my $instances_rs;
    eval { 
        $instances_rs = schema->resultset('Instance')->search( 
                                                               { 'stacks.name' => $stack },
                                                               { join => 'stacks', } 
                                                             );
    };
    my $result = $self->check_db_result( $@, __LINE__ );
    die $@ if $result ne SUCCESS;

    my @instances;
    while (my $rs = $instances_rs->next) {
        push @instances, $rs->hostname;
    }
    return \@instances;
}

sub update_instance_in_db {
    my $self = shift;
    my $action = shift;
    my $host = shift;
    my $stack_id = shift;

    my %fields = ( status => $action, 
                   last_updated => time, 
                   hostname => $host );

    $fields{stack_id} = $stack_id if( $stack_id =~ /^\d+$/ );

    my $instance_rs;
    eval { $instance_rs = schema->resultset('Instance')->update_or_create( \%fields, { key => 'hostname_unique' } ) }; 

    $self->dsl->debug( "Action: $action, Host: $host (stack id: ".$instance_rs->stack_id.")" );
    my $result = $self->check_db_result( $@, __LINE__ );
    
    return $result;
}

# Not used - used to be used to make sure the SQLITE schema existed, but it's not smart enough to account for
# schema updates
sub check_or_create_records_db {
    my $self = shift;

    my $dbfile = top_level_dir."/".$self->records_db_file;
    #say $dbfile;
    my $dbh = DBI->connect("dbi:SQLite:dbname=$dbfile","","") or die $!;
    my $sth = $dbh->prepare("SELECT hostname FROM instances");
    #$sth->execute();
    unless( $sth ){
        $self->dsl->debug(  $self->app->config->{db_init} );
        $dbh->do($self->app->config->{db_init});
        #say Dumper( $dbh );
        my $rc = $dbh->disconnect  or warn $dbh->errstr;
    }
    return SUCCESS;
}


# check whether hostname is active in Puppet or PCG
sub is_hostname_in_use{
    my $self = shift;
    my $hostname = shift;
    $self->dsl->debug(  "Checking $hostname" );
    my $ssh = Net::SSH::Perl->new($self->puppet_master, debug => 0 );
    $self->dsl->debug(  "Logging into Puppet master (".$self->puppet_master.")" );
    $ssh->login('pcg');
    my $cmd = "sudo -i /usr/local/bin/puppet_db.pl -a is_hostname_in_puppetdb ".$hostname;
    $self->dsl->debug(  "Running '$cmd' on the Puppet master (".$self->puppet_master.")" );
    my($stdout, $stderr, $exit) = $ssh->cmd($cmd);
    chomp( $stdout, $stderr);
    $self->dsl->debug(  "Got this back: $stdout (stderr: $stderr)" );

    # Return affirmative if found in the PuppetDB, continue if not
    if( ! $exit ){
        my $ans = decode_json( $stdout );
        #say Dumper( $ans );
        if( $ans->{hostname_is_in_puppetdb} ) {
            $self->dsl->debug(  "$hostname is found in the PuppetDB" );
            return 1;
        }
    }
    $self->dsl->debug(  "$hostname was not found in the PuppetDB" );

    # Return affirmative if found in the PCG DB as reserved or active
    return $self->is_host_in_pcg_db( $hostname );
}

# Generate a hostname and reserve it in the PCG
sub get_hostname {
    my $self = shift;
    my $env = shift;
    my $app_name = shift;
    my $stack_id = shift;

    my $company = $self->hostname_naming->{company};
    my $platform = $self->hostname_naming->{platform};
    my $hosting = $self->hostname_naming->{hosting};
    my $i = 1;

    # Checkhostname in PuppetDB and instance DB - if found increment the number
    my $hostname;
    my $environment = $self->app_sub_envs->{$env}{code};
    die "Could not get the environment! $env doesn't match a key in the app_sub_envs hash in the config." unless $environment;

    while( $self->is_hostname_in_use( $hostname = substr( $company, 0, 1) .
                                                  substr( $platform, 0, 1) .
                                                  $environment .
                                                  $app_name .
                                                  sprintf( "%02d", $i) .
                                                  $hosting 
                                    ) ){
        $i++;
    }

    # If unique insert into instance DB to reserver it
    $self->update_instance_in_db( 'reserve', $hostname, $stack_id );

    return $hostname;
}

# Generate a unique stack name
sub get_unique_stack_name {
    my $self = shift;
    my $stack = shift;
    my $env = shift;
    my $newstack;

    my $i = 1;

    # Check the database for existing names
    while( $self->is_stack_in_pcg_db( $newstack = $stack . '-' .
                                      $env . '-' .
                                      sprintf( "%02d", $i)
                                    ) 
         ){
        $i++;
    }

    return $newstack;
}

sub check_host_exists {
    my $self = shift;
    my $hostname = shift;

    my $result;
    my $msg;

    if( $self->is_host_in_pcg_db( $hostname ) ){
            $msg = "$hostname is reserved or active";
            $result = SUCCESS; 
    } else {
            $msg = "$hostname is available for (re)use";
            $result = FAILED; 
    }
    return $result, $msg;
}

sub is_host_in_pcg_db {
    my $self = shift;
    my $hostname = shift;

    my $instance_rs;
    eval { $instance_rs = schema->resultset('Instance')->find( $hostname, { key => 'hostname_unique' } ) }; 

    my $result = $self->check_db_result( $@, __LINE__ );

    die $@ if $result ne SUCCESS;

    if( $instance_rs and $instance_rs->status =~ /^(create|reserve)$/ ){
        $self->dsl->debug(  "$hostname is reserved or active according to the PCG" );
        return 1; 
    } else {
        $self->dsl->debug(  "$hostname is available according to the PCG" );
        return 0; 
    }
}

sub is_stack_in_pcg_db{
    my $self = shift;
    my $stack = shift;

    my $stack_rs;
    eval { 
        $stack_rs = schema->resultset('Stack')->find( $stack, { key => 'name_unique' } ); 
    };
    my $result = $self->check_db_result( $@, __LINE__ );
    die $@ if $result ne SUCCESS;

    if( $stack_rs and $stack_rs->id ){
        $self->dsl->debug(  "$stack is already in use, according to the PCG" );
        return 1; 
    } else {
        $self->dsl->debug(  "$stack is available, according to the PCG" );
        return 0; 
    }
}

sub update_hiera_data {
    my $self = shift;

    my $type = shift;
    my $name = shift;
    my $key = shift;
    my $value = shift;

    $self->dsl->debug(  "Updating Hiera data, setting: $type, $name, $key to $value" );
    my %fields = ( 
                   lookup_type => $type, 
                   lookup_name => $name, 
                   key => $key, 
                   value => $value, 
                   last_updated => time, 
                 );
    my $hiera_rs;
    eval { $hiera_rs = schema->resultset('HieraData')->update_or_create( \%fields, { key => 'lookup_type_lookup_name_key_unique' } ) }; 
    my $result = $self->check_db_result( $@, __LINE__ );

    return $result;
}

sub check_db_result{
    my $self = shift;
    my $result = shift;
    my $line = shift;

    if( $result ){
        my @err = split /\n/, $result;
        $self->dsl->debug( "######".$err[0]."###### at line:".$line );
        return FAILED;
    }

    return SUCCESS;
}


1;
