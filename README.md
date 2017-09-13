# PCG - Puppet Cloud Gateway

This web service provides an API to drive cloud automation through the Puppet absraction layer.  Although all clouds require different parameters, using a 
basically common interface reduces the amount of code to be maintained.  Puppet provides this abstraction layer, but does not provide a ready way to interact with it through an API.  This tool provides that gateway.

**PCG** is written in Perl using the [Dancer2](http://perldancer.org) Web Framework (a lightweight framework based on Sinatra for Ruby).  **PCG** does not provide a web browser interface, but JSON can be sent and received as XMLHttpRequest object.  See https://github.com/Q-Technologies/PCG for full details.

## Usage

The AJAX request needs to contain JSON along these lines.  

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

Once the request is received, it is turned into a Puppet manifest and immediately applied.  As Puppet is idempotent, if the same server is requested multiple times 
it will only be created once. Each subsequent invocation will have no effect.

### Actions
Actions are sent to the __/do__ path.

Different fields are compulsory depending on the action type.  The following actions are supported:
#### create
Show all the instances running the specified cloud account region. The following fields are required:
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

Authentication will be a simple pre-shared identifier and token, e.g.:

    identifier: GkTCWUp2yZwxbF8u
    token:      MVJsF5ZbpjPADXUPAxU38cZG

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

Install the RPM (nodeps is required as RPM will automatically make any perl modules reference into dependencies, which is a problem if you have installed those modules through CPAN):

    rpm -ivh --nodeps autopkg-1.0-1.0.noarch.rpm

### Prepare Environment

Install the following PERL modules:
  * Dancer2
  * Dancer2::Plugin::Ajax

Update PERL5LIB in the `/etc/sysconfig/autopkg` file with the path for additional PERL modules.

### Set the location of the dropped file root
In `./environments/production.yml`, set the `top_level_dir` and `repo_dir`, e.g.:

    top_level_dir: "/autopkg"
    repo_dir: "/repo/apps/from_nexus"

Make sure the user autopkg is running as (fcollect, byt default) has permissions to write to this directory:

    mkdir /autopkg
    chown autopkg /autopkg


## Maintenance
### Changing the password
Change the password in the `config_local.yml` file and restart the web service.  Also change the password in any client scripts submitting data.

## Missing Features

  * Needs to be able to purge a node from Puppet
  * Needs to check when the node is booted and return a status: AWS, SSH, Puppet
  * Needs to return an error if the role doesn't exist


