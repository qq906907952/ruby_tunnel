# @param [TCPServer] tcpserv
# @param [Queue] id_queue
# @param [Queue] que
# @param [Queue] send_queue
def local_loop(local, send_queue, que, id)
    Thread.start {
        loop {
            begin
                #@type [Frame]
                frame = que.pop
                if frame.nil?
                    raise IOError.new("que close")
                end

                case frame.action
                when Frame::DATA
                    socket_write_all(local, frame.get_data)
                when Frame::ACTION_CLOSE_CONN
                    p_exception(__FILE__, __LINE__, "recv frame with close ", id)
                    break
                else
                    abort "recv unknown frame"
                end
            rescue IOError => e
                p_exception(__FILE__, __LINE__, e.message, id)
                break
            end
        }
        local.close
    }

    loop {
        begin
            data = local.recv($tcp_recv_buf)
        rescue
            send_queue.push(Frame.new(Frame::ACTION_CLOSE_CONN, id))
            raise IOError.new("local close")
        end

        if data == "" || data.nil?
            send_queue.push(Frame.new(Frame::ACTION_CLOSE_CONN, id))
            raise IOError.new("local close")
        end
        send_queue.push(Frame.new(Frame::DATA, id, data.unpack("C*")))
    }

end


# @param [OpenSSL::SSL::SSLSocket] remote
# @param [Queue] send_queue
def remote_loop(remote, send_queue, recv_queue, map_lock)
    Thread.start {

        loop {
            begin
                #@type[Frame]
                frame = send_queue.pop
                if frame.nil?
                    raise IOError.new("send queue close")
                end
                socket_write_all(remote, frame.to_bytes)
            rescue IOError => e
                p_exception(__FILE__, __LINE__, e.message)
                break
            end
        }
        remote.close
        send_queue.clear
        send_queue.close
    }

    loop {

        data = socket_read_at_least(remote, to_uint16(socket_read_at_least(remote, 2).unpack("C*")))
        frame = Frame.parse_from_bytes(data.unpack("C*"))
        case frame.action
        when Frame::DATA
            recv_queue[frame.id].push(frame)
        when Frame::ACTION_CLOSE_CONN
            que = recv_queue[frame.id]
            que.push(frame)
            map_lock.synchronize {
                recv_queue.delete(frame.id)
            }

            que.close
        else
            raise ProtocolException.new('recv unknown frame')
        end

    }
end

# @param [TCPSocket] con
# @param [Queue] send_queue
# @param [Hash] recv_queue
def redir_side_loop(con, map_lock, send_queue, recv_queue, redir_addr, redir_port)
    Thread.start {
        loop {
            begin
                #@type [Frame]
                frame = send_queue.pop()
                if frame.nil?
                    p_exception(__FILE__, __LINE__, "send queue close")
                    break
                end
                socket_write_all(con, frame.to_bytes)
            rescue Exception => e
                p_exception(__FILE__, __LINE__, e.message)
                break
            end

        }
        con.close
        send_queue.close
    }
    loop {
        len = to_uint16(socket_read_at_least(con, 2).unpack("C*"))
        frame = Frame.parse_from_bytes(socket_read_at_least(con, len).unpack("C*"))
        case frame.action
        when Frame::ACTION_NEW_CONN
            que = Queue.new
            id = frame.id
            map_lock.synchronize {
                recv_queue[id] = que
            }

            Thread.start(que, id) {
                |que, id|
                begin
                    redir_sock = TCPSocket.new(redir_addr, redir_port)
                rescue Exception => e
                    p_exception(__FILE__, __LINE__, e.message)

                    begin
                        send_queue.push(Frame.new(Frame::ACTION_CLOSE_CONN, id))
                    rescue ClosedQueueError
                        Thread.exit
                    end
                    Thread.exit
                end


                Thread.start {
                    loop {
                        begin
                            #@type[Frame]
                            frame = que.pop()
                            if frame.nil?
                                p_exception(__FILE__, __LINE__, "que close", id)
                                break
                            end
                            case frame.action
                            when Frame::DATA
                                socket_write_all(redir_sock, frame.get_data)
                            when Frame::ACTION_CLOSE_CONN
                                p_exception(__FILE__, __LINE__, "recv frame with close", id)
                                break
                            else
                                raise ProtocolException.new("recv unknown frame")
                            end
                        rescue ProtocolException => e
                            p_exception(__FILE__, __LINE__, e.message, id)
                            abort("recv an unexpect frame")
                        rescue Exception => e
                            p_exception(__FILE__, __LINE__, e.message, id)
                            break
                        end
                    }
                    redir_sock.close

                }


                loop {
                    begin
                        data = redir_sock.recv($tcp_recv_buf)
                        if data == "" || data.nil?
                            p_exception(__FILE__, __LINE__, "local close", id)
                            raise IOError.new 'local close'
                        end
                        send_queue.push(Frame.new(Frame::DATA, id, data.unpack("C*")))
                    rescue ClosedQueueError
                        p_exception(__FILE__, __LINE__, "send_queue close", id)
                        break
                    rescue Exception => e
                        p_exception(__FILE__, __LINE__, e.message, id)
                        begin
                            send_queue.push(Frame.new(Frame::ACTION_CLOSE_CONN, id))
                        rescue ClosedQueueError
                            #doing nothing
                        ensure
                            break
                        end
                    end
                }
                redir_sock.close


            }
        when Frame::ACTION_CLOSE_CONN
            que = recv_queue[frame.id]
            map_lock.synchronize {
                recv_queue.delete(frame.id)
            }
            que.push(frame)
            que.close()
        when Frame::DATA
            recv_queue[frame.id].push(frame)

        else
            raise ProtocolException.new("recv unknown frame")
        end

    }

end