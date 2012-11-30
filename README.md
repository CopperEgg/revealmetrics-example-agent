revealmetrics-example-agent
===========================

Example agent for use with CopperEgg RevealMetrics.

If you do not have a CopperEgg account, you may create one at <https://copperegg.com/copperegg-signup/>

If you have a CopperEgg account, you may log in and use RevealMetrics at <https://app.copperegg.com/login>


#Getting Started with RevealMetrics Ruby Agent

##1. Install dependencies ruby and mysql-dev

On newer Debian/Ububntu, run:

    sudo apt-get -y install ruby1.9.3 rubygems libopenssl-ruby1.9.3 unzip

Older versions such as Ubuntu 10.04 may need to use "ruby1.9.1" instead of "ruby1.9.3",
or "rubygems1.9.1" instead of "rubygems".  In the instructions below,
you will need to replace "1.9.3" with "1.9.1".

If you need to monitor mysql, run this as well:

    sudo apt-get -y install ruby1.9.3-dev libmysqld-dev build-essential

On RedHat/Fedora/CentOS/Amazon Linux, run:

    sudo yum install -y ruby19 rubygems mysql-devel

and in the instructions below, replace "ruby1.9.3" with "ruby19" and "gem1.9.3" with "gem19".

Note that the agent should work properly with ruby 1.8.x, but 1.9.x is recommended and tested.


##2. Download and configure the agent

Download the [revealmetrics-example-agent.zip](https://github.com/CopperEgg/revealmetrics-example-agent/archive/master.zip)
file \([hosted at github](https://github.com/CopperEgg/revealmetrics-example-agent)\) on a Linux or Mac OSX system:

    cd ~; wget https://github.com/CopperEgg/revealmetrics-example-agent/archive/master.zip

Unzip the archive and enter the directory:

    unzip master.zip; cd revealmetrics-example-agent-master

Copy the example config into config.yml, and edit with your favorite editor:

    cp config-example.yml config.yml; nano config.yml

Make sure to replace "YOUR\_APIKEY" with your api key, found in the settings tab of app.copperegg.com.
Remove any sections that you do not wish to monitor, and edit server settings accordingly.
Be sure to keep the same spacing supplied in the original file.


##3. Install gems

Ensure that the ruby gems are installed.  Do not use the "--without=mysql" flag if you want to monitor mysql:

    gem1.9.3 install bundler; bundle install --without=mysql

If installing bundler fails with the error "bundler requires RubyGems version >= 1.3.6",
try running this command and then rerunning the bundle command above:

    gem1.9.1 install rubygems-update; sudo /var/lib/gems/1.9.1/bin/update_rubygems

If the bundle command still fails, run this \(and omit "redis" or "mysql2" if desired\):

    gem1.9.3 install json_pure copperegg redis mysql2


##4. Run the agent

Run the agent in a terminal:

    ruby1.9.3 ./copperegg-agent.rb

You should see some output saying that dashboards are created, and services are being monitored.

To run the process in the background, you may use:

    nohup ruby1.9.3 ./copperegg-agent.rb >/tmp/copperegg-agent.log 2>&1 &

And it will run in the background, and log to /tmp/copperegg-agent.log


##5. Enjoy your new Dashboards

It may take up to a minute for the dashboards to automatically appear, once they are created.
After a minute or a page refresh, they will appear in the left nav of the RevealMetrics tab.  Enjoy!

