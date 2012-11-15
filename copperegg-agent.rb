#!/usr/bin/env ruby
#
# Copyright 2012 CopperEgg Corporation.  All rights reserved.
#

require 'getoptlong'
require 'copperegg'
require 'json'
require 'yaml'

####################################################################

def help
  puts "usage: $0 args"
  puts "Examples:"
  puts "  -c config.yml"
  puts "  -f 60                 (for 60s updates. Valid values: 5, 15, 60, 300, 900, 3600)"
  puts "  -k hcd7273hrejh712    (your APIKEY from the UI dashboard settings)"
  puts "  -a https://api.copperegg.com    (API endpoint to use [DEBUG ONLY])"
end

def interruptible_sleep(seconds)
  seconds.times {|i| sleep 1 if !@interrupted}
end

def child_interrupt
  # do child clean-up here
  @interrupted = true
  puts "Exiting pid #{Process.pid}"
end

def parent_interrupt
  puts "INTERRUPTED"
  # parent clean-up
  @interrupted = true

  @worker_pids.each do |pid|
    Process.kill 'TERM', pid
  end

  puts "Waiting for all workers to exit"
  Process.waitall

  if @monitor_thread
    puts "Waiting for monitor thread to exit"
    @monitor_thread.join
  end

  puts "Exiting cleanly"
  exit
end
####################################################################

# get options
opts = GetoptLong.new(
  ['--help',      '-h', GetoptLong::NO_ARGUMENT],
  ['--debug',     '-d', GetoptLong::NO_ARGUMENT],
  ['--config',    '-c', GetoptLong::REQUIRED_ARGUMENT],
  ['--apikey',    '-k', GetoptLong::REQUIRED_ARGUMENT],
  ['--frequency', '-f', GetoptLong::REQUIRED_ARGUMENT],
  ['--apihost',   '-a', GetoptLong::REQUIRED_ARGUMENT]
)

config_file = "config.yml"
apikey = nil
@apihost = nil
@debug = 0
@freq = 60  # update frequency in seconds
@interupted = false
@worker_pids = []
@services = []

# Options and examples:
opts.each do |opt, arg|
  case opt
  when '--help'
    help
    exit
  when '--debug'
    @debug = true
  when '--config'
    config_file = arg
  when '--apikey'
    apikey = arg
  when '--frequency'
    @freq = arg.to_i
  when '--apihost'
    @apihost = arg
  end
end

# Look for config file
@config = YAML.load(File.open(config_file))

if !@config.nil?
  # load config
  if !@config["copperegg"].nil?
    apikey = @config["copperegg"]["apikey"] if !@config["copperegg"]["apikey"].nil? && apikey.nil?
    @freq = @config["copperegg"]["frequency"] if !@config["copperegg"]["frequency"].nil?
    @services = @config['copperegg']['services']
  else
    puts "You have no copperegg entry in your config.yml!"
    puts "Edit your config.yml and restart."
    exit
  end
end

if apikey.nil?
  puts "You need to supply an apikey with the -k option or in the config.yml."
  exit
end

if @services.length == 0
  puts "No services listed in the config file."
  puts "Nothing will be monitored!"
  exit
end

####################################################################

def connect_to_redis(uri, attempts=10)
  host, port = uri.split(':')
  connect_try_count = 0
  redis = nil
  begin
    redis = Redis.new(:host=>host, :port=>port)
  rescue Exception => e
    connect_try_count += 1
    if connect_try_count > attempts
      log "#{e.inspect}"
      raise e
    end
    sleep 0.5
  retry
  end
  return redis
end

