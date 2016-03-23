logstash-input-journald
=======================

POC systemd journal Logstash input

Example config
--------------
```
input {
     journald {
       lowercase => true
       seekto => "head"
       thisboot => true
       type => "systemd"
       tags => [ "coreos" ]
     }
}

output {
  stdout {codec => rubydebug}
}
```

Install with
------------

From source
```
git clone https://github.com/logstash-plugins/logstash-input-journald.git
cd logstash-input-journald
gem build logstash-input-journald.gemspec
sudo /path/to/logstash/bin/plugin install /path/to/git/logstash-input-journald/logstash-input-journald-*.gem
```

From rubygems
```
sudo /path/to/logstash/bin/plugin install logstash-input-journald
```

Sincedb
----

This plugin creates a sincedb in your home, called .sincedb\_journal.
It automatically stores the cursor to the journal there, so when you restart logstash, only new messages are read.
When executing the plugin the second time (which means the sincedb exists), ``seekto``, and ``thisboot`` are ignored.
If you don't want the sincedb, configure it's path to /dev/null.
Tips
----

Ensure the user you are running logstash as has read access to the journal files ``/var/log/journal/*/*``

Issues
------

Killing the logstash process takes a long time...
