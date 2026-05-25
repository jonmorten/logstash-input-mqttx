# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "socket"
require "mqtt"
require "stud/interval"

class LogStash::Inputs::Mqtt < LogStash::Inputs::Base
  config_name "mqtt"

  # If undefined, Logstash will complain, even if codec is unused.
  default :codec, "plain"

  # Connection
  config :host, :validate => :string, :required => true
  config :port, :validate => :number, :default => 1883

  # Authentication
  config :client_id, :validate => :string
  config :username,  :validate => :string
  config :password,  :validate => :string

  # TLS
  config :ssl, :validate => :boolean, :default => false
  config :cert_file, :validate => :path
  config :key_file,  :validate => :path
  config :ca_file,   :validate => :path

  # MQTT usage
  config :topic, :validate => :string, :required => true
  config :qos,   :validate => :number, :default => 0

  # Timeouts and reconnect behavior
  config :keep_alive,      :validate => :number, :default => 15
  config :connect_timeout, :validate => :number, :default => 30
  config :reconnect_delay, :validate => :number, :default => 5

  public

  def register
    @closing       = false
    @logstash_host = Socket.gethostname

    @mqtt_options = {
      host:            @host,
      port:            @port,
      keep_alive:      @keep_alive,
      connect_timeout: @connect_timeout,
    }

    @mqtt_options[:client_id] = @client_id if @client_id
    @mqtt_options[:username]  = @username  if @username
    @mqtt_options[:password]  = @password  if @password

    if @ssl
      @mqtt_options[:ssl] = true
      @mqtt_options[:cert_file] = @cert_file if @cert_file
      @mqtt_options[:key_file]  = @key_file  if @key_file
      @mqtt_options[:ca_file]   = @ca_file   if @ca_file
    end
  end

  def run(queue)
    @logger.info("MQTT input starting: host=#{@host}, port=#{@port}, topic=#{@topic}")

    until stop?
      begin
        @client = MQTT::Client.connect(@mqtt_options)
        @logger.info("MQTT connected to #{@host}")
        @client.subscribe(@topic => @qos)
        @logger.info("MQTT subscribed to #{@topic}, qos #{@qos}")

        until stop?
          if @client.queue_empty?
            Stud.stoppable_sleep(1) { stop? }
            next
          end

          packet = @client.get_packet
          next if packet.nil?

          topic   = packet.topic
          payload = packet.payload

          @codec.decode(payload) do |event|
            event.set("host", event.get("host") || @logstash_host)
            event.set("topic", topic)
            decorate(event)
            queue << event
          end
        end

      rescue MQTT::Exception, MQTT::ProtocolException, IOError, SystemCallError => e
        break if stop?

        @logger.warn(
          "MQTT input error - reconnecting",
          :error => e.message,
          :class => e.class.name
        )

        Stud.stoppable_sleep(@reconnect_delay) { stop? }

      ensure
        if @client
          begin
            @client.disconnect
          rescue StandardError
            # ignore
          ensure
            @client = nil
          end
        end
      end
    end

    @logger.info("MQTT input stopping")
  end

  def stop
    @closing = true
  end


  private

  def stop?
    @closing || super
  end
end
