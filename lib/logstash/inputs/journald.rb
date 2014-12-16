# encoding: utf-8
require "logstash/inputs/threadable"
require "logstash/namespace"
require "socket"
require "systemd/journal"

# Pull events from a local systemd journal.
#
# See requirements https://github.com/ledbettj/systemd-journal
class LogStash::Inputs::Journald < LogStash::Inputs::Threadable

    config_name "journald"
    milestone 1

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

    public
    def register
        opts = {
            flags: @flags,
            path: @path,
        }
        @hostname = Socket.gethostname
        @journal = Systemd::Journal.new(opts)
        if @thisboot
            @filter[:_boot_id] = Systemd::Id128.boot_id
        end
    end

    def run(queue)
        @journal.seek(@seekto.to_sym)
        @journal.filter(@filter)
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
        end
    end # def run

    public
    def teardown # FIXME: doesn't really seem to work...
        @logger.debug("journald shutting down.")
        @journal = nil
        finished
    end # def teardown

end # class LogStash::Inputs::Journald

# Monkey patch Systemd::JournalEntry
module Systemd
    class JournalEntry
        def to_h_lower(is_lowercase)
            if is_lowercase
                @entry.each_with_object({}) { |(k, v), h| h[k.downcase] = v.dup }
            else
                @entry.each_with_object({}) { |(k, v), h| h[k] = v.dup }
            end
        end
    end
end
