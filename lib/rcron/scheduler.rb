require 'thread'
require 'logger'
require 'forwardable'

class RCron
  extend Forwardable

  def_delegators :@logger, :info, :warn, :error

  def initialize
    @tasks    = []
    @mutex    = Mutex.new
    @sleeping = false
  end

  # Enqueues a task to be run
  # @param [String] name Name of the task
  # @param [String] schedule Cron-format schedule string
  # @param [Hash] options Additional options for the task. :exclusive and :timeout.
  # @return [RCron::Task]
  def enq name, schedule, options = {}, &block
    raise ArgumentError.new("Block not given") unless block_given?

    new_task = nil
    @mutex.synchronize do
      @tasks << new_task = Task.send(:new,
                      self, name, schedule,
                      options[:exclusive], options[:timeout],
                      &block)
    end
    return new_task
  end
  alias q enq

  # Starts the scheduler
  # @param logger Logger instance. Default is a Logger to standard output.
  def start logger = Logger.new($stdout)
    unless [:info, :warn, :error].all? { |m| logger.respond_to? m }
      raise ArgumentError.new("Invalid Logger")
    end

    @logger = logger
    @thread = Thread.current

    info "rcron started"

    now = Time.now
    while @tasks.length > 0
      # At every minute
      next_tick = Time.at( (now + 60 - now.sec).to_i )
      interval = @tasks.select(&:running?).map(&:timeout).compact.min
      begin
        @mutex.synchronize { @sleeping = true }
        #puts [ next_tick - now, interval ].compact.min
        sleep [ next_tick - now, interval ].compact.min
        @mutex.synchronize { @sleeping = false }
      rescue RCron::Alarm => e
        # puts 'woke up'
      end

      # Join completed threads
      @tasks.select(&:running?).each do |t|
        t.send :join
      end

      # Removed dequeued tasks
      @tasks.reject { |e| e.running? || e.queued? }.each do |t|
        @mutex.synchronize { @tasks.delete t }
      end

      # Start new task threads if it's time
      now = Time.now
      @tasks.select { |e| e.queued? && e.scheduled?(now) }.each do |t|
        if t.running? && t.exclusive?
          warn "[#{t.name}] already running exclusively"
          next
        end

        info "[#{t.name}] started"
        t.send :start, now
      end if now >= next_tick
    end#while
    info "rcron completed"
  end#start

  # Crontab-like tasklist
  # @return [String]
  def tab
    @tasks.map { |t| "#{t.schedule_expression} #{t.name}" }.join($/)
  end

private
  def wake_up
    @mutex.synchronize {
      if @sleeping
        @sleeping = false
        @thread.raise(RCron::Alarm.new)
      end
    }
  end
end#RCron
