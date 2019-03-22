# PCG - Puppet Cloud Gateway

This web service provides an API to drive cloud automation through the Puppet absraction layer.  Although all clouds require different parameters, using a 
mostly common interface reduces the amount of code to be maintained.  Puppet provides this abstraction layer, but does not provide a ready way to interact with it through an API.  This tool provides that gateway.

**PCG** is written in Perl using the [Dancer2](http://perldancer.org) Web Framework (a lightweight framework based on Sinatra for Ruby).  Currently, the **PCG** does not provide a web browser interface, but JSON can be sent and received as XMLHttpRequest object.  See https://github.com/Q-Technologies/Dancer2-pcg for full details.

## Table of Contents

<!-- vim-markdown-toc GFM -->

* [Usage](#usage)
  * [Actions](#actions)
    * [create](#create)
    * [destroy](#destroy)
    * [show](#show)
    * [showall](#showall)
    * [stop/start](#stopstart)
    * [create_stack](#create_stack)
    * [list_stacks](#list_stacks)
    * [show_stack](#show_stack)
    * [destroy_stack](#destroy_stack)
  * [Options](#options)
  * [Authentication](#authentication)
  * [Response](#response)
* [Installation](#installation)
  * [Prepare Environment](#prepare-environment)
  * [Deploy PCG](#deploy-pcg)
  * [Update the config files](#update-the-config-files)
  * [Create Role Definitions](#create-role-definitions)
  * [Create Stack Definitions](#create-stack-definitions)
* [Accompanying Files](#accompanying-files)
  * [manage_instance.pl](#manage_instancepl)
  * [agent_install.sh](#agent_installsh)
* [Maintenance](#maintenance)
  * [Changing the password](#changing-the-password)
* [Missing Features](#missing-features)

<!-- vim-markdown-toc -->

## Usage

The AJAX request needs to contain JSON data with an Action, Event and PayLoad.  The PayLoad is an array of instance request objects. Some of the instance request data can be ommitted if appropriate defaults are set in the configuration.  Here is a sample request:  

    {
      "PayLoad" : [
         {
            "cloud": "aws",
            "account": "qtech",
            "region": "ap-southeast-2",
            "size": "t2.micro",
            "role": "vanilla",
            "app_sub_env": "dev",
            "os": "centos_7",
            "availability_zone": "random",
            "name": "sdlklsdks",
            "puppet_branch": null
        }
    ],
        "Action" : "create",
        "Event" : "from Jenkins - build 98398",
    }

Once the request is received, it is turned into a Puppet manifest and immediately applied.  

As Puppet is idempotent, if a cloud is requested multiple times it will only be created once. Each subsequent invocation will have no effect.  

On the other hand, stacks are not created directly by Puppet, but are objects stored within the PCG itself.  They are requested generically and a specific stack instance name is 
returned.  If a request is issued multiple times for the same stack name, multiple unique stacks will be created (they are numbered squentially).

### Actions
Actions are sent to the __/do__ path.

Different fields are compulsory depending on the action type.  The following actions are supported:
#### create
Create a cloud instance in the specified cloud account region. It will not recreate an existing instance with the same name (it will just perform a show). The following fields are required:
  * cloud
  * account
  * region
  * name
  * size
  * role
  * app_sub_env
  * os
  * availability_zone

The following field is optional - it sets a custom Puppet environment (Git branch) to overide the default from app_sub_env:
  * puppet_branch

#### destroy
Destroy the named instance running in the specified cloud account region. The following fields are required:
  * cloud
  * account
  * region
  * name

#### show
Show the named instance running in the specified cloud account region. The following fields are required:
  * cloud
  * account
  * region
  * name

#### showall
Show all the instances running in the specified cloud account region. The following fields are required:
  * cloud
  * account
  * region

#### stop/start
Stop or Start the named instance in the specified cloud account region. The following fields are required:
  * cloud
  * account
  * region

#### create_stack
Create a new cloud stack in the specified cloud account region. It will create additional stacks if any of the same name exist. The following fields are required:
  * cloud
  * account
  * region
  * name
  * size
  * role
  * app_sub_env
  * os
  * availability_zone

The following field is optional - it sets a custom Puppet environment (Git branch) to overide the default from app_sub_env:
  * puppet_branch

#### list_stacks
List all the stacks that PCG has defined within it. No fields are required.

#### show_stack
Show details about a running cloud stack.  The following fields are required:
  * cloud
  * account
  * region
  * name

#### destroy_stack
Destroy an existing stack and all its instances.  The following fields are required:
  * cloud
  * account
  * region
  * name

### Options
Most of the fields specfied in the actions, must be selected from options rather than being free text.  The only free text field is **name**.  The available options for each field can be displayed by sending a request to the __/list__ path.  Sending an AJAX request with JSON along the following lines (this will list the instance size for the cloud in the configuration file):

    {
      "Query" : {
            "option": "size",
            "cloud": "aws"
        }
    }

The following fields can be queried:
  * cloud
  * account - requires cloud
  * region - requires cloud
  * size - requires cloud
  * os - requires cloud and region
  * availability_zone - requires cloud and region
  * role
  * app_sub_env

### Authentication

Authentication is a simple pre-shared identifier (userid) and token (passwd), e.g.:

    userid: GkTCWUp2yZwxbF8u
    passwd: MVJsF5ZbpjPADXUPAxU38cZG

This can either be sent as parameters in the URL or embedded in the JSON object. Sessions are also supported, so authentication only has to occur once an hour.

### Response

A successful post will get a 202 status code and a JSON object along these lines:

    {
       "result" : "success", 
       "message" : "Puppet command ran successfully", 
       "data" : Puppet_Return_Data
    }

An unsuccessful post will get a 200 status and a JSON object like this - the message will try to convey what went wrong:

    {
       "result" : "failed", 
       "message" : "An error occurred trying to run Puppet"
    }

Other errors might occur where an unexpected condition was met - this would usually return a status of 500.


## Installation
### Prepare Environment

Install the following PERL modules:
  * Dancer2
  * Dancer2::Plugin::Ajax
  * Dancer2::Plugin::DBIC
  * Net::SSH::Perl

### Deploy PCG

Install the RPM:

    rpm -ivh pcg-1.0-1.0.noarch.rpm

Or, deply from GitHub:

    git clone https://github.com/Q-Technologies/Dancer2-pcg.git

Using Puppet:

Install the pcg module (by default, this assumes there is a package in a subscribed repository).  This sets up a systemd service by default, also.

Then in the manifest in the scope of the server you want to install PCG on:

    class { 'pcg': }

### Update the config files
Create a `config_local.yml` using the example one as a starting point.  Most is self explanatory, the hostname_naming is not:

    hostname_naming:
      standard: 'e(w|l)(c|d|e|f|i|n|p|q|r|s|t|u|v)[a-z]{3,5}\d{1,2}(v|p)(cl|dc)'
      company: example
      platform: linux
      hosting: vcl

The algorithm for creating the hostname is:
 * first letter of comany
 * first letter of platform
 * the letter value from the app_sub_envs (application sub environments)
 * a 3-5 letter name for the application (comes from the name4hostname in the role definitions)
 * a 1-2 digit serial number
 * a hosting type (3 letters)

### Create Role Definitions
In the roles subdirectory (top level within PCG), create one file per role, along the following lines:

    ---
    app_name: infrastructure
    name4hostname: myapp
    short_app_name: infra
    puppet_role: base
    domain: example.com
    network_zone: dev
    network_type: dev
    root_volume_size: 8
    extra_volumes:
    - volume_size: 1
      device_name: xvdb
    associate_public_ip_address: true
    security_groups:
    - dev servers
    tags:
      purpose: testing

### Create Stack Definitions
In the stacks subdirectory (top level within PCG), create one file per stack, along the following lines:

    ---
    role1:
    - os: centos_7
      size: t2.micro
    - os: ubuntu_1204
      name4hostname: myapp
      size: t2.micro
    role2:
    - os: centos_7
      size: t2.micro

This will create a stack with 2 role1 servers (one using centos, the other ubuntu - with its hostname overridden) and one role2 server running on centos.

## Accompanying Files
The following files are available from within the PCG Puppet module (or they can be grabbed directly from the git repo).

### manage_instance.pl
This is a script that can be used on the command line to send the AJAX requests to the PCG instead of using Curl or similar to make it easy to call.

### agent_install.sh
This is a small script to boostrap the Puppet install - mostly by putting trusted facts in the CSR.  This needs to be installed somewhere
where it can be downloaded by the instance as it boots.

## Maintenance
### Changing the password
Change the password in the `config_local.yml` file and restart the web service.  Also change the password in any client scripts submitting data.

## Missing Features

  * Needs to check when the node is booted and return a status for each of: AWS, SSH, Puppet
  * Needs to return an error if the role doesn't exist
  * Needs to track which stack has been deployed into what cloud/account/region, so they can be listed separately
  * Need to provide a way for people to insert their own naming standard


