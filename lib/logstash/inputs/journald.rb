# encoding: utf-8
require "logstash/inputs/threadable"
require "logstash/namespace"
require "socket"
require "systemd/journal"
require "fileutils" # For touch
require "base64"

# Pull events from a local systemd journal.
#
# See requirements https://github.com/ledbettj/systemd-journal
class LogStash::Inputs::Journald < LogStash::Inputs::Threadable

    config_name "journald"

    # Where in the journal to start capturing logs
    # Options: head, tail
    config :seekto, :validate => [ "head", "tail" ], :default => "tail"

    # System journal flags
    # 0 = all avalable
    # 1 = local only
    # 2 = runtime only
    # 4 = system only
    #
    config :flags, :validate => [0, 1, 2, 4], :default => 0

    # Path to read journal files from
    #
    config :path, :validate => :string, :default => "/var/log/journal"

    # Filter on events. Not heavily tested.
    #
    config :filter, :validate => :hash, :required => false, :default => {}

    # Filter logs since the system booted (only relevant with seekto => "head")
    #
    config :thisboot, :validate => :boolean, :default => true

    # Lowercase annoying UPPERCASE fieldnames. (May clobber existing fields)
    #
    config :lowercase, :validate => :boolean, :default => false

    # Where to write the sincedb database (keeps track of the current
    # position of the journal). The default will write
    # the sincedb file to matching `$HOME/.sincedb_journal`
    #
    config :sincedb_path, :validate => :string

    # How often (in seconds) to write a since database with the current position of
    # the journal.
    #
    config :sincedb_write_interval, :validate => :number, :default => 15

    # The max timeout in microsends to wait for new events from the journal.
    # Set to -1 to wait indefinitely. Setting this to a large value will
    # result in delayed shutdown of the plugin.
    config :wait_timeout, :validate => :number, :default => 3000000

    public
    def register
        opts = {
            flags: @flags,
            path: @path,
        }
        @hostname = Socket.gethostname
        @journal = Systemd::Journal.new(opts)
        @cursor = ""
        @written_cursor = ""
        @cursor_lock = Mutex.new
        if @thisboot
            @filter[:_boot_id] = Systemd::Id128.boot_id
        end
        if @sincedb_path.nil?
            if ENV["SINCEDB_DIR"].nil? && ENV["HOME"].nil?
                @logger.error("No SINCEDB_DIR or HOME environment variable set, I don't know where " \
                              "to keep track of the files I'm watching. Either set " \
                              "HOME or SINCEDB_DIR in your environment, or set sincedb_path in " \
                              "in your Logstash config for the file input with " \
                              "path '#{@path.inspect}'")
                raise(LogStash::ConfigurationError, "Sincedb can not be created.")
            end
            sincedb_dir = ENV["SINCEDB_DIR"] || ENV["HOME"]
            @sincedb_path = File.join(sincedb_dir, ".sincedb_journal")
            @logger.info("No sincedb_path set, generating one for the journal",
                         :sincedb_path => @sincedb_path)
        end
        # (Create and) read sincedb
        FileUtils.touch(@sincedb_path)
        @cursor = IO.read(@sincedb_path)
        # Write sincedb in thread
        @sincedb_writer = Thread.new do
            loop do
                sleep @sincedb_write_interval
                if @cursor != @written_cursor
                    file = File.open(@sincedb_path, 'w+')
                    file.puts @cursor
                    file.close
                    @cursor_lock.synchronize {
                        @written_cursor = @cursor
                    }
                 end
            end
        end
    end # def register

    def run(queue)
        if @cursor.strip.length == 0
            @journal.seek(@seekto.to_sym)

            # We must make one movement in order for the journal C api or else
            # the @journal.watch call will start from the beginning of the
            # journal. see:
            # https://github.com/ledbettj/systemd-journal/issues/55
            if @seekto == 'tail'
              @journal.move_previous
            end

            @journal.filter(@filter)
        else
            @journal.seek(@cursor)
            @journal.move_next # Without this, the last event will be read again
        end

        watch_journal do |entry|
            timestamp = entry.realtime_timestamp
            event = LogStash::Event.new(
                entry.to_h_lower(@lowercase).merge(
                    "@timestamp" => timestamp,
                    "host" => entry._hostname || @hostname,
                    "cursor" => @journal.cursor
                )
            )
            decorate(event)
            queue << event
            @cursor_lock.synchronize {
                @cursor = @journal.cursor
            }
        end
    end # def run

    public
    def close # FIXME: doesn't really seem to work...
        @logger.debug("journald shutting down.")
        @journal = nil
        Thread.kill(@sincedb_writer)
        # Write current cursor
        file = File.open(@sincedb_path, 'w+')
        file.puts @cursor
        file.close
        @cursor = nil
    end # def close

    private
    def watch_journal
        until stop?
            if @journal.wait(@wait_timeout)
                while !stop? && @journal.move_next
                    begin
                        yield @journal.current_entry
                    rescue => error
                        @logger.error("Unable to read journald message skipping: #{error.message}")
                    end
                end
            end
        end
    end # def watch_journal
end # class LogStash::Inputs::Journald

# Monkey patch Systemd::JournalEntry
module Systemd
    class JournalEntry
        def to_h_lower(is_lowercase)
            if is_lowercase
                @entry.each_with_object({}) { |(k, v), h| h[k.downcase] = decode_value(v.dup) }
            else
                @entry.each_with_object({}) { |(k, v), h| h[k] = decode_value(v.dup) }
            end
        end
		
        # Field values are returned as binary (ASCII-8BIT) by the journal API.
        # The officially recommended encoding is UTF-8, so trying that.
        # If the result is not valid, using base64 representation instead.
        # (see https://www.freedesktop.org/software/systemd/man/sd_journal_print.html#Description)
        private
        def decode_value(value)
            value_utf8 = value.force_encoding('utf-8')
            if value_utf8.valid_encoding?
                value_utf8
            else
                Base64.encode64(value)
            end
        end
    end
end
