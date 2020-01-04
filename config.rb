require 'optparse'
require 'json'
require 'client'
require 'server'

$tcp_recv_buf=65500
$LOCAL_REMOTE = "local_remote"
$REMOTE_LOCAL = "remote_local"
$DEBUG = false


def load_conf()
  clients, servers = [],[]
  when_key_not_found = ->(_,k){
    raise "#{k} not found"
  }
  _c=false
  OptParse.new {
    #@type arg  [OptionParser]
      |arg|

    arg.on("-cconfig", "config file") {
        |config|
      _c=true
      begin
        conf = JSON.parse(File.read(config))
        clis = conf["client"]
        unless clis.nil?
          unless clis.instance_of?(Array)
            Process.abort "client must array"
          end
          for i in clis
            i.default_proc=when_key_not_found
            clients << Client.new(i)
          end
        end

        servs=conf["server"]
        unless  servs.nil?
          unless servs.instance_of?(Array)
            Process.abort "server must array"
          end
          for i in servs
            i.default_proc=when_key_not_found
            servers << Server.new(i)
          end
        end
      rescue Exception => e
        Process.abort e.full_message
      end
    }

  }.parse(ARGV)
  unless _c
    abort 'config file no provide. usage: ruby main.rb -c ${config_file_path} '
  end

  return clients, servers
end