def monitor_redis(redis_servers, group_name, apikey)
  require 'redis'

  rm = CopperEgg::Metrics.new(apikey, @apihost)

  puts "Monitoring Redis: "
  
  while !@interupted do
    return if @interrupted

    redis_servers.each do |rhost|
      return if @interrupted

      #label, rhostname, rport = rhost.split(':')
      label = rhost["name"]
      rhostname = rhost["hostname"]
      rport = rhost["port"]

      redis_uri = "#{rhostname}:#{rport}"
      begin
        redis = connect_to_redis(redis_uri)
        rinfo = redis.info()
      rescue Exception => e
        puts "Error getting stats from: #{rhost} [skipping]"
        next
      end

      metrics = {}
      metrics["uptime"]                       = rinfo["uptime_in_seconds"].to_i
      metrics["used_cpu_sys"]                 = rinfo["used_cpu_sys"].to_f*100
      metrics["used_cpu_user"]                = rinfo["used_cpu_user"].to_f*100
      metrics["connected_clients"]            = rinfo["connected_clients"].to_i
      metrics["connected_slaves"]             = rinfo["connected_slaves"].to_i
      metrics["blocked_clients"]              = rinfo["blocked_clients"].to_i
      metrics["used_memory"]                  = rinfo["used_memory"].to_i
      metrics["used_memory_rss"]              = rinfo["used_memory_rss"].to_i
      metrics["used_memory_peak"]             = rinfo["used_memory_peak"].to_i
      metrics["mem_fragmentation_ratio"]      = rinfo["mem_fragmentation_ratio"].to_f
      metrics["changes_since_last_save"]      = rinfo["changes_since_last_save"].to_i
      metrics["total_connections_received"]   = rinfo["total_connections_received"].to_i
      metrics["total_commands_processed"]     = rinfo["total_commands_processed"].to_i
      metrics["expired_keys"]                 = rinfo["expired_keys"].to_i
      metrics["evicted_keys"]                 = rinfo["evicted_keys"].to_i
      metrics["keyspace_hits"]                = rinfo["keyspace_hits"].to_i
      metrics["keyspace_misses"]              = rinfo["keyspace_misses"].to_i
      metrics["pubsub_channels"]              = rinfo["pubsub_channels"].to_i
      metrics["pubsub_patterns"]              = rinfo["pubsub_patterns"].to_i
      metrics["latest_fork_usec"]             = rinfo["latest_fork_usec"].to_i
      metrics["keys"]                         = rinfo["db0"].split(',')[0].split('=')[1].to_i
      metrics["expires"]                      = rinfo["db0"].split(',')[1].split('=')[1].to_i

      # check version of rinfo (2.4 or 2.6)
      if !rinfo["redis_version"].match("2.4")

        metrics["used_memory_lua"]            = rinfo["used_memory_lua"].to_i
        metrics["rdb_changes_since_last_save"]= rinfo["rdb_changes_since_last_save"].to_i
        metrics["instantaneous_ops_per_sec"]  = rinfo["instantaneous_ops_per_sec"].to_i
        metrics["rejected_connections"]       = rinfo["rejected_connections"].to_i

        # command stats:
        #commandstats = redis.info("commandstats")

      end
      
      redis.client.disconnect

      rm.store_sample(group_name, label, Time.now.to_i, metrics)
    
    end
    interruptible_sleep @freq
  end
end

def create_redis_metric_group(group_name, group_label, apikey)
  ce_metrics = CopperEgg::Metrics.new(apikey, @apihost)

  # no metric group found - create one
  puts "Creating Redis metric group"

  groupcfg = {}
  groupcfg["name"] = group_name
  groupcfg["label"] = group_label
  groupcfg["frequency"] = @freq
  groupcfg["metrics"] = [{"type"=>"ce_counter", "name"=>"uptime",                     "unit"=>"Seconds"},
                         {"type"=>"ce_gauge_f", "name"=>"used_cpu_sys",               "unit"=>"Percent"},
                         {"type"=>"ce_gauge_f", "name"=>"used_cpu_user",              "unit"=>"Percent"},
                         {"type"=>"ce_gauge",   "name"=>"connected_clients",          "unit"=>"Clients"},
                         {"type"=>"ce_gauge",   "name"=>"connected_slaves",           "unit"=>"Slaves"},
                         {"type"=>"ce_gauge",   "name"=>"blocked_clients",            "unit"=>"Clients"},
                         {"type"=>"ce_gauge",   "name"=>"used_memory",                "unit"=>"Bytes"},
                         {"type"=>"ce_gauge",   "name"=>"used_memory_rss",            "unit"=>"Bytes"},
                         {"type"=>"ce_gauge",   "name"=>"used_memory_peak",           "unit"=>"Bytes"},
                         {"type"=>"ce_gauge_f", "name"=>"mem_fragmentation_ratio"},
                         {"type"=>"ce_gauge",   "name"=>"changes_since_last_save",    "unit"=>"Changes"},
                         {"type"=>"ce_counter", "name"=>"total_connections_received", "unit"=>"Connections"},
                         {"type"=>"ce_counter", "name"=>"total_commands_processed",   "unit"=>"Commands"},
                         {"type"=>"ce_gauge",   "name"=>"expired_keys",               "unit"=>"Keys"},
                         {"type"=>"ce_counter", "name"=>"keyspace_hits",              "unit"=>"Hits"},
                         {"type"=>"ce_counter", "name"=>"keyspace_misses",            "unit"=>"Misses"},
                         {"type"=>"ce_gauge",   "name"=>"pubsub_channels",            "unit"=>"Channels"},
                         {"type"=>"ce_gauge",   "name"=>"pubsub_patterns",            "unit"=>"Patterns"},
                         {"type"=>"ce_gauge",   "name"=>"latest_fork_usec",           "unit"=>"usec"},
                         {"type"=>"ce_gauge",   "name"=>"keys",                       "unit"=>"Keys"},
                         {"type"=>"ce_counter", "name"=>"evicted_keys",               "unit"=>"Keys"},
                         {"type"=>"ce_counter", "name"=>"expires",                    "unit"=>"Keys"},
                          # Redis 2.6:
                         {"type"=>"ce_counter", "name"=>"used_memory_lua",            "unit"=>"Bytes"},
                         {"type"=>"ce_gauge",   "name"=>"rdb_changes_since_last_save","unit"=>"Changes"},
                         {"type"=>"ce_gauge",   "name"=>"instantaneous_ops_per_sec",  "unit"=>"Ops"},
                         {"type"=>"ce_counter", "name"=>"rejected_connections",       "unit"=>"Connections"}
                       ]

  res = ce_metrics.create_metric_group(group_name, groupcfg)
