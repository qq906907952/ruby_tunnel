$LOAD_PATH << "."
require 'config'
require 'client'
require 'server'

$pids = []
END{
    for i in $pids
        begin
            Process.kill(9, i)
        rescue
        end
    end
}

def main()
    client, servs = load_conf()


    for i in client
        p "================================="
        case i.mode
        when Handshake::MODE_LOCAL_REMOTE
            p "client side, mode:local-remote, serve_addr:#{i.serv_addr}:#{i.serv_port} | client:#{i.listen_port} -> remote:#{i.redir_addr}:#{i.redir_port}"
        when Handshake::MODE_REMOTE_LOCAL
            p "client side, mode:remote-local, serve_addr:#{i.serv_addr}:#{i.serv_port} | remote:#{i.listen_port} -> client:#{i.redir_addr}:#{i.redir_port}"
        end
        pid = fork {
            handle_client(i)
        }
        $pids << pid
        Thread.start(pid) {
            |pid|
            Process.wait pid
            exit (1)
        }

    end
    p "================================="


    for i in servs
        p "======================================"
        p "server side, listen_port;#{i.listen_port}"
        pid = fork {
            handle_serv(i)
        }
        $pids << pid
        Thread.start(pid) {
            |pid|
            Process.wait pid
            exit (1)
        }
        p "======================================"
    end

    loop {
        sleep(99999999999)
    }
end


main()
