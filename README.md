# Telemetry Components Release

## Overview
The Telemetry System uses an agent job to scrape logs from co-located bosh jobs to find possible telemetry messages. The
identified messages are then forwarded to a centralizer job, which attempts to parse each message and extract the telemetry section
from the message. If the centralizer successfully extracts a telemetry object from the message, then it is logged to the centralizer's
stdout log file.

## Jobs
### telemetry-agent:
- Responsible for collecting and emitting telemetry from components/jobs it is collocated with.

### telemetry-centralizer:
- Receives and centralizes data emitted from agent jobs.


## Required Message Format in Logs
Message must contain a JSON object (or one encoded as a string) with these fields:
  - `telemetry-source`: [string] The source name for the telemetry data
  - `data`: [object] Required key, that wraps the message you wish to send
    - `<message-type>`: [object] The telemetry message type with the data you wish to send as a JSON object

The following limitations apply:
 - Your message should not contain any other JSON key or value that is `telemetry-source`

Because your ability to log specific kinds of messages may vary depending on your technology choices, the telemetry system recognizes
messages in a variety of formats. Use the format that best suits your existing logging facility.

**Valid log message formats:**

Let's say your source is `my-component` and you want to log a message type `create-instance` with data `{ "cluster-size": 42, "cool-feature-enabled": true }`.

A) Message is exactly the telemetry message
```
{ "telemetry-source": "my-component", "data": {"create-instance": { "cluster-size": 42, "cool-feature-enabled": true }}}
```

B) Message is embedded as a string value in a JSON object log message
```
{ "time": 12341234123412, "level": "info", "message": "{ \"data\": {\"create-instance\": { \"cluster-size\": 42, \"cool-feature-enabled\": true}}, \"telemetry-source\": \"my-component\"}"}
```

C) Message is embedded as a JSON object within another JSON object log message
```
{ "time": 12341234123412, "level": "info", "message": "whatever", "data": { "something": "else", "telemetry-thing": { "telemetry-source": "my-component", "data": { "create-instance": { "cluster-size": 42, "cool-feature-enabled": true } } }, "more": "otherthings"} }
```

D) Message is embedded in a text log message
```
Tue 14-Mar-2019 [Thread-14] com.java.SomeClassThatLogs myhostname {"telemetry-source": "my-component", "data": {"create-instance": { "cluster-size": 42, "cool-feature-enabled": true }}} maybe some junk here
```

**Expected centralizer stdout logfile output:**
```
2019-04-12 16:05:12.624003617 +0000 tail.0: {"telemetry-source": "my-component", "data": {"create-instance": { "cluster-size": 42, "cool-feature-enabled": true }}}
```

## Requirements
- The telemetry-agent must be colocated in the same instance group as your job
- Your job must either be owned by vcap or run with bpm for the agent to be able to scrape your log files

## How to Deploy
See [example manifest](https://github.com/pivotal-cf/telemetry-components-release/blob/master/ci/manifest/telemetry-components.yml) for how we deploy the agent and centralizer in a standalone scenario.