end

def create_redis_dashboard(group_name, dashboard, server_list, apikey)
  servers = []
  server_list.each do |server_entry|
    servers.push server_entry["name"]
  end

  puts "Creating new Redis Dashboard"
  ce_metrics = CopperEgg::Metrics.new(apikey, @apihost)

  # Configure a dashboard:
  dashcfg = {}
  dashcfg["name"] = dashboard
  dashcfg["data"] = {}

  widgets = {}
  widget_cnt = 0

  servers.each do |server|
    # Create a widget  
    widgetcfg = {}
    widgetcfg["type"] = "metric"
    widgetcfg["style"] = "both"
    widgetcfg["metric"] = [group_name, "19", "keys"]
    widgetcfg["match"] = "select"
    widgetcfg["match_param"] = server
    widgets["#{widget_cnt}"] = widgetcfg.dup
    widget_cnt += 1

    widgetcfg["type"] = "metric"
    widgetcfg["style"] = "both"
    widgetcfg["metric"] = [group_name, "11", "total_connections_received"]
    widgetcfg["match"] = "select"
    widgetcfg["match_param"] = server
    widgets["#{widget_cnt}"] = widgetcfg.dup
    widget_cnt += 1

    widgetcfg["type"] = "metric"
    widgetcfg["style"] = "both"
    widgetcfg["metric"] = [group_name, "3", "connected_clients"]
    widgetcfg["match"] = "select"
    widgetcfg["match_param"] = server
    widgets["#{widget_cnt}"] = widgetcfg.dup
    widget_cnt += 1

    widgetcfg["type"] = "metric"
    widgetcfg["style"] = "both"
    widgetcfg["metric"] = [group_name, "6", "used_memory"]
    widgetcfg["match"] = "select"
    widgetcfg["match_param"] = server
    widgets["#{widget_cnt}"] = widgetcfg.dup
    widget_cnt += 1

    widgetcfg["type"] = "metric"
    widgetcfg["style"] = "both"
    widgetcfg["metric"] = [group_name, "12", "total_commands_processed"]
    widgetcfg["match"] = "select"
    widgetcfg["match_param"] = server
    widgets["#{widget_cnt}"] = widgetcfg.dup
    widget_cnt += 1
  end

  # Add the widgets to the dashboard:
  dashcfg["data"]["widgets"] = widgets

  # Set the order we want on the dashboard:
  dashcfg["data"]["order"] = widgets.keys

  # Create the dashboard:
  res = ce_metrics.create_dashboard(dashcfg)
end

####################################################################

def connect_to_mysql(hostname, user, pw, db)
  client = Mysql2::Client.new(:host => hostname,
                              :username => user,
                              :password => pw,
                              :database => db)
    
  return client
end

