require 'socket'
require 'util'
require 'frame'




class Server
    attr_accessor :listen_port, :ssl_context

    def initialize(conf)
        unless conf.instance_of?(Hash)
            raise("serv format malformed")
        end
        @listen_port = conf["listen_port"]
        cert = conf["cert"]
        @ssl_context = OpenSSL::SSL::SSLContext.new
        @ssl_context.min_version = OpenSSL::SSL::TLS1_3_VERSION
        @ssl_context.verify_mode = OpenSSL::SSL::VERIFY_PEER | OpenSSL::SSL::VERIFY_FAIL_IF_NO_PEER_CERT

        # @type[Array]
        cert_chain = cert["cert_chain"]
        if !cert_chain.instance_of?(Array) || cert_chain.length < 1
            raise "cert_chain length less than 1 or nor an array"
        end
        private_key = cert["private_key"]
        @ssl_context.add_certificate(
            OpenSSL::X509::Certificate.new(File.read(cert_chain[0])),
            OpenSSL::PKey::read(File.read(private_key)),
            cert_chain.slice(1...cert_chain.length).map {
                |cert|
                OpenSSL::X509::Certificate.new(File.read(cert))
            })

        client_certs = cert["cient_certs"]
        if !client_certs.instance_of?(Array) || client_certs.length < 1
            raise "client_certs length less than 1 or not an array"
        end
        cert_store = OpenSSL::X509::Store.new
        client_certs.each {
            |cert|
            cert_store.add_cert(OpenSSL::X509::Certificate.new(File.read(cert)))
        }
        @ssl_context.cert_store = cert_store

    end
end


def handle_serv(serv)
    begin
        serv = OpenSSL::SSL::SSLServer.new(TCPServer.new("0.0.0.0", serv.listen_port), serv.ssl_context)
    rescue Exception => e
        abort e.message
    end
    loop {
        begin
            con = serv.accept
            con.sync_close = true
            Thread.start(con) {
                #@type [OpenSSL::SSL::SSLSocket]
                |con|

                begin
                    data = socket_read_at_least(con, to_uint16(socket_read_at_least(con, 2).unpack("C*")))
                    #@type [Handshake]
                    handshake = Handshake.parse_from_bytes(data.unpack("C*"))
                    case handshake.state_code
                    when Handshake::INIT
                        unless handshake.port.between?(1, 65535)
                            raise ProtocolException.new 'port number illegal'
                        end
                    else
                        raise ProtocolException.new 'unknown state'
                    end

                rescue IOError => e
                    p_exception(__FILE__, __LINE__, e.message)
                    con.close()
                    Thread.exit
                rescue ProtocolException => e
                    begin
                        socket_write_all(con, Handshake.new(Handshake::FAIL, 0, 0, e.message).to_bytes)
                    rescue Exception => e
                        p_exception(__FILE__, __LINE__, e.message)
                    ensure
                        con.close()
                        Thread.exit
                    end


                end

                case handshake.mode
                when Handshake::MODE_REMOTE_LOCAL
                    begin
                        listen = TCPServer.new("0.0.0.0", handshake.port)
                        socket_write_all(con, Handshake.new(Handshake::SUCCESS, 0, 0).to_bytes)

                    rescue Errno::EADDRINUSE
                        begin
                            socket_write_all(con, Handshake.new(Handshake::FAIL, 0, 0, "port can not listen").to_bytes)
                        rescue IOError
                            p_exception(__FILE__, __LINE__, e.message)
                            con.close
                        ensure
                            Thread.exit
                        end

                    rescue Exception => e
                        p_exception(__FILE__, __LINE__, e.message)
                        begin
                            socket_write_all(con, Handshake.new(Handshake::FAIL, 0, 0, e.message).to_bytes)
                        rescue IOError
                        ensure
                            listen.close
                            con.close
                            Thread.exit
                        end
                    end

                    p "client connect, mode:remote-local, remote:#{handshake.port} -> local:?:?"

                    id_queue = SizedQueue.new(65535)
                    send_queue = SizedQueue.new(1)
                    map_lock = Mutex.new
                    recv_queue = {}
                    for i in (0...65535)
                        id_queue.push i
                    end

                    Thread.start {

                        loop {
                            begin
                                local = listen.accept
                                id = id_queue.pop(true)
                            rescue ThreadError
                                p_exception(__FILE__, __LINE__, "can not get id")
                                local.close
                                next
                            rescue Exception => e
                                p_exception(__FILE__, __LINE__, e.message)
                                break
                            end
                            que = Queue.new

                            Thread.start {
                                begin
                                    send_queue.push(Frame.new(Frame::ACTION_NEW_CONN, id, nil))
                                rescue ClosedQueueError
                                    local.close
                                    Thread.exit
                                end

                                map_lock.synchronize {
                                    recv_queue[id] = que
                                }

                                begin
                                    local_loop(local, send_queue, que, id)
                                rescue ClosedQueueError => e
                                    p_exception(__FILE__, __LINE__, e.message, id)
                                rescue IOError => e
                                    p_exception(__FILE__, __LINE__, e.message, id)
                                    id_queue.push(id)
                                ensure
                                    local.close
                                end
                            }
                        }
                    }

                    begin
                        remote_loop(con, send_queue, recv_queue, map_lock)
                    rescue ProtocolException => e
                        p_exception(__FILE__, __LINE__, e.message)
                        abort e.message
                    rescue IOError => e
                        p_exception(__FILE__, __LINE__, e.message)
                        con.close
                        listen.close
                        send_queue.clear
                        send_queue.close
                        map_lock.synchronize {
                            recv_queue.each {
                                |_, v|
                                v.close
                            }
                        }

                    end


                when Handshake::MODE_LOCAL_REMOTE
                    begin
                        socket_write_all(con, Handshake.new(Handshake::SUCCESS, 0, 0).to_bytes)
                    rescue IOError => e
                        p_exception(__FILE__, __LINE__, e.message)
                        con.close
                        Thread.exit
                    end

                    redir_addr = handshake.extend
                    redir_port = handshake.port
                    send_queue = SizedQueue.new(1)
                    recv_queue = {}
                    map_lock = Mutex.new
                    p "client connect, mode:local-remote,  local:?:? -> remote:#{handshake.extend}:#{handshake.port} "

                    begin
                        redir_side_loop(con, map_lock, send_queue, recv_queue, redir_addr, redir_port)
                    rescue ProtocolException, UnknownError => e
                        p_exception(__FILE__, __LINE__, e.message)
                        abort e.message
                    rescue Exception => e
                        p_exception(__FILE__, __LINE__, e.message)
                        con.close
                        send_queue.clear
                        send_queue.close
                        map_lock.synchronize {
                            recv_queue.each {
                                |_, v|
                                v.close
                            }
                        }

                        Thread.exit
                    end
                else
                    begin
                        socket_write_all(con, Handshake.new(Handshake::FAIL, 0, 0, "unknown mode").to_bytes)
                    rescue IOError => e
                        p_exception(__FILE__, __LINE__, e.message)
                    end
                    con.close()
                    Thread.exit
                end

            }

        rescue Exception => e
            p_exception(__FILE__, __LINE__, e.message)
            unless con.nil?
                con.close
            end
        end

    }

end