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
```
git clone https://github.com/stuart-warren/logstash-input-journald.git
cd logstash-input-journald
gem build logstash-input-journald.gemspec
sudo /path/to/logstash/bin/plugin install /path/to/git/logstash-input-journald/logstash-input-journald-0.0.1.gem
```

Tips
----

Ensure the user you are running logstash as has read access to the journal files ``/var/log/journal/*/*``

Issues
------

Killing the logstash process takes a long time...
