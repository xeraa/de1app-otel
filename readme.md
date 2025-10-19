# OpenTelemetry Plugin for Decent Espresso

Plugin for the [Decent Espresso app](https://github.com/decentespresso/de1app). The code is largely inspired by the [Visualizer Upload plugin](https://github.com/decentespresso/de1app/blob/main/de1plus/plugins/visualizer_upload/plugin.tcl).


## Installation

Copy the `plugin.tcl` file to your tablet folder `de1plus/plugins/otel`.


## Configuration

* OTLP endpoint: Where an OpenTelemetry Collector or managed endpoint is receiving the data.
* Auto upload: Automatically upload all the log data.
* Auto upload minimum seconds: Set to 0 to receive everything or a higher threshold to skip quick rinses or quickly cancelled operations.


## Development

* [Environment setup](https://github.com/decentespresso/de1app/blob/main/documentation/de1_app_plugin_development_overview.md#set-up-your-development-environment)
* Symlinked the plugin file into a clone of the de1app repository: `ln -s ~/Documents/GitHub/de1app-otel/plugin.tcl
~/Documents/GitHub/de1app/de1plus/plugins/otel/`
* Start a local OTel Collector: `curl -fsSL https://elastic.co/start-local | sh -s -- --edot`
* Send the following request and find the result in Kibana to make sure it's working end to end:

```sh
curl -XPOST http://localhost:4318/v1/logs -H "Content-Type: application/json" -d '{
    "resourceLogs": [{
        "resource": {
            "attributes": [{
                "key": "service.name",
                "value": { "stringValue": "my-service" }
            }]
        },
        "scopeLogs": [{
            "scope": {
                "name": "my-logger"
            },
            "logRecords": [{
                "timeUnixNano": "'$(date +%s%N)'",
                "observedTimeUnixNano": "'$(date +%s%N)'",
                "severityText": "INFO",
                "severityNumber": 9,
                "body": {
                    "stringValue": "Hello, OpenTelemetry!"
                }
            }]
        }]
    }]
}'
```

* Follow the log files in `~/Documents/GitHub/de1app/de1plus/` with `tail -f log.txt | grep -i -E "(ERROR|WARNING|otel)"`. You might have to explicitly flush them with the start / stop button in the app.
