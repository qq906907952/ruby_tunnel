require 'util'
class Handshake
  INIT=0
  FAIL=1
  SUCCESS = 2
  MODE_LOCAL_REMOTE=1
  MODE_REMOTE_LOCAL=2
  @@min_len=4
  attr_accessor :state_code ,:mode,:port, :extend #1 byte,1 byte,2bytes, var
  def initialize(state,mode,port=0,extend="")
    @state_code=state
    @mode=mode
    @port=port
    @extend=extend
  end


  def self.parse_from_bytes(data)
    if data.length<@@min_len
      raise ProtocolException.new("len too short")
    end
    state_code=data[0]
    mode=data[1]
    port=to_uint16(data.slice(2...4))
    ext=data.slice(4...data.length).pack("C*")
    return Handshake.new(state_code,mode,port,ext)
  end

  def to_bytes()
    data=[@state_code,@mode]+put_uint16(@port)+@extend.unpack("C*")
    return ([data.length>>8,data.length&255]+data).pack("C*")
  end
end


class Frame
  ACTION_NEW_CONN = 1
  ACTION_CLOSE_CONN = 2
  DATA = 3
  @@min_len=3
  attr_accessor :action,:id,:data


  def initialize(action,id,data=nil)
    @action=action
    @id=id
    @data=data||[]

  end


  def self.parse_from_bytes(data)
    if data.length<@@min_len
      raise ProtocolException.new('len toot short')
    end
    action=data[0]
    id=data.slice(1...3)
    data=data.slice(3...data.length)
    return Frame.new(action,to_uint16(id),data)
  end

  def get_data
    @data.pack("C*")
  end

  def to_bytes()
    data=[@action,]+put_uint16(@id)+@data
    return (put_uint16(data.length)+data).pack("C*")
  end
end



class ProtocolException < Exception

end


class HandshakeException < Exception

end

class UnknownError < Exception

end
