def check_port(port)
    pp = Integer(port)
    if pp > 65535 || pp < 1
        raise "port number illegal"
    end
    return pp
end

# @param [String] data
# @param [TCPSocket] con
def socket_write_all(con, data)
    begin
        n = data.length
        loop {
            i = con.write(data)
            break if i == n
            data = data.slice(i...n)
            n -= i
        }
    rescue
        raise IOError.new("remote close")
    end
end

#@param conn [TCPSocket]
def socket_read_at_least(conn, len)
    begin
        data = conn.read(len)
        if data.nil? || data.length != len
            raise IOError.new "remote close"
        end
        return data
    rescue
        raise IOError.new "remote close"
    end


end

def put_uint16(int16)
    return [int16 >> 8, int16 & 0xff]
end

def to_uint16(bytes)
    return (bytes[0] << 8) + bytes[1]
end

def p_exception(file, line, msg, id=nil)
    if $DEBUG
        unless id.nil?
            p "#{file}:#{line}, id:#{id}, #{msg}"
        else
            p "#{file}:#{line}, #{msg}"
        end

    end

end