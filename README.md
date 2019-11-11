# Telemetry Release

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
  - `telemetry-time`: [string] Time formatted in RFC3339

The message may contain additional key(s) which conform to the following:
  - key names may not begin with `telemetry`
  - values must be objects

Additionally, log messages may not contain the substrings `"telemetry-source"` or `\"telemetry-source\"` except as specified above.

Because your ability to log specific kinds of messages may vary depending on your technology choices, the telemetry system recognizes
messages in a variety of formats. Use the format that best suits your existing logging facility.

**Valid log message formats:**

Let's say your source is `my-component` and you want to log a message type `create-instance` with data `{ "cluster-size": 42, "cool-feature-enabled": true }`.

A) Message is exactly the telemetry message
```
{ "telemetry-source": "my-component","telemetry-time": "2009-11-10T23:00:00Z", "create-instance": { "cluster-size": 42, "cool-feature-enabled": true }}
```

B) Message is embedded as a string value in a JSON object log message
```
{ "time": 12341234123412, "level": "info", "message": "{\"create-instance\": { \"cluster-size\": 42, \"cool-feature-enabled\": true}, \"telemetry-source\": \"my-component\", \"telemetry-time\": \"2009-11-10T23:00:00Z\"}"}
```

C) Message is embedded as a JSON object within another JSON object log message
```
{ "time": 12341234123412, "level": "info", "message": "whatever", "data": { "something": "else", "telemetry-thing": { "telemetry-source": "my-component", "telemetry-time": "2009-11-10T23:00:00Z", "create-instance": { "cluster-size": 42, "cool-feature-enabled": true } }, "more": "otherthings"} }
```

D) Message is embedded in a text log message
```
Tue 14-Mar-2019 [Thread-14] com.java.SomeClassThatLogs myhostname {"telemetry-source": "my-component", "telemetry-time": "2009-11-10T23:00:00Z", "create-instance": { "cluster-size": 42, "cool-feature-enabled": true }} maybe some junk here
```

## Recommendations for telemetry messages

#### Use distinct key names
Your data may be processed at a later stage using technologies which have naming constraints (e.g. SQL). In this case keys could potentially be the names of tables or columns, so if they are similar, they could cause unintended collisions. For example:
- they will be transformed (e.g. `key-name` might become `key_name`)
- they will be treated case-insensitively (e.g. `FOO` will be equivalent to `foo`).

These collisions could cause undefined behavior when your telemetry data is processed. Because of this, take care to name your keys distinctly.


## Requirements
- The telemetry-agent must be colocated in the same instance group as your job
- Your job must either be owned by vcap or run with bpm for the agent to be able to scrape your log files

## How to Deploy
See [centralizer](https://github.com/pivotal-cf/telemetry-release/blob/master/manifest/centralizer.yml) and [agent](https://github.com/pivotal-cf/telemetry-release/blob/master/manifest/agent.yml) manifests for how we deploy the agent and centralizer in separate deployments.
