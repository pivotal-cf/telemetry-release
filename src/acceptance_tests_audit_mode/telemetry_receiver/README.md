# Telemetry Receiver

## Overview
The Telemetry Receiver provides an api for writing integration tests for messages sent by this release

## Endpoints

### /components

Endpoint to configure Telemetry Centralizer to send messages to.
Ex centralizer manifest.yml
```
...
properties:
  telemetry:
    api_key: ((valid-telemetry-receiver-api-key)) (provided by T&I team)
    endpoint: ((telemetry-receiver-url))/components
...
```

### /received_messages

Endpoint returns all messages sent by an api key limited by the MESSAGE_LIMIT configuration of the Telemetry Receiver
Example usage:
```
$ curl <telemetry-receiver-url>/received_messages -h "Authorization: Bearer <valid-api-key>"
> [{"foo":"bar"}, {"bar":"foo"}]
```

### /clear_messages

Endpoint to clear all messages saved for the user (api key)
Example usage:
```
$ curl -X POST <telemetry-receiver-url>/clear_messages -h "Authorization: Bearer <valid-api-key>"
$ curl <telemetry-receiver-url>/received_messages -h "Authorization: Bearer <valid-api-key>"
> []
```