def monitor_mysql(mysql_servers, group_name, apikey)
  require 'mysql2'
  puts "Monitoring MySQL: "
  return if @interrupted

  rm = CopperEgg::Metrics.new(apikey, @apihost)

  while !@interupted do
    return if @interrupted

    mysql_servers.each do |mhost|
      return if @interrupted

      begin
        mysql = connect_to_mysql(mhost["hostname"], mhost["username"], mhost["password"], mhost["database"])
        mstats = mysql.query('SHOW STATUS;')

      rescue Exception => e
        puts "Error getting stats from: #{mhost['hostname']} [skipping]"
        next
      end

      minfo = {}

      mstats.each do |row|
        minfo[row["Variable_name"]] = row["Value"]
      end

      metrics = {}
      metrics["Threads_connected"]            = minfo["Threads_connected"].to_i
      metrics["Created_tmp_disk_tables"]      = minfo["Created_tmp_disk_tables"].to_i
      metrics["Handler_read_first"]           = minfo["Handler_read_first"].to_i
      metrics["Innodb_buffer_pool_wait_free"] = minfo["Innodb_buffer_pool_wait_free"].to_i
      metrics["Innodb_log_waits"]             = minfo["Innodb_log_waits"].to_i
      metrics["Innodb_data_read"]             = minfo["Innodb_data_read"].to_i
      metrics["Innodb_data_written"]          = minfo["Innodb_data_written"].to_i
      metrics["Innodb_data_pending_fsyncs"]   = minfo["Innodb_data_pending_fsyncs"].to_i
      metrics["Innodb_data_pending_reads"]    = minfo["Innodb_data_pending_reads"].to_i
      metrics["Innodb_data_pending_writes"]   = minfo["Innodb_data_pending_writes"].to_i
      metrics["Innodb_os_log_pending_fsyncs"] = minfo["Innodb_os_log_pending_fsyncs"].to_i
      metrics["Innodb_os_log_pending_writes"] = minfo["Innodb_os_log_pending_writes"].to_i
      metrics["Innodb_os_log_written"]        = minfo["Innodb_os_log_written"].to_i
      metrics["Qcache_hits"]                  = minfo["Qcache_hits"].to_i
      metrics["Qcache_lowmem_prunes"]         = minfo["Qcache_lowmem_prunes"].to_i
      metrics["Key_reads"]                    = minfo["Key_reads"].to_i
      metrics["Key_writes"]                   = minfo["Key_writes"].to_i
      metrics["Max_used_connections"]         = minfo["Max_used_connections"].to_i
      metrics["Open_tables"]                  = minfo["Open_tables"].to_i
      metrics["Open_files"]                   = minfo["Open_files"].to_i
      metrics["Select_full_join"]             = minfo["Select_full_join"].to_i
      metrics["Uptime"]                       = minfo["Uptime"].to_i
      metrics["Table_locks_immediate"]        = minfo["Table_locks_immediate"].to_i
      metrics["Bytes_received"]               = minfo["Bytes_received"].to_i
      metrics["Bytes_sent"]                   = minfo["Bytes_sent"].to_i
      metrics["Com_alter_db"]                 = minfo["Com_alter_db"].to_i
      metrics["Com_create_db"]                = minfo["Com_create_db"].to_i
      metrics["Com_delete"]                   = minfo["Com_delete"].to_i
      metrics["Com_drop_db"]                  = minfo["Com_drop_db"].to_i
      metrics["Com_insert"]                   = minfo["Com_insert"].to_i
      metrics["Com_select"]                   = minfo["Com_select"].to_i
      metrics["Com_update"]                   = minfo["Com_update"].to_i
      metrics["Queries"]                      = minfo["Queries"].to_i
      metrics["Slow_queries"]                 = minfo["Slow_queries"].to_i

      mysql.close

      rm.store_sample(group_name, mhost["name"], Time.now.to_i, metrics)
    
    end
    interruptible_sleep @freq
  end
end

def create_mysql_metric_group(group_name, group_label, apikey)
  ce_metrics = CopperEgg::Metrics.new(apikey, @apihost)

  # no metric group found - create one
  puts "Creating MySQL metric group"

  groupcfg = {}
  groupcfg["name"] = group_name
  groupcfg["label"] = group_label
  groupcfg["frequency"] = @freq
  groupcfg["metrics"] = [{"type"=>"ce_gauge",   "name"=>"Threads_connected",            "unit"=>"Threads"},
                         {"type"=>"ce_counter", "name"=>"Created_tmp_disk_tables",      "unit"=>"Tables"},
                         {"type"=>"ce_gauge",   "name"=>"Handler_read_first",           "unit"=>"Reads"},
                         {"type"=>"ce_gauge",   "name"=>"Innodb_buffer_pool_wait_free"},
                         {"type"=>"ce_gauge",   "name"=>"Innodb_log_waits",             "unit"=>"Waits"},
                         {"type"=>"ce_counter", "name"=>"Innodb_data_read",             "unit"=>"Bytes"},
                         {"type"=>"ce_counter", "name"=>"Innodb_data_written",          "unit"=>"Bytes"},
                         {"type"=>"ce_gauge",   "name"=>"Innodb_data_pending_fsyncs",   "unit"=>"FSyncs"},
                         {"type"=>"ce_gauge",   "name"=>"Innodb_data_pending_reads",    "unit"=>"Reads"},
                         {"type"=>"ce_gauge",   "name"=>"Innodb_data_pending_writes",   "unit"=>"Writes"},
                         {"type"=>"ce_gauge",   "name"=>"Innodb_os_log_pending_fsyncs", "unit"=>"FSyncs"},
                         {"type"=>"ce_gauge",   "name"=>"Innodb_os_log_pending_writes", "unit"=>"Writes"},
                         {"type"=>"ce_counter", "name"=>"Innodb_os_log_written"},
                         {"type"=>"ce_counter", "name"=>"Qcache_hits",                  "unit"=>"Hits"},
                         {"type"=>"ce_counter", "name"=>"Qcache_lowmem_prunes",         "unit"=>"Prunes"},
                         {"type"=>"ce_counter", "name"=>"Key_reads",                    "unit"=>"Reads"},
                         {"type"=>"ce_counter", "name"=>"Key_writes",                   "unit"=>"Writes"},
                         {"type"=>"ce_gauge",   "name"=>"Max_used_connections",         "unit"=>"Connections"},
                         {"type"=>"ce_gauge",   "name"=>"Open_tables",                  "unit"=>"Tables"},
                         {"type"=>"ce_gauge",   "name"=>"Open_files",                   "unit"=>"Files"},
                         {"type"=>"ce_counter", "name"=>"Select_full_join"},
                         {"type"=>"ce_counter", "name"=>"Uptime",                       "unit"=>"Seconds"},
                         {"type"=>"ce_gauge",   "name"=>"Table_locks_immediate"},
                         {"type"=>"ce_counter", "name"=>"Bytes_received",               "unit"=>"Bytes"},
                         {"type"=>"ce_counter", "name"=>"Bytes_sent",                   "unit"=>"Bytes"},
                         {"type"=>"ce_counter", "name"=>"Com_alter_db",                 "unit"=>"Commands"},
                         {"type"=>"ce_counter", "name"=>"Com_create_db",                "unit"=>"Commands"},
                         {"type"=>"ce_counter", "name"=>"Com_delete",                   "unit"=>"Commands"},
                         {"type"=>"ce_counter", "name"=>"Com_drop_db",                  "unit"=>"Commands"},
                         {"type"=>"ce_counter", "name"=>"Com_insert",                   "unit"=>"Commands"},
                         {"type"=>"ce_counter", "name"=>"Com_select",                   "unit"=>"Commands"},
                         {"type"=>"ce_counter", "name"=>"Com_update",                   "unit"=>"Commands"},
                         {"type"=>"ce_counter", "name"=>"Queries",                      "unit"=>"Queries"},
                         {"type"=>"ce_counter", "name"=>"Slow_queries",                 "unit"=>"Slow Queries"}
                       ]

  res = ce_metrics.create_metric_group(group_name, groupcfg)
end

def create_mysql_dashboard(group_name, dashboard, server_list, apikey)
  servers = []
  server_list.each do |server_entry|
    servers.push server_entry["name"]
  end

  puts "Creating new MySQL/RDS Dashboard"
  ce_metrics = CopperEgg::Metrics.new(apikey, @apihost)

  # Configure a dashboard:
  dashcfg = {}
  dashcfg["name"] = dashboard
  dashcfg["data"] = {}

  widgets = {}
  widget_cnt = 0

  servers.each do |server|
    # Create a widget  
    widgetcfg = {}
    widgetcfg["type"] = "metric"
    widgetcfg["style"] = "both"
    widgetcfg["metric"] = [group_name, "32", "Queries"]
    widgetcfg["match"] = "select"
    widgetcfg["match_param"] = server
    widgets["#{widget_cnt}"] = widgetcfg.dup
    widget_cnt += 1

    widgetcfg["type"] = "metric"
    widgetcfg["style"] = "both"
    widgetcfg["metric"] = [group_name, "33", "Slow_queries"]
    widgetcfg["match"] = "select"
    widgetcfg["match_param"] = server
    widgets["#{widget_cnt}"] = widgetcfg.dup
    widget_cnt += 1

    widgetcfg["type"] = "metric"
    widgetcfg["style"] = "both"
    widgetcfg["metric"] = [group_name, "18", "Open_tables"]
    widgetcfg["match"] = "select"
    widgetcfg["match_param"] = server
    widgets["#{widget_cnt}"] = widgetcfg.dup
    widget_cnt += 1

    widgetcfg["type"] = "metric"
    widgetcfg["style"] = "both"
    widgetcfg["metric"] = [group_name, "23", "Bytes_received"]
    widgetcfg["match"] = "select"
    widgetcfg["match_param"] = server
    widgets["#{widget_cnt}"] = widgetcfg.dup
    widget_cnt += 1

    widgetcfg["type"] = "metric"
    widgetcfg["style"] = "both"
    widgetcfg["metric"] = [group_name, "24", "Bytes_sent"]
    widgetcfg["match"] = "select"
    widgetcfg["match_param"] = server
    widgets["#{widget_cnt}"] = widgetcfg.dup
    widget_cnt += 1
  end

  # Add the widgets to the dashboard:
  dashcfg["data"]["widgets"] = widgets

  # Set the order we want on the dashboard:
  dashcfg["data"]["order"] = widgets.keys

  # Create the dashboard:
  res = ce_metrics.create_dashboard(dashcfg)
end

####################################################################

