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
use qutil;
use DBI qw(:sql_types);
use Type::Tiny;

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
    traits                 => ['Array'],
    is                     => 'rw',
    required               => 1,
    default                => sub { [] },
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
    default => 'localhost',
    predicate => 'has_puppet_master',
);

plugin_keywords qw/
    do_action
    check_host
    list_options
/;

sub BUILD {
    my $self = shift;
    if( keys %{ $self->app->config->{clouds} } ){
        $self->clouds( $self->app->config->{clouds} );
    } else {
        die "You need to set the clouds in the config file";
    }
    if( @{ $self->app->config->{app_sub_envs} } ){
        $self->app_sub_envs( $self->app->config->{app_sub_envs} );
    } else {
        die "You need to set the app_sub_envs in the config file";
    }
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

}
sub do_action {
    my $self = shift;
    #say Dumper( $self );
    my $payload = shift;
    my $action = shift;
    #say $action;
    my $event = shift;
    my $data = {};
    my $result = SUCCESS;
    my $msg;

    # get all the roles - perform at each run so new ones are picked up
    my $roles;
    ( $result, $msg, $roles ) = $self->get_roles();

    if( $result eq SUCCESS and ref($payload) ne 'ARRAY' ){
        $msg = "The payload needs to be an array of requests";
        $result = FAILED; 
    }
    if( $result eq SUCCESS ){
        #say Dumper( $payload );
        for my $req ( @$payload ){

            # set defaults if fields are empty
            say Dumper( $req );
            #say Dumper( $self->app->config );
            $req->{cloud}       = $self->default_cloud->{name}          unless $req->{cloud};
            $req->{region}      = $self->default_cloud->{region}        unless $req->{region};
            $req->{size}        = $self->default_cloud->{instance_size} unless $req->{size};
            $req->{subnet}      = $self->default_cloud->{subnet}        unless $req->{subnet};
            $req->{account}     = $self->default_cloud->{account}       unless $req->{account};
            $req->{os}          = $self->default_cloud->{os}            unless $req->{os};
            $req->{app_sub_env} = $self->default_cloud->{app_sub_env}   unless $req->{app_sub_env};
            $req->{role}        = $self->default_cloud->{role}          unless $req->{role};
            say Dumper( $req );
            
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
            my @availability_zones = keys %{ $self->clouds->{$req->{cloud}}{regions}{$req->{region}}{zones} };
            push @availability_zones, 'random';

            if( $result eq SUCCESS ){
                $req->{Action} = $action;
                $req->{Event} = $event;

                $ENV{AWS_REGION} = $req->{region};
                $ENV{AWS_SECRET_ACCESS_KEY} = $req->{secret_access_key};
                $ENV{AWS_ACCESS_KEY_ID} = $req->{access_key_id};
                # Transform the data for the Puppet template
                my $tpl_data = {};
                my $tags = {};
                my $role = $roles->{$req->{role}};
                $tpl_data->{certname} = join( '.', $req->{name}, $role->{domain} );
                if( $action eq 'create' ){
                    $tags->{role} = $req->{role};
                    $tags->{os} = $req->{os};

                    $tpl_data->{name}                        = $req->{name};
                    $tpl_data->{user}                        = $self->installed_by_user;
                    $tpl_data->{provisioner}                 = "PuppetProvisioning";
                    $tpl_data->{puppet_master}               = $self->puppet_master;
                    $tpl_data->{image_id}                    = $self->clouds->{$req->{cloud}}{regions}{$req->{region}}{image_ids}{$req->{os}};
                    $tpl_data->{location}                    = $self->clouds->{$req->{cloud}}{location};
                    $tpl_data->{key_name}                    = $self->clouds->{$req->{cloud}}{access_key_name};
                    $tpl_data->{tags}                        = $tags;

                    say $req->{availability_zone};
                    if( $req->{availability_zone} eq 'random' or not $req->{availability_zone} ){
                        say "looking for zone";
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
                    say "Contents written to ".$tmp->filename;
                    $self->run_puppet_apply( $tmp->filename );
                    my $ans = $self->run_puppet( );
                    if( $ans->{$req->{name}} ){
                        $data->{$req->{name}} =  $ans->{$req->{name}};
                        $self->update_records( $action, $req->{name} );
                    } else {
                        $data->{$req->{name}} =  { ensure => 'absent' };
                    }
                } elsif( $action eq 'destroy' ){
                    my $ans = $self->run_puppet( $req->{name}, 'ensure=absent', "region=".$req->{region});
                    #say Dumper( $ans );
                    if( $ans->{$req->{name}}{ensure} eq 'absent' ){
                        $msg = $req->{name}." no longer exists";
                        $data->{$req->{name}} =  $ans->{$req->{name}};
                        $self->update_records( $action, $req->{name} );
                    } else {
                        $msg = "unexpected error for ".$req->{name};
                        $result = FAILED; 
                    }
                } elsif( $action =~ /^show_*all$/ ){
                    $data = $self->run_puppet( );
                } elsif( $action eq 'show' ){
                    my $ans = $self->run_puppet( );
                    #say Dumper( $ans );
                    if( $ans->{$req->{name}} ){
                        $data->{$req->{name}} =  $ans->{$req->{name}};
                    } else {
                        $data->{$req->{name}} =  { ensure => 'absent' };
                        #$msg = $req->{name}." does not exist";
                        #$result = FAILED; 
                    }
                } else {
                    $msg = "Unknown command: $action";
                    $result = FAILED; 
                }

            }
        }
    }


    #say Dumper( $result, $msg, $data );
    return $result, $msg, $data;

}

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


sub list_options {
    my $self = shift;
    my $req = shift;
    my $data = shift;
    my $result = SUCCESS;
    my $msg;
    say Dumper( $req );

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
            $data = $self->app_sub_envs;
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

sub run_puppet {
    my $self = shift;
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
        say $stderr;
        say $exit;
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
    print $output;
    my $data = Load( $output );
    #say Dumper( $data );
    return $data->{ec2_instance};
}
sub run_puppet_apply {
    my $self = shift;
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
        say $stderr;
        say $exit;
        for( $stderr ){
            die "Could not load Puppet modules" if /Could not find type/;
            die $1 if /(Error:\s+.*)\nRather/s;
        }
    }
    say $stdout;
    return $stdout;
}

sub get_roles {
    my $self = shift;
    my $result = SUCCESS;
    my $msg;
    # Find the roles
    my $roles_dir = catfile( top_level_dir, 'roles' );
    # say $roles_dir;
    my $roles = {};
    opendir DIR, $roles_dir or die $!;
    while(readdir DIR){
        #say $_;
        if( /([^.].+)\.ya?ml$/ ){
            my $role_file = catfile( $roles_dir, $_ );
            my $role_name = $1;
            if( -r $role_file ){
                $roles->{$role_name} = LoadFile( $role_file );
                # we should validate the content of each yaml file - todo
            } else {
                $msg = "Could not read role configuration file: $role_file.  Check permissions.";
                $result = FAILED; 
                last;
            }
        }
    }
    #say Dumper( $roles );
    return $result, $msg, $roles;
}

sub get_zone {
    my $self = shift;
    my $cloud = shift;
    my $region = shift;
    my $subnet = shift;
    for my $zone ( keys %{ $self->clouds->{$cloud}{regions}{$region}{zones} } ){
        for my $_subnet ( @{ $self->clouds->{$cloud}{regions}{$region}{zones}{$zone}{subnets} } ){
            say "Zone: $zone, Subnet: $subnet, _Subnet: $_subnet";
            return $zone if $subnet eq $_subnet;
        }
    }
}

sub update_records {
    my $self = shift;
    my $action = shift;
    my $host = shift;
     say "Action: $action, Host: $host";

    $self->check_or_create_records_db;

    my $dbfile = top_level_dir."/".$self->records_db_file;
    my $dbh = DBI->connect("dbi:SQLite:dbname=$dbfile","","") or die $!;
    my $sth;
    $sth = $dbh->prepare("UPDATE instances set status = ?, last_updated = ? WHERE hostname = ?");
    $sth->bind_param(1, $action, SQL_VARCHAR);
    $sth->bind_param(2, time, SQL_INTEGER);
    $sth->bind_param(3, $host, SQL_VARCHAR);
    $sth->execute();
    if( $sth->rows == 0 ){
        $sth = $dbh->prepare("INSERT INTO instances (hostname,status,last_updated) VALUES (?, ?, ?)");
        $sth->bind_param(1, $host, SQL_VARCHAR);
        $sth->bind_param(2, $action, SQL_VARCHAR);
        $sth->bind_param(3, time, SQL_INTEGER);
        $sth->execute();
    }
    my $rc = $dbh->disconnect  or warn $dbh->errstr;
    return SUCCESS;
}
sub check_or_create_records_db {
    my $self = shift;

    my $dbfile = top_level_dir."/".$self->records_db_file;
    #say $dbfile;
    my $dbh = DBI->connect("dbi:SQLite:dbname=$dbfile","","") or die $!;
    my $sth = $dbh->prepare("SELECT hostname FROM instances");
    #$sth->execute();
    unless( $sth ){
        say $self->app->config->{db_init};
        $dbh->do($self->app->config->{db_init});
        #say Dumper( $dbh );
        my $rc = $dbh->disconnect  or warn $dbh->errstr;
    }
    return SUCCESS;
}

sub check_host {
    my $self = shift;
    my $hostname = shift;
    my $result;
    my $msg;
    my $dbfile = top_level_dir."/".$self->records_db_file;
    my $dbh = DBI->connect("dbi:SQLite:dbname=$dbfile","","") or die $!;
    my $sth = $dbh->prepare("SELECT hostname FROM instances WHERE status = ? and hostname = ?");
    $sth->bind_param(1, 'create', SQL_VARCHAR);
    $sth->bind_param(2, $hostname, SQL_VARCHAR);
    $sth->execute();
    my $table = $sth->fetchall_arrayref;
    my $rc = $dbh->disconnect  or warn $dbh->errstr;
    if( @$table > 0 ){
            $msg = "$hostname is a valid host";
            $result = SUCCESS; 
    } else {
            $msg = "$hostname is not a valid host";
            $result = FAILED; 
    }
    return $result, $msg;
}


1;
