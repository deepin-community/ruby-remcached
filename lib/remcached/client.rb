require 'eventmachine'

module Memcached
  class Connection < EventMachine::Connection
    def self.connect(host, port=11211, &connect_callback)
      df = EventMachine::DefaultDeferrable.new
      df.callback &connect_callback

      EventMachine.connect(host, port, self) do |me|
        me.instance_eval { 
          @host, @port = host, port
          @connect_deferrable = df
        }
      end
    end

    def connected?
      @connected
    end

    def reconnect
      @connect_deferrable = EventMachine::DefaultDeferrable.new
      super @host, @port
      @connect_deferrable
    end

    def post_init
      @recv_buf = ""
      @recv_state = :header
      @connected = false
      @keepalive_timer = nil
    end

    def connection_completed
      @connected = true
      @connect_deferrable.succeed(self)

      @last_receive = Time.now
      @keepalive_timer = EventMachine::PeriodicTimer.new(1, &method(:keepalive))
    end

    RECONNECT_DELAY = 10
    RECONNECT_JITTER = 5
    def unbind
      @keepalive_timer.cancel if @keepalive_timer

      @connected = false
      EventMachine::Timer.new(RECONNECT_DELAY + rand(RECONNECT_JITTER),
                              method(:reconnect))
    end

    RECEIVE_TIMEOUT = 15
    KEEPALIVE_INTERVAL = 5
    def keepalive
      if @last_receive + RECEIVE_TIMEOUT <= Time.now
        p :timeout
        close_connection
      elsif @last_receive + KEEPALIVE_INTERVAL <= Time.now
        send_keepalive
      end
    end

    def send_packet(pkt)
      send_data pkt.to_s
    end

    def receive_data(data)
      @recv_buf += data
      @last_receive = Time.now

      done = false
      while not done

        if @recv_state == :header && @recv_buf.length >= 24
          @received = Response.parse_header(@recv_buf[0..23])
          @recv_buf = @recv_buf[24..-1]
          @recv_state = :body

        elsif @recv_state == :body && @recv_buf.length >= @received[:total_body_length]
          @recv_buf = @received.parse_body(@recv_buf)
          receive_packet(@received)

          @recv_state = :header

        else
          done = true
        end
      end
    end
  end

  class Client < Connection
    def post_init
      super
      @opaque_counter = 0
      @pending = []
    end

    def unbind
      super
      @pending.each do |opaque, callback|
        callback.call :status => Errors::DISCONNECTED
      end
      @pending = []
    end

    def send_request(pkt, &callback)
      @opaque_counter += 1
      @opaque_counter %= 1 << 32
      pkt[:opaque] = @opaque_counter
      send_packet pkt

      if callback
        @pending << [@opaque_counter, callback]
      end
    end

    ##
    # memcached responses possess the same order as their
    # corresponding requests. Therefore quiet requests that have not
    # yielded responses will be dropped silently to free memory from
    # +@pending+
    #
    # When a callback has been fired and returned +:proceed+ without a
    # succeeding packet, we still keep it referenced around for
    # commands such as STAT which has multiple response packets.
    def receive_packet(response)
      pending_pos = nil
      pending_callback = nil
      @pending.each_with_index do |(pending_opaque,pending_cb),i|
        if response[:opaque] == pending_opaque
          pending_pos = i
          pending_callback = pending_cb
          break
        end
      end

      if pending_pos
        @pending = @pending[pending_pos..-1]
        begin
          if pending_callback.call(response) != :proceed
            @pending.shift
          end
        rescue Exception => e
          $stderr.puts "#{e.class}: #{e}\n" + e.backtrace.join("\n")
        end
      end
    end

    def send_keepalive
      send_request Request::NoOp.new
    end

    # Callback will be called multiple times
    def stats(contents={}, &callback)
      send_request Request::Stats.new(contents) do |result|
        callback.call result

        if result[:status] == Errors::NO_ERROR && result[:key] != ''
          :proceed
        end
      end
    end
  end
end