def monitor_apache(apache_servers, group_name, apikey)

  puts "Monitoring Apache: "
  return if @interrupted

  rm = CopperEgg::Metrics.new(apikey, @apihost)

  while !@interupted do
    return if @interrupted

    apache_servers.each do |ahost|
      return if @interrupted

      begin
        uri = URI.parse("#{ahost['url']}/server-status?auto")
        response = Net::HTTP.get_response(uri)
        if response.code != "200"
          return nil
        end

        astats = response.body.split(/\r*\n/)

      rescue Exception => e
        puts "Error getting stats from: #{ahost['url']} [skipping]"
        next
      end

      ainfo = {}

      astats.each do |row|
        name, value = row.split(": ")
        ainfo[name] = value
      end

      metrics = {}
      metrics["total_accesses"]               = ainfo["Total Accesses"].to_i
      metrics["total_kbytes"]                 = ainfo["Total kBytes"].to_i
      metrics["cpu_load"]                     = ainfo["CPULoad"].to_f*100
      metrics["uptime"]                       = ainfo["Uptime"].to_i
      metrics["request_per_sec"]              = ainfo["ReqPerSec"].to_f
      metrics["bytes_per_sec"]                = ainfo["BytesPerSec"].to_i
      metrics["bytes_per_request"]            = ainfo["BytesPerReq"].to_f
      metrics["busy_workers"]                 = ainfo["BusyWorkers"].to_i
      metrics["idle_workers"]                 = ainfo["IdleWorkers"].to_i
      metrics["connections_total"]            = ainfo["ConnsTotal"].to_i
      metrics["connections_async_writing"]    = ainfo["ConnsAsyncWriting"].to_i
      metrics["connections_async_keepalive"]  = ainfo["ConnsAsyncKeepAlive"].to_i
      metrics["connections_async_closing"]    = ainfo["ConnsAsyncClosing"].to_i

      rm.store_sample(group_name, ahost["name"], Time.now.to_i, metrics)
    
    end
    interruptible_sleep @freq
  end
end

def create_apache_metric_group(group_name, group_label, apikey)
  ce_metrics = CopperEgg::Metrics.new(apikey, @apihost)

  # no metric group found - create one
  puts "Creating Apache metric group"

  groupcfg = {}
  groupcfg["name"] = group_name
  groupcfg["label"] = group_label
  groupcfg["frequency"] = @freq
  groupcfg["metrics"] = [{"type"=>"ce_gauge",   "name"=>"total_accesses",             "unit"=>"Accesses"},
                         {"type"=>"ce_gauge",   "name"=>"total_kbytes",               "unit"=>"kBytes"},
                         {"type"=>"ce_gauge_f", "name"=>"cpu_load",                   "unit"=>"Percent"},
                         {"type"=>"ce_gauge",   "name"=>"uptime",                     "unit"=>"Seconds"},
                         {"type"=>"ce_gauge_f", "name"=>"request_per_sec",            "unit"=>"Req/s"},
                         {"type"=>"ce_gauge",   "name"=>"bytes_per_sec",              "unit"=>"Bytes/s"},
                         {"type"=>"ce_gauge_f", "name"=>"bytes_per_request",          "unit"=>"Bytes/Req"},
                         {"type"=>"ce_gauge",   "name"=>"busy_workers",               "unit"=>"Busy Workers"},
                         {"type"=>"ce_gauge",   "name"=>"idle_workers",               "unit"=>"Idle Workers"},
                         {"type"=>"ce_gauge",   "name"=>"connections_total",          "unit"=>"Connections"},
                         {"type"=>"ce_gauge",   "name"=>"connections_async_writing",  "unit"=>"Connections"},
                         {"type"=>"ce_gauge",   "name"=>"connections_async_keepalive","unit"=>"Connections"},
                         {"type"=>"ce_gauge",   "name"=>"connections_async_closing",  "unit"=>"Connections"}
                       ]

  res = ce_metrics.create_metric_group(group_name, groupcfg)
end

