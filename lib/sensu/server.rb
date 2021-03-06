require File.join(File.dirname(__FILE__), 'base')

require 'redis'

require File.join(File.dirname(__FILE__), 'patches', 'redis')

module Sensu
  class Server
    attr_reader :redis, :amq, :is_master

    def self.run(options={})
      server = self.new(options)
      EM::run do
        server.setup_redis
        server.setup_rabbitmq
        server.setup_keepalives
        server.setup_results
        server.setup_master_monitor
        server.setup_rabbitmq_monitor

        %w[INT TERM].each do |signal|
          Signal.trap(signal) do
            server.stop(signal)
          end
        end
      end
    end

    def initialize(options={})
      base = Sensu::Base.new(options)
      @logger = base.logger
      @settings = base.settings
      @timers = Array.new
      @handlers_in_progress = 0
    end

    def setup_redis
      @logger.debug('connecting to redis', {
        :settings => @settings[:redis]
      })
      @redis = Redis.connect(@settings[:redis])
    end

    def setup_rabbitmq
      @logger.debug('connecting to rabbitmq', {
        :settings => @settings[:rabbitmq]
      })
      @rabbitmq = AMQP.connect(@settings[:rabbitmq])
      @amq = AMQP::Channel.new(@rabbitmq)
    end

    def setup_keepalives
      @logger.debug('subscribing to keepalives')
      @keepalive_queue = @amq.queue('keepalives')
      @keepalive_queue.subscribe do |payload|
        client = JSON.parse(payload, :symbolize_names => true)
        @logger.debug('received keepalive', {
          :client => client
        })
        @redis.set('client:' + client[:name], client.to_json).callback do
          @redis.sadd('clients', client[:name])
        end
      end
    end

    def check_handlers(check)
      handler_list = case
      when check.has_key?(:handler)
        [check[:handler]]
      when check.has_key?(:handlers)
        check[:handlers]
      else
        ['default']
      end
      handler_list.reject! do |handler_name|
        !@settings.handler_exists?(handler_name)
      end
      handler_list.map! do |handler_name|
        if @settings[:handlers][handler_name][:type] == 'set'
          @settings[:handlers][handler_name][:handlers]
        else
          handler_name
        end
      end
      handler_list.flatten!
      handler_list.uniq!
      handler_list.reject! do |handler_name|
        !@settings.handler_exists?(handler_name)
      end
      handler_list.map do |handler_name|
        @settings[:handlers][handler_name].merge(:name => handler_name)
      end
    end

    def handle_event(event)
      report = proc do |output|
        if output.is_a?(String)
          output.split(/\n+/).each do |line|
            @logger.info('handler output', {
              :output => line
            })
          end
        end
        @handlers_in_progress -= 1
      end
      handlers = check_handlers(event[:check])
      handlers.each do |handler|
        @logger.debug('handling event', {
          :event => event,
          :handler => handler
        })
        @handlers_in_progress += 1
        case handler[:type]
        when 'pipe'
          execute = proc do
            begin
              IO.popen(handler[:command] + ' 2>&1', 'r+') do |io|
                io.write(event.to_json)
                io.close_write
                io.read
              end
            rescue Errno::ENOENT => error
              @logger.error('handler does not exist', {
                :event => event,
                :handler => handler,
                :error => error.to_s
              })
            rescue Errno::EPIPE => error
              @logger.error('broken pipe', {
                :event => event,
                :handler => handler,
                :error => error.to_s
              })
            rescue => error
              @logger.error('unexpected error', {
                :event => event,
                :handler => handler,
                :error => error.to_s
              })
            end
          end
          EM::defer(execute, report)
        when 'amqp'
          exchange_name = handler[:exchange][:name]
          exchange_type = handler[:exchange].has_key?(:type) ? handler[:exchange][:type].to_sym : :direct
          exchange_options = handler[:exchange].reject do |key, value|
            [:name, :type].include?(key)
          end
          @logger.debug('publishing event to an amqp exchange', {
            :event => event,
            :exchange => handler[:exchange]
          })
          payload = handler[:send_only_check_output] ? event[:check][:output] : event.to_json
          unless payload.empty?
            @amq.method(exchange_type).call(exchange_name, exchange_options).publish(payload)
          end
          @handlers_in_progress -= 1
        when 'set'
          @logger.error('handler sets cannot be nested', {
            :handler => handler
          })
          @handlers_in_progress -= 1
        end
      end
    end

    def process_result(result)
      @logger.debug('processing result', {
        :result => result
      })
      @redis.get('client:' + result[:client]).callback do |client_json|
        unless client_json.nil?
          client = JSON.parse(client_json, :symbolize_names => true)
          check = case
          when @settings.check_exists?(result[:check][:name])
            @settings[:checks][result[:check][:name]].merge(result[:check])
          else
            result[:check]
          end
          event = {
            :client => client,
            :check => check,
            :occurrences => 1
          }
          @redis.sadd('history:' + client[:name], check[:name])
          history_key = 'history:' + client[:name] + ':' + check[:name]
          @redis.rpush(history_key, check[:status]).callback do
            @redis.lrange(history_key, -21, -1).callback do |history|
              event[:check][:history] = history
              total_state_change = 0
              unless history.count < 21
                state_changes = 0
                change_weight = 0.8
                history.each do |status|
                  previous_status ||= status
                  unless status == previous_status
                    state_changes += change_weight
                  end
                  change_weight += 0.02
                  previous_status = status
                end
                total_state_change = (state_changes.fdiv(20) * 100).to_i
                @redis.lpop(history_key)
              end
              @redis.hget('events:' + client[:name], check[:name]).callback do |event_json|
                previous_occurrence = event_json ? JSON.parse(event_json, :symbolize_names => true) : false
                is_flapping = false
                if check.has_key?(:low_flap_threshold) && check.has_key?(:high_flap_threshold)
                  was_flapping = previous_occurrence ? previous_occurrence[:flapping] : false
                  is_flapping = case
                  when total_state_change >= check[:high_flap_threshold]
                    true
                  when was_flapping && total_state_change <= check[:low_flap_threshold]
                    false
                  else
                    was_flapping
                  end
                end
                if check[:status] != 0
                  if previous_occurrence && check[:status] == previous_occurrence[:status]
                    event[:occurrences] = previous_occurrence[:occurrences] += 1
                  end
                  @redis.hset('events:' + client[:name], check[:name], {
                    :output => check[:output],
                    :status => check[:status],
                    :issued => check[:issued],
                    :flapping => is_flapping,
                    :occurrences => event[:occurrences]
                  }.to_json).callback do
                    unless check[:handle] == false
                      event[:check][:flapping] = is_flapping
                      event[:action] = 'create'
                      handle_event(event)
                    else
                      @logger.debug('handling disabled', {
                        :event => event
                      })
                    end
                  end
                elsif previous_occurrence
                  unless is_flapping
                    unless check[:auto_resolve] == false && !check[:force_resolve]
                      @redis.hdel('events:' + client[:name], check[:name]).callback do
                        unless check[:handle] == false
                          event[:action] = 'resolve'
                          handle_event(event)
                        else
                          @logger.debug('handling disabled', {
                            :event => event
                          })
                        end
                      end
                    end
                  else
                    @logger.debug('check is flapping', {
                      :event => event
                    })
                    @redis.hset('events:' + client[:name], check[:name], previous_occurrence.merge(:flapping => true).to_json).callback do
                      if check[:type] == 'metric'
                        event[:check][:flapping] = is_flapping
                        handle_event(event)
                      end
                    end
                  end
                elsif check[:type] == 'metric'
                  handle_event(event)
                end
              end
            end
          end
        end
      end
    end

    def setup_results
      @logger.debug('subscribing to results')
      @result_queue = @amq.queue('results')
      @result_queue.subscribe do |payload|
        result = JSON.parse(payload, :symbolize_names => true)
        @logger.debug('received result', {
          :result => result
        })
        process_result(result)
      end
    end

    def setup_publisher(options={})
      @logger.debug('scheduling check requests')
      check_count = 0
      stagger = options[:test] ? 0 : 7
      @settings.checks.each do |check|
        unless check[:publish] == false || check[:standalone]
          check_count += 1
          @timers << EM::Timer.new(stagger * check_count) do
            interval = options[:test] ? 0.5 : check[:interval]
            @timers << EM::PeriodicTimer.new(interval) do
              unless @rabbitmq.reconnecting?
                payload = {
                  :name => check[:name],
                  :issued => Time.now.to_i
                }
                @logger.info('publishing check request', {
                  :payload => payload,
                  :subscribers => check[:subscribers]
                })
                check[:subscribers].uniq.each do |exchange_name|
                  @amq.fanout(exchange_name).publish(payload.to_json)
                end
              end
            end
          end
        end
      end
    end

    def publish_result(client, check)
      payload = {
        :client => client[:name],
        :check => check
      }
      @logger.info('publishing check result', {
        :payload => payload
      })
      @amq.queue('results').publish(payload.to_json)
    end

    def setup_keepalive_monitor
      @logger.debug('monitoring client keepalives')
      @timers << EM::PeriodicTimer.new(30) do
        unless @rabbitmq.reconnecting?
          @logger.debug('checking for stale client info')
          @redis.smembers('clients').callback do |clients|
            clients.each do |client_name|
              @redis.get('client:' + client_name).callback do |client_json|
                client = JSON.parse(client_json, :symbolize_names => true)
                check = {
                  :name => 'keepalive',
                  :issued => Time.now.to_i
                }
                time_since_last_keepalive = Time.now.to_i - client[:timestamp]
                case
                when time_since_last_keepalive >= 180
                  check[:output] = 'No keep-alive sent from host in over 180 seconds'
                  check[:status] = 2
                  publish_result(client, check)
                when time_since_last_keepalive >= 120
                  check[:output] = 'No keep-alive sent from host in over 120 seconds'
                  check[:status] = 1
                  publish_result(client, check)
                else
                  @redis.hexists('events:' + client[:name], 'keepalive').callback do |exists|
                    if exists
                      check[:output] = 'Keep-alive sent from host'
                      check[:status] = 0
                      publish_result(client, check)
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    def master_duties
      setup_publisher
      setup_keepalive_monitor
    end

    def request_master_election
      @is_master ||= false
      @redis.setnx('lock:master', Time.now.to_i).callback do |created|
        if created
          @is_master = true
          @logger.info('i am the master')
          master_duties
        else
          @redis.get('lock:master') do |timestamp|
            if Time.now.to_i - timestamp.to_i >= 60
              @redis.getset('lock:master', Time.now.to_i).callback do |previous|
                if previous == timestamp
                  @is_master = true
                  @logger.info('i am now the master')
                  master_duties
                end
              end
            end
          end
        end
      end
    end

    def resign_as_master(&block)
      if @is_master
        @redis.del('lock:master').callback do
          @logger.warn('resigned as master')
          if block
            block.call
          end
        end
      else
        @logger.warn('not currently master')
        if block
          block.call
        end
      end
    end

    def setup_master_monitor
      request_master_election
      @timers << EM::PeriodicTimer.new(20) do
        if @is_master
          @redis.set('lock:master', Time.now.to_i).callback do
            @logger.debug('updated master lock timestamp')
          end
        else
          request_master_election
        end
      end
    end

    def setup_rabbitmq_monitor
      @logger.debug('monitoring rabbitmq connection')
      @timers << EM::PeriodicTimer.new(5) do
        if @rabbitmq.reconnecting?
          @logger.warn('reconnecting to rabbitmq')
        else
          unless @keepalive_queue.subscribed?
            @logger.warn('re-subscribing to keepalives')
            setup_keepalives
          end
          unless @result_queue.subscribed?
            @logger.warn('re-subscribing to results')
            setup_results
          end
        end
      end
    end

    def stop_reactor
      @logger.info('completing handlers in progress', {
        :handlers_in_progress => @handlers_in_progress
      })
      complete_in_progress = EM::tick_loop do
        if @handlers_in_progress == 0
          :stop
        end
      end
      complete_in_progress.on_stop do
        @logger.warn('stopping reactor')
        EM::PeriodicTimer.new(0.25) do
          EM::stop_event_loop
        end
      end
    end

    def stop(signal)
      @logger.warn('received signal', {
        :signal => signal
      })
      @logger.warn('stopping')
      @timers.each do |timer|
        timer.cancel
      end
      unless @rabbitmq.reconnecting?
        @logger.warn('unsubscribing from keepalives')
        @keepalive_queue.unsubscribe do
          @logger.warn('unsubscribing from results')
          @result_queue.unsubscribe do
            resign_as_master do
              stop_reactor
            end
          end
        end
      else
        resign_as_master do
          stop_reactor
        end
      end
    end
  end
end
