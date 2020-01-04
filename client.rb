require 'openssl'
require 'socket'
require 'util'
require 'frame'
require 'connection'


class Client

    attr_accessor :serv_addr, :serv_port, :listen_port, :mode, :redir_addr, :redir_port, :ssl_context, :local

    def initialize(conf)
        unless conf.instance_of?(Hash)
            raise("client format malformed")
        end
        #@type[Hash]
        @closed = true
        @redir_addr = conf["redir_addr"]
        @redir_port = check_port(conf["redir_port"])
        @serv_addr = conf["server_addr"]
        @serv_port = check_port(conf["server_port"])
        @listen_port = check_port(conf["listen_port"])
        cert = conf["cert"]
        @serv_name = cert["serv_name"] || @serv_addr
        serv_cert = cert["serv_root_cert"]
        private_key = cert["private_key"]
        # @type[Array]
        cert_chain = cert["cert_chain"]
        if !cert_chain.instance_of?(Array) || cert_chain.length < 1
            raise "cert_chain length less than 1 or not an array"
        end
        #@type [OpenSSL::SSL::SSLContext ]
        @ssl_context = OpenSSL::SSL::SSLContext.new
        @ssl_context.servername_cb = @serv_name
        @ssl_context.min_version = OpenSSL::SSL::TLS1_3_VERSION
        @ssl_context.verify_mode = OpenSSL::SSL::VERIFY_PEER | OpenSSL::SSL::VERIFY_FAIL_IF_NO_PEER_CERT
        @ssl_context.verify_hostname = true
        cert_store = OpenSSL::X509::Store.new
        cert_store.add_cert(OpenSSL::X509::Certificate.new(File.read(serv_cert)))
        @ssl_context.cert_store = cert_store
        @ssl_context.add_certificate(
            OpenSSL::X509::Certificate.new(File.read(cert_chain[0])),
            OpenSSL::PKey::read(File.read(private_key)),
            cert_chain.slice(1...cert_chain.length).map {
                |cert|
                OpenSSL::X509::Certificate.new(File.read(cert))
            })

        mode = conf["redir_mode"]
        case mode
        when $LOCAL_REMOTE
            @mode = 1
            @local = TCPServer.new(@listen_port)
        when $REMOTE_LOCAL
            @mode = 2
        else
            Process.abort "redir_mode must one of local_remote or remote_local"
        end
    end

    def connect_to_serv()
        #@type [TCPSocket]
        remote = TCPSocket.new(@serv_addr, @serv_port)
        remote.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true)
        remote.setsockopt(Socket::SOL_TCP, Socket::TCP_KEEPINTVL, 10)
        remote.setsockopt(Socket::SOL_TCP, Socket::TCP_KEEPCNT, 5)
        remote = OpenSSL::SSL::SSLSocket.new(remote, @ssl_context)
        remote.sync_close = true
        remote.connect()

        case @mode
        when Handshake::MODE_LOCAL_REMOTE
            socket_write_all(remote, Handshake.new(Handshake::INIT, @mode, @redir_port, @redir_addr).to_bytes)
        when Handshake::MODE_REMOTE_LOCAL
            socket_write_all(remote, Handshake.new(Handshake::INIT, @mode, @listen_port).to_bytes)
        else
            raise UnknownError.new("unknown error ")
        end

        len = to_uint16(socket_read_at_least(remote, 2).unpack("C*"))
        h = Handshake.parse_from_bytes(socket_read_at_least(remote, len).unpack("C*"))

        case h.state_code
        when Handshake::SUCCESS
            return remote
        when Handshake::FAIL
            raise HandshakeException.new(h.extend)
        else
            raise ProtocolException.new("recv unknown handshake")
        end
    end

end

#@param client [Client]
def handle_client(client)
    case client.mode
    when Handshake::MODE_LOCAL_REMOTE
        id_queue = SizedQueue.new(65535)
        send_queue = nil
        recv_queue = nil
        map_lock = Mutex.new
        wait_lock = Mutex.new
        for i in (0...65535)
            id_queue.push i
        end
        wait_lock.lock
        Thread.start {
            loop {

                local = client.local.accept
                begin
                    id = id_queue.pop(true)
                rescue ThreadError
                    local.close
                    next
                end

                wait_lock.synchronize {
                    que = Queue.new
                    map_lock.synchronize {
                        recv_queue[id] = que
                    }

                    Thread.start(local, id, send_queue, que) {
                        |local, id, send_queue, que|
                        begin
                            send_queue.push(Frame.new(Frame::ACTION_NEW_CONN, id, nil))
                        rescue ClosedQueueError => e
                            p_exception(__FILE__, __LINE__, e.message, id)
                            id_queue.push(id)
                            local.close
                            que.close
                            if $DEBUG
                                $payload_lock.synchronize {
                                    $payload -= 1
                                    p "payload:#{$payload}"
                                }
                            end
                            Thread.exit
                        end

                        begin
                            local_loop(local, send_queue, que, id)
                        rescue ClosedQueueError, IOError => e
                            p_exception(__FILE__, __LINE__, e.message, id)
                            local.close
                            id_queue.push(id)

                        end
                    }
                }
            }
        }

        loop {
            begin
                #@type [OpenSSL::SSL::SSLSocket]
                remote = client.connect_to_serv()
            rescue Exception => e
                p e.message
                p_exception(__FILE__, __LINE__, e.message)
                unless remote.nil?
                    remote.close
                end
                sleep 5
                retry
            end
            send_queue = SizedQueue.new(1)
            recv_queue = Hash.new
            wait_lock.unlock

            begin
                remote_loop(remote, send_queue, recv_queue, map_lock)
            rescue ProtocolException => e
                p_exception(__FILE__, __LINE__, e.message)
                abort e.message
            rescue IOError =>e
                p_exception(__FILE__, __LINE__, e.message)
                wait_lock.lock
                remote.close
                send_queue.clear
                send_queue.close
                map_lock.synchronize {
                    recv_queue.each {
                        |_, v|
                        v.close
                    }
                }
                next

            end
        }


    when Handshake::MODE_REMOTE_LOCAL
        begin
            send_queue = SizedQueue.new(1)
            recv_queue = {}
            map_lock = Mutex.new
            remote = client.connect_to_serv()
            redir_side_loop(remote, map_lock, send_queue, recv_queue, client.redir_addr, client.redir_port)
        rescue HandshakeException => e
            p_exception(__FILE__, __LINE__, e.message)
            unless remote.nil?
                remote.close
            end
            retry
        rescue UnknownError, ProtocolException => e
            p_exception(__FILE__, __LINE__, e.message)
            abort e.message
        rescue Exception => e
            p e.message
            p_exception(__FILE__, __LINE__, e.message)
            send_queue.clear
            send_queue.close
            unless remote.nil?
                remote.close
            end
            map_lock.synchronize {
                recv_queue.each {
                    |_, v|
                    v.close
                }
            }
            sleep(3)
            retry
        end
    else
        Process.abort "unknown error"
    end

end