def create_apache_dashboard(group_name, dashboard, server_list, apikey)
  servers = []
  server_list.each do |server_entry|
    servers.push server_entry["name"]
  end

  puts "Creating new Apache Dashboard"
  ce_metrics = CopperEgg::Metrics.new(apikey, @apihost)

  # Configure a dashboard:
  dashcfg = {}
  dashcfg["name"] = dashboard
  dashcfg["data"] = {}

  widgets = {}
  widget_cnt = 0

  servers.each do |server|
    # Create a widget  
    widgetcfg = {}
    widgetcfg["type"] = "metric"
    widgetcfg["style"] = "both"
    widgetcfg["metric"] = [group_name, "0", "total_accesses"]
    widgetcfg["match"] = "select"
    widgetcfg["match_param"] = server
    widgets["#{widget_cnt}"] = widgetcfg.dup
    widget_cnt += 1

    widgetcfg["type"] = "metric"
    widgetcfg["style"] = "both"
    widgetcfg["metric"] = [group_name, "4", "request_per_sec"]
    widgetcfg["match"] = "select"
    widgetcfg["match_param"] = server
    widgets["#{widget_cnt}"] = widgetcfg.dup
    widget_cnt += 1

    widgetcfg["type"] = "metric"
    widgetcfg["style"] = "both"
    widgetcfg["metric"] = [group_name, "7", "busy_workers"]
    widgetcfg["match"] = "select"
    widgetcfg["match_param"] = server
    widgets["#{widget_cnt}"] = widgetcfg.dup
    widget_cnt += 1

    widgetcfg["type"] = "metric"
    widgetcfg["style"] = "both"
    widgetcfg["metric"] = [group_name, "9", "connections_total"]
    widgetcfg["match"] = "select"
    widgetcfg["match_param"] = server
    widgets["#{widget_cnt}"] = widgetcfg.dup
    widget_cnt += 1

    widgetcfg["type"] = "metric"
    widgetcfg["style"] = "both"
    widgetcfg["metric"] = [group_name, "8", "idle_workers"]
    widgetcfg["match"] = "select"
    widgetcfg["match_param"] = server
    widgets["#{widget_cnt}"] = widgetcfg.dup
    widget_cnt += 1
  end

  # Add the widgets to the dashboard:
  dashcfg["data"]["widgets"] = widgets

  # Set the order we want on the dashboard:
  dashcfg["data"]["order"] = widgets.keys

  # Create the dashboard:
  res = ce_metrics.create_dashboard(dashcfg)
end

####################################################################

def monitor_nginx(nginx_servers, group_name, apikey)

  puts "Monitoring Nginx: "
  return if @interrupted

  rm = CopperEgg::Metrics.new(apikey, @apihost)

  while !@interupted do
    return if @interrupted

    nginx_servers.each do |nhost|
      return if @interrupted

      begin
        uri = URI.parse("#{nhost['url']}/nginx_status")
        response = Net::HTTP.get_response(uri)
        if response.code != "200"
          next
        end

        nstats = response.body.split(/\r*\n/)

      rescue Exception => e
        puts "Error getting stats from: #{nhost['url']} [skipping]"
        next
      end

      metrics = {}
      metrics["active_connections"]           = nstats[0].split(": ")[1].to_i
      metrics["connections_accepts"]          = nstats[2].split(/\s+/)[0].to_i
      metrics["connections_handled"]          = nstats[2].split(/\s+/)[1].to_i
      metrics["connections_requested"]        = nstats[2].split(/\s+/)[2].to_i
      metrics["reading"]                      = nstats[3].split(/\s+/)[1].to_i
      metrics["writing"]                      = nstats[3].split(/\s+/)[3].to_i
      metrics["waiting"]                      = nstats[3].split(/\s+/)[5].to_i

      rm.store_sample(group_name, nhost["name"], Time.now.to_i, metrics)
    
    end
    interruptible_sleep @freq
  end
end

def create_nginx_metric_group(group_name, group_label, apikey)
  ce_metrics = CopperEgg::Metrics.new(apikey, @apihost)

  # no metric group found - create one
  puts "Creating Nginx metric group"

  groupcfg = {}
  groupcfg["name"] = group_name
  groupcfg["label"] = group_label
  groupcfg["frequency"] = @freq
  groupcfg["metrics"] = [{"type"=>"ce_gauge",   "name"=>"active_connections",     "unit"=>"Connections"},
                         {"type"=>"ce_gauge",   "name"=>"connections_accepts",    "unit"=>"Connections"},
                         {"type"=>"ce_gauge",   "name"=>"connections_handled",    "unit"=>"Connections"},
                         {"type"=>"ce_gauge",   "name"=>"connections_requested",  "unit"=>"Connections"},
                         {"type"=>"ce_gauge",   "name"=>"reading",                "unit"=>"Connections"},
                         {"type"=>"ce_gauge",   "name"=>"writing",                "unit"=>"Connections"},
                         {"type"=>"ce_gauge",   "name"=>"waiting",                "unit"=>"Connections"}
                       ]

  res = ce_metrics.create_metric_group(group_name, groupcfg)
end

