# encoding: utf-8
require "logstash/inputs/threadable"
require "logstash/namespace"
require "socket"
require "systemd/journal"
require "fileutils" # For touch

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

    public
    def register
        opts = {
            flags: @flags,
            path: @path,
        }
        @hostname = Socket.gethostname
        @journal = Systemd::Journal.new(opts)
        @cursor = nil
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
                raise # TODO How do I fail properly?
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
        if @cursor.to_s.empty?
            @journal.seek(@seekto.to_sym)
            @journal.filter(@filter)
        else
            @journal.seek(@cursor)
            @journal.move_next # Without this, the last event will be read again
        end
        @journal.watch do |entry|
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
    def teardown # FIXME: doesn't really seem to work...
        @logger.debug("journald shutting down.")
        @journal = nil
        Thread.kill(@sincedb_writer)
        # Write current cursor
        file = File.open(@sincedb_path, 'w+')
        file.puts @cursor
        file.close
        @cursor = nil
        finished
    end # def teardown

end # class LogStash::Inputs::Journald

# Monkey patch Systemd::JournalEntry
module Systemd
    class JournalEntry
        def to_h_lower(is_lowercase)
            if is_lowercase
                @entry.each_with_object({}) { |(k, v), h| h[k.downcase] = v.dup.force_encoding('iso-8859-1').encode('utf-8') }
            else
                @entry.each_with_object({}) { |(k, v), h| h[k] = v.dup.force_encoding('iso-8859-1').encode('utf-8') }
            end
        end
    end
end