def create_nginx_dashboard(group_name, dashboard, server_list, apikey)
  servers = []
  server_list.each do |server_entry|
    servers.push server_entry["name"]
  end

  puts "Creating new Nginx Dashboard"
  ce_metrics = CopperEgg::Metrics.new(apikey, @apihost)

  # Configure a dashboard:
  dashcfg = {}
  dashcfg["name"] = dashboard
  dashcfg["data"] = {}

  widgets = {}
  widget_cnt = 0

  servers.each do |server|
    # Create a widget  
    widgetcfg = {}
    widgetcfg["type"] = "metric"
    widgetcfg["style"] = "both"
    widgetcfg["metric"] = [group_name, "0", "active_connections"]
    widgetcfg["match"] = "select"
    widgetcfg["match_param"] = server
    widgets["#{widget_cnt}"] = widgetcfg.dup
    widget_cnt += 1

    widgetcfg["type"] = "metric"
    widgetcfg["style"] = "both"
    widgetcfg["metric"] = [group_name, "1", "connections_accepts"]
    widgetcfg["match"] = "select"
    widgetcfg["match_param"] = server
    widgets["#{widget_cnt}"] = widgetcfg.dup
    widget_cnt += 1

    widgetcfg["type"] = "metric"
    widgetcfg["style"] = "both"
    widgetcfg["metric"] = [group_name, "2", "connections_handled"]
    widgetcfg["match"] = "select"
    widgetcfg["match_param"] = server
    widgets["#{widget_cnt}"] = widgetcfg.dup
    widget_cnt += 1

    widgetcfg["type"] = "metric"
    widgetcfg["style"] = "both"
    widgetcfg["metric"] = [group_name, "4", "reading"]
    widgetcfg["match"] = "select"
    widgetcfg["match_param"] = server
    widgets["#{widget_cnt}"] = widgetcfg.dup
    widget_cnt += 1

    widgetcfg["type"] = "metric"
    widgetcfg["style"] = "both"
    widgetcfg["metric"] = [group_name, "5", "writing"]
    widgetcfg["match"] = "select"
    widgetcfg["match_param"] = server
    widgets["#{widget_cnt}"] = widgetcfg.dup
    widget_cnt += 1
  end

  # Add the widgets to the dashboard:
  dashcfg["data"]["widgets"] = widgets

  # Set the order we want on the dashboard:
  dashcfg["data"]["order"] = widgets.keys

  # Create the dashboard:
  res = ce_metrics.create_dashboard(dashcfg)
end

####################################################################

# init - check apikey? make sure site is valid, and apikey is ok
trap("INT") { parent_interrupt }
trap("TERM") { parent_interrupt }


#################################

def create_metric_group(service, apikey)
if service == "redis"
    create_redis_metric_group(@config[service]["group_name"], @config[service]["group_label"], apikey)
  elsif service == "mysql"
    create_mysql_metric_group(@config[service]["group_name"], @config[service]["group_label"], apikey)
  elsif service == "apache"
    create_apache_metric_group(@config[service]["group_name"], @config[service]["group_label"], apikey)
  elsif service == "nginx"
    create_nginx_metric_group(@config[service]["group_name"], @config[service]["group_label"], apikey)
  else
    puts "Service #{service} not recognized"
  end
end

def create_dashboard(service, apikey)
  if service == "redis"
    create_redis_dashboard(@config[service]["group_name"], @config[service]["dashboard"], @config[service]["servers"], apikey)
  elsif service == "mysql"
    create_mysql_dashboard(@config[service]["group_name"], @config[service]["dashboard"], @config[service]["servers"], apikey)
  elsif service == "apache"
    create_apache_dashboard(@config[service]["group_name"], @config[service]["dashboard"], @config[service]["servers"], apikey)
  elsif service == "nginx"
    create_nginx_dashboard(@config[service]["group_name"], @config[service]["dashboard"], @config[service]["servers"], apikey)
  else
    puts "Service #{service} not recognized"
  end
end

def monitor_service(service, apikey)
  if service == "redis"
    monitor_redis(@config[service]["servers"], @config[service]["group_name"], apikey)
  elsif service == "mysql"
    monitor_mysql(@config[service]["servers"], @config[service]["group_name"], apikey)
  elsif service == "apache"
    monitor_apache(@config[service]["servers"], @config[service]["group_name"], apikey)
  elsif service == "nginx"
    monitor_nginx(@config[service]["servers"], @config[service]["group_name"], apikey)
  else
    puts "Service #{service} not recognized"
  end
end

#################################
@services.each do |service|
  if @config[service] && @config[service]["servers"].length > 0

    # metric group check
    puts "Checking for existence of metric group for #{service}"
    ce_metrics = CopperEgg::Metrics.new(apikey, @apihost)
    mgroup = ce_metrics.metric_group(@config[service]["group_name"])

    if mgroup.nil?
      # no metric group found - create one
      create_metric_group(service, apikey)
    end

    # Check for dashboard:
    puts "Checking for existence of #{service} Dashboard"
    dashboard = ce_metrics.dashboard(@config[service]["dashboard"])

    if dashboard.nil?
      # no dashboard found - create one
      create_dashboard(service, apikey)
    end

    child_pid = fork {
      trap("INT") { child_interrupt if !@interrupted }
      trap("TERM") { child_interrupt if !@interrupted }

      monitor_service(service, apikey)
    }
    @worker_pids.push child_pid
  end
end

# ... wait for all processes to exit ...
p Process.waitall
