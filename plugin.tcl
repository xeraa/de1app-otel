package require http
package require tls
package require json
package require json::write

set plugin_name "otel"

namespace eval ::plugins::${plugin_name} {
    variable author "Philipp Krenn"
    variable contact "pk@xeraa.net"
    variable version 1.0
    variable description "Forward logs to an OTel endpoint using OTLP/HTTP"
    variable name "OpenTelemetry"


    # Paint settings screen
    proc create_ui {} {
        set needs_save_settings 0

        # Create settings if non-existant
        if {[array size ::plugins::otel::settings] == 0} {
            array set  ::plugins::otel::settings {
                otlp_endpoint http://localhost:4318
                otlp_api_key ""
                min_seconds 2
            }
            set needs_save_settings 1
        }
        if { ![info exists ::plugins::otel::settings(last_forward_shot)] } {
            set ::plugins::otel::settings(last_forward_shot) {}
            set ::plugins::otel::settings(last_upload_result) {}
            set needs_save_settings 1
        }
        if { $needs_save_settings == 1 } {
            plugins save_settings otel
        }

        dui page add otel_settings -namespace [namespace current]::otel_settings \
            -bg_img settings_message.png -type fpdialog

        return "otel_settings"
    }


    # Utility function for logging
    proc msg { msg } {
        catch {
            # a bad message migth cause an error here, so catching it
            ::msg [namespace current] {*}$msg
        }
    }

    # Create the header for OTLP/HTTP with optional API keys
    proc build_headers {} {
        variable settings
        set headers [list "Content-Type" "application/json"]

        # Add API key if configured
        if {[info exists settings(otlp_api_key)] && [string trim $settings(otlp_api_key)] ne ""} {
            lappend headers "Authorization" "Bearer $settings(otlp_api_key)"
            msg "Adding API key to request headers"
        }

        return $headers
    }

    # Process the log data of espresso shots
    proc parse_content_data { content } {
        # Parse the content JSON and extract only profile, meta, and app fields
        set contentAttrs [list]
        set profileValue ""

        # Define which fields to include
        set allowedFields [list "profile" "meta" "app"]

        if {[catch {set contentDict [::json::json2dict $content]} err] == 0} {
            # Successfully parsed JSON, only add allowed fields
            dict for {key value} $contentDict {
                if {$key in $allowedFields} {
                    lappend contentAttrs [json::write object \
                        key [json::write string $key] \
                        value [json::write object \
                            stringValue [json::write string $value] \
                        ] \
                    ]
                    # Extract profile value if it exists
                    if {$key eq "profile"} {
                        set profileValue $value
                    }
                }
            }
        } else {
            # Failed to parse JSON, add the raw content as a single attribute
            lappend contentAttrs [json::write object \
                key [json::write string "raw_content"] \
                value [json::write object \
                    stringValue [json::write string $content] \
                ] \
            ]
        }

        return [list $contentAttrs $profileValue]
    }

    proc parse_timeseries_data { content } {
        msg "Starting data point parsing"

        # Parse the content JSON and extract data points
        if {[catch {set contentDict [::json::json2dict $content]} err] != 0} {
            msg "Failed to parse JSON: $err"
            return [list]
        }

        # Define all data point fields we want to capture
        set timeSeriesFields {
            "elapsed"
            "pressure.pressure"
            "pressure.goal"
            "flow.flow"
            "flow.by_weight"
            "flow.by_weight_raw"
            "flow.goal"
            "temperature.basket"
            "temperature.mix"
            "temperature.goal"
            "totals.weight"
            "totals.water_dispensed"
            "resistance.resistance"
            "resistance.by_weight"
            "state_change"
        }

        msg "Looking for [llength $timeSeriesFields] data point fields"

        # Extract all data point arrays
        set fieldData [dict create]
        set maxLength 0
        set foundFields 0

        foreach field $timeSeriesFields {
            # Handle nested fields (e.g., "pressure.pressure" means pressure->pressure)
            if {[string match "*.*" $field]} {
                set parts [split $field "."]
                set parentField [lindex $parts 0]
                set childField [lindex $parts 1]

                if {[dict exists $contentDict $parentField]} {
                    set parentData [dict get $contentDict $parentField]
                    if {[dict exists $parentData $childField]} {
                        set fieldValues [dict get $parentData $childField]
                        dict set fieldData $field $fieldValues
                        set fieldLength [llength $fieldValues]
                        msg "Field '$field' has $fieldLength values"

                        if {$fieldLength > $maxLength} {
                            set maxLength $fieldLength
                        }
                        incr foundFields
                    } else {
                        msg "Child field '$childField' not found in '$parentField'"
                    }
                } else {
                    msg "Parent field '$parentField' not found in content"
                }
            } else {
                # Handle non-nested fields
                if {[dict exists $contentDict $field]} {
                    set fieldValues [dict get $contentDict $field]
                    dict set fieldData $field $fieldValues
                    set fieldLength [llength $fieldValues]
                    msg "Field '$field' has $fieldLength values"

                    if {$fieldLength > $maxLength} {
                        set maxLength $fieldLength
                    }
                    incr foundFields
                } else {
                    msg "Field '$field' not found in content"
                }
            }
        }

        msg "Found $foundFields out of [llength $timeSeriesFields] data point fields"

        # Check if elapsed field exists and compare lengths
        if {[dict exists $fieldData "elapsed"]} {
            set elapsedLength [llength [dict get $fieldData "elapsed"]]

            if {$elapsedLength != $maxLength} {
                msg "WARNING: Elapsed field length ($elapsedLength) does not match maximum field length ($maxLength)"
                msg "Some data points may have misaligned timestamps"
            }

            # Check each field against elapsed length
            dict for {field values} $fieldData {
                if {$field ne "elapsed"} {
                    set fieldLength [llength $values]
                    if {$fieldLength != $elapsedLength} {
                        msg "WARNING: Field '$field' length ($fieldLength) differs from elapsed length ($elapsedLength)"
                    }
                }
            }
        } else {
            msg "WARNING: No 'elapsed' field found - timestamps may be incorrect for data point"
        }

        if {$maxLength == 0} {
            msg "No data point found - all fields empty or missing"
            return [list]
        }

        # Create data points
        set dataPoints [list]

        for {set i 0} {$i < $maxLength} {incr i} {
            set dataPoint [dict create]
            set hasData 0

            # Extract values for each field at this index
            foreach field $timeSeriesFields {
                if {[dict exists $fieldData $field]} {
                    set fieldValues [dict get $fieldData $field]
                    set value [lindex $fieldValues $i]
                    if {$value ne ""} {
                        # Use field name as-is (no longer need to remove "attributes." prefix)
                        dict set dataPoint $field $value
                        set hasData 1
                    }
                }
            }

            # Only add data point if it has at least one value
            if {$hasData} {
                lappend dataPoints $dataPoint
            }
        }

        if {[llength $dataPoints] == 0} {
            msg "No data points created - all values were empty"
        } else {
            msg "Successfully created [llength $dataPoints] data points"
        }
        return $dataPoints
    }

    proc upload_main_document { content } {
        variable settings

        set content [encoding convertto utf-8 $content]
        http::register https 443 [list ::tls::socket -servername $settings(otlp_endpoint)]

        set url "$settings(otlp_endpoint)/v1/logs"
        set headers [build_headers]

        # Parse content to get shot start time
        if {[catch {set contentDict [::json::json2dict $content]} err] == 0} {
            if {[dict exists $contentDict "date"]} {
                set shotStartTime [dict get $contentDict "date"]
                set timeUnixNano [format "%.0f" [expr {[clock scan $shotStartTime] * 1000000000}]]
            } else {
                set timeUnixNano [format "%.0f" [expr {[clock milliseconds] * 1000000}]]
            }
        } else {
            set timeUnixNano [format "%.0f" [expr {[clock milliseconds] * 1000000}]]
        }

        set observedTimeUnixNano [format "%.0f" [expr {[clock milliseconds] * 1000000}]]

        # Parse content data using the dedicated function
        lassign [parse_content_data $content] contentAttrs profileValue

        # Create the OpenTelemetry body using the dedicated function
        set body [create_otel_body $timeUnixNano $observedTimeUnixNano $profileValue $contentAttrs]

        # Send the espresso shot data
        if {[catch {
            set token [http::geturl $url -headers $headers -method POST -query $body -timeout 8000]
            set status [http::status $token]
            set returncode [http::ncode $token]
            http::cleanup $token

            if {$returncode == 200} {
                msg "Espresso shot sent successfully"
                return 1
            } else {
                msg "Failed to send espresso shot: HTTP $returncode"
                return 0
            }
        } err]} {
            msg "Error sending espresso shot: $err"
            return 0
        }
    }

    proc create_timeseries_otel_body { timeUnixNano observedTimeUnixNano dataPoint } {
        # Create OpenTelemetry body for a single data point following OTel semantic conventions
        # Build message string dynamically from all available fields
        set messageParts [list]

        # Add absolute timestamp as first part in human-readable format with timezone
        set absoluteTimestampSeconds [format "%.0f" [expr {$timeUnixNano / 1000000000}]]
        set humanReadableTimestamp [clock format $absoluteTimestampSeconds -format "%Y-%m-%d %H:%M:%S %Z"]
        lappend messageParts "\[$humanReadableTimestamp\]"

        # Add elapsed time with prefix if available
        if {[dict exists $dataPoint "elapsed"]} {
            lappend messageParts "elapsed:[dict get $dataPoint "elapsed"]"
        }

        # Add all other fields in field:value format
        dict for {field value} $dataPoint {
            if {$field ne "elapsed"} {
                lappend messageParts "$field:$value"
            }
        }

        # Join all parts with commas
        set message [join $messageParts ", "]

        return [json::write object \
            resourceLogs [json::write array \
                [json::write object \
                    resource [json::write object \
                        attributes [json::write array \
                            [json::write object \
                                key [json::write string "service.name"] \
                                value [json::write object \
                                    stringValue [json::write string "decent-espresso"] \
                                ] \
                            ] \
                        ] \
                    ] \
                    scopeLogs [json::write array \
                        [json::write object \
                            scope [json::write object \
                                name [json::write string "otel-logger"] \
                            ] \
                            logRecords [json::write array \
                                [json::write object \
                                    timeUnixNano [json::write string $timeUnixNano] \
                                    observedTimeUnixNano [json::write string $observedTimeUnixNano] \
                                    severityText [json::write string "INFO"] \
                                    body [json::write object \
                                        stringValue [json::write string $message] \
                                    ] \
                                    attributes [json::write array \
                                        [json::write object \
                                            key [json::write string "log.type"] \
                                            value [json::write object \
                                                stringValue [json::write string "espresso_data-point"] \
                                            ] \
                                        ] \
                                    ] \
                                ] \
                            ] \
                        ] \
                    ] \
                ] \
            ] \
        ]
    }

    proc send_timeseries_data { content } {
        variable settings

        # First, send the espresso shot
        set mainResult [upload_main_document $content]
        msg "Espresso shot forward result: $mainResult"

        # Parse data points
        set dataPoints [parse_timeseries_data $content]

        if {[llength $dataPoints] == 0} {
            msg "No data points found, only espresso shot sent"
            return $mainResult
        }

        msg "Found [llength $dataPoints] data points to send"

        # Set up HTTP connection for data points
        set content [encoding convertto utf-8 $content]
        http::register https 443 [list ::tls::socket -servername $settings(otlp_endpoint)]

        set url "$settings(otlp_endpoint)/v1/logs"
        set headers [build_headers]

        # Send each data point
        set successCount 0
        set totalCount [llength $dataPoints]

        # Get shot start time from content
        set shotStartTime [clock milliseconds]
        if {[catch {set contentDict [::json::json2dict $content]} err] == 0} {
            if {[dict exists $contentDict "date"]} {
                set shotStartTime [expr {[clock scan [dict get $contentDict "date"]] * 1000}]
            }
        }

        foreach dataPoint $dataPoints {

            # Calculate timeUnixNano using shot start time + elapsed offset
            if {[dict exists $dataPoint "elapsed"]} {
                set elapsedSeconds [dict get $dataPoint "elapsed"]
                set dataPointTimeMs [expr {$shotStartTime + ($elapsedSeconds * 1000)}]
                set timeUnixNano [format "%.0f" [expr {$dataPointTimeMs * 1000000}]]
            } else {
                set timeUnixNano [format "%.0f" [expr {[clock milliseconds] * 1000000}]]
                msg "No elapsed time found, using current time: $timeUnixNano"
            }

            # Use current time for observedTimeUnixNano
            set observedTimeUnixNano [format "%.0f" [expr {[clock milliseconds] * 1000000}]]

            set body [create_timeseries_otel_body $timeUnixNano $observedTimeUnixNano $dataPoint]
            msg "Body preview: [string range $body 0 200]..."

            # Send HTTP request
            if {[catch {
                set token [http::geturl $url -headers $headers -method POST -query $body -timeout 5000]
                set status [http::status $token]
                set returncode [http::ncode $token]
                set response [http::data $token]
                http::cleanup $token

                if {$returncode == 200} {
                    incr successCount
                } else {
                    msg "Failed to send data point: HTTP $returncode"
                    msg "Response: $response"
                }
            } err]} {
                msg "Error sending data point: $err"
            }

            # Small delay to avoid overwhelming the endpoint
            after 10
        }

        msg "Sent espresso shot + $successCount/$totalCount data points successfully"

        if {$successCount > 0} {
            popup [translate_toast "Forwarded espresso shot + $successCount data points"]
            set settings(last_upload_result) "Forwarded espresso shot + $successCount/$totalCount data points"
        } else {
            popup [translate_toast "Forwarded espresso shot only"]
            set settings(last_upload_result) "Forwarded espresso shot only"
        }

        plugins save_settings otel
        return [expr {$mainResult + $successCount}]
    }

    proc create_otel_body { timeUnixNano observedTimeUnixNano profileValue contentAttrs } {
        # Create the OpenTelemetry log body structure following OTel semantic conventions
        return [json::write object \
            resourceLogs [json::write array \
                [json::write object \
                    resource [json::write object \
                        attributes [json::write array \
                            [json::write object \
                                key [json::write string "service.name"] \
                                value [json::write object \
                                    stringValue [json::write string "decent-espresso"] \
                                ] \
                            ] \
                        ] \
                    ] \
                    scopeLogs [json::write array \
                        [json::write object \
                            scope [json::write object \
                                name [json::write string "otel-logger"] \
                            ] \
                            logRecords [json::write array \
                                [json::write object \
                                    timeUnixNano [json::write string $timeUnixNano] \
                                    observedTimeUnixNano [json::write string $observedTimeUnixNano] \
                                    severityText [json::write string "INFO"] \
                                    body [json::write object \
                                        stringValue [json::write string $profileValue] \
                                    ] \
                                    attributes [json::write array \
                                        [json::write object \
                                            key [json::write string "log.type"] \
                                            value [json::write object \
                                                stringValue [json::write string "espresso_shot"] \
                                            ] \
                                        ] \
                                        {*}$contentAttrs \
                                    ] \
                                ] \
                            ] \
                        ] \
                    ] \
                ] \
            ] \
        ]
    }


    # Kick off the data forward process
    proc upload {content} {
        variable settings

        msg "forwarding log"

        set settings(last_action) "upload"

        # Safely get espresso_clock with fallback
        if {[info exists ::settings(espresso_clock)]} {
            set settings(last_forward_shot) $::settings(espresso_clock)
        } else {
            set settings(last_forward_shot) [clock seconds]
            msg "No espresso_clock found, using current time"
        }

        set settings(last_upload_result) ""
        set timeNano [expr {[clock milliseconds] * 1000000}]

        # Check if content contains data points
        set hasElapsed [string match "*elapsed*" $content]
        set hasPressure [string match "*pressure*" $content]
        set hasFlow [string match "*flow*" $content]
        set hasTemperature [string match "*temperature*" $content]
        set hasTotals [string match "*totals*" $content]
        set hasResistance [string match "*resistance*" $content]
        set hasStateChange [string match "*state_change*" $content]

        msg "Data points detection: elapsed=$hasElapsed pressure=$hasPressure flow=$hasFlow temperature=$hasTemperature totals=$hasTotals resistance=$hasResistance state_change=$hasStateChange"

        if {$hasElapsed && ($hasPressure || $hasFlow || $hasTemperature || $hasTotals || $hasResistance || $hasStateChange)} {
            msg "Detected data points, using specialized handler"
            return [send_timeseries_data $content]
        } else {
            msg "No data points detected, using espresso shot metadata only"
        }

        # Fall back to regular single-document upload
        set content [encoding convertto utf-8 $content]

        http::register https 443 [list ::tls::socket -servername $settings(otlp_endpoint)]

        set url "$settings(otlp_endpoint)/v1/logs"
        set headers [build_headers]

        # Parse content to get shot start time
        if {[catch {set contentDict [::json::json2dict $content]} err] == 0} {
            if {[dict exists $contentDict "date"]} {
                set shotStartTime [dict get $contentDict "date"]
                set timeUnixNano [format "%.0f" [expr {[clock scan $shotStartTime] * 1000000000}]]
            } else {
                set timeUnixNano [format "%.0f" [expr {[clock milliseconds] * 1000000}]]
            }
        } else {
            set timeUnixNano [format "%.0f" [expr {[clock milliseconds] * 1000000}]]
        }

        set observedTimeUnixNano [format "%.0f" [expr {[clock milliseconds] * 1000000}]]

        # Parse content data using the dedicated function
        lassign [parse_content_data $content] contentAttrs profileValue

        # Create the OpenTelemetry body using the dedicated function
        set body [create_otel_body $timeUnixNano $observedTimeUnixNano $profileValue $contentAttrs]


        set returncode 0
        set returnfullcode ""
        set answer ""

        # Initialize retry counter
        set retryCount 0
        set maxAttempts 3
        set success 0

        set attempts 0
        while {$retryCount < $maxAttempts && !$success} {
            if {[catch {
                # Execute the HTTP POST request
                if {$attempts == 0} {
                    incr attempts
                    popup [translate_toast "Forwarding to OTLP"]
                } else {
                    popup [subst {[translate_toast "Forwarding to OTLP, attempt"] #[incr attempts]}]
                }

                # exponentially increasing timeout
                set timeout [expr {$attempts * 900}]

                set token [http::geturl $url -headers $headers -method POST -query $body -timeout $timeout]
                msg $token

                set status [http::status $token]
                set answer [http::data $token]
                set returncode [http::ncode $token]
                set returnfullcode [http::code $token]
                msg "status: $status"
                msg "answer $answer"

                http::cleanup $token

                # Check if response code indicates success
                if {$returncode == 200} {
                    set success 1
                } else {
                    # Increment retry counter if response code is not 200
                    incr retryCount
                    after 1000
                }
            } err] != 0} {
                # Increment retry counter in case of error
                incr retryCount

                # Log error message
                msg "error during forward attempt $retryCount: $err"
                set returnfullcode $err

                # Clean up HTTP token if necessary
                catch { http::cleanup $token }

                if {$retryCount < $maxAttempts} {
                    after 1000
                }
            }
        }

        if {$returncode == 401} {
            msg "forward failed: unauthorized"
            popup [translate_toast "Forward authentication failed. Please check credentials"]
            set settings(last_upload_result) [translate "Authentication failed. Please check credentials"]
            plugins save_settings otel
            return
        }
        if {[string length $answer] == 0 || $returncode != 200} {
            msg "forward failed: $returnfullcode"
            popup [translate_toast "Forward failed"]
            set settings(last_upload_result) "[translate {Forward failed}] $returnfullcode"
            plugins save_settings otel
            return
        }

        if {[catch {
            set response [::json::json2dict $answer]
        } err] != 0} {
            msg "forward successful but unexpected server answer"
            set settings(last_upload_result) [translate "Forward successful but unexpected server answer"]
            plugins save_settings otel
            return
        }

        popup [translate_toast "Forward successful"]
        msg "forward successful"
        set settings(last_upload_result) "[translate {Forward successful}]"
        save_plugin_settings otel

        plugins save_settings otel
    }


    proc uploadShotData {} {
        variable settings
        set settings(last_action) "upload"

        # Safely get espresso_clock with fallback
        if {[info exists ::settings(espresso_clock)]} {
            set settings(last_forward_shot) $::settings(espresso_clock)
        } else {
            set settings(last_forward_shot) [clock seconds]
            msg "No espresso_clock found, using current time"
        }

        set settings(last_upload_result) ""

        set min_seconds [ifexists settings(min_seconds) 2]
        if {[espresso_elapsed length] < $min_seconds && [espresso_pressure length] < $min_seconds } {
            set settings(last_upload_result) [translate "Not forwarded: shot was too short"]
            save_plugin_settings otel
            return
        }
        msg "espresso_elapsed = [espresso_elapsed range end end]s"
        if {[espresso_elapsed range end end] < $min_seconds } {
            set settings(last_upload_result) [translate "Not forwarded: shot duration was less than $min_seconds seconds"]
            save_plugin_settings otel
            return
        }

        set espresso_data [::shot::create]
        ::plugins::otel::upload $espresso_data
    }


    # Kick off the background data forwarding
    proc async_dispatch {old new} {
        after 100 ::plugins::otel::uploadShotData
    }


    # Entry point into the application
    proc main {} {
        plugins gui otel [create_ui]
        ::de1::event::listener::after_flow_complete_add \
            [lambda {event_dict} {
            ::plugins::otel::async_dispatch \
                [dict get $event_dict previous_state] \
                [dict get $event_dict this_state] \
            } ]
    }

}



# The settings page
namespace eval ::plugins::${plugin_name}::otel_settings {
    variable widgets
    array set widgets {}

    variable data
    array set data {}

    proc setup { } {
        variable widgets
        set page_name [namespace tail [namespace current]]

        # "Done" button
        dui add dbutton $page_name 980 1210 1580 1410 -tags page_done -label [translate "Done"] -label_pos {0.5 0.5} -label_font Helv_10_bold -label_fill "#fAfBff"

        # Headline
        dui add dtext $page_name 1280 300 -text [translate "OpenTelemetry Forwarder"] -font Helv_20_bold -width 1200 -fill "#444444" -anchor "center" -justify "center"

        # Endpoint
        dui add entry $page_name 280 720 -tags endpoint -width 38 -font Helv_8  -borderwidth 1 -bg #fbfaff -foreground #4e85f4 -textvariable ::plugins::otel::settings(otlp_endpoint) -relief flat  -highlightthickness 1 -highlightcolor #000000 \
            -label [translate "Endpoint"] -label_pos {280 660} -label_font Helv_8 -label_width 1000 -label_fill "#444444"
        bind $widgets(endpoint) <Return> [namespace current]::save_settings

        # API Key
        dui add entry $page_name 280 860 -tags api_key -width 38 -font Helv_8  -borderwidth 1 -bg #fbfaff -foreground #4e85f4 -textvariable ::plugins::otel::settings(otlp_api_key) -relief flat  -highlightthickness 1 -highlightcolor #000000 \
            -label [translate "API Key (optional)"] -label_pos {280 800} -label_font Helv_8 -label_width 1000 -label_fill "#444444"
        bind $widgets(api_key) <Return> [namespace current]::save_settings

        # Minimum seconds to forward
        dui add entry $page_name 280 980 -tags min_seconds -textvariable ::plugins::otel::settings(min_seconds) -width 3 -font Helv_8  -borderwidth 1 -bg #fbfaff  -foreground #4e85f4 -relief flat -highlightthickness 1 -highlightcolor #000000 \
            -label [translate "Minimum shot seconds to upload"] -label_pos {280 920} -label_font Helv_8 -label_width 1100 -label_fill "#444444"
        bind $widgets(min_seconds) <Return> [namespace current]::save_settings

        # Last upload shot
        dui add dtext $page_name 1350 480 -tags last_action_label -text [translate "Last upload:"] -font Helv_8 -width 900 -fill "#444444"
        dui add dtext $page_name 1350 540 -tags last_action -font Helv_8 -width 900 -fill "#6c757d" -anchor "nw" -justify "left"

        # Last upload result
        dui add dtext $page_name 1350 600 -tags last_action_result -font Helv_8 -width 900 -fill "#6c757d" -anchor "nw" -justify "left"
    }


    # This is run immediately after the settings page is shown, wherever it is invoked from
    proc show { page_to_hide page_to_show } {
        dui item config $page_to_show last_action_label -text [translate "Last forward:"]
        dui item config $page_to_show last_action -text [::plugins::otel::otel_settings::format_shot_start]

        # Safely display last_upload_result
        if {[info exists ::plugins::otel::settings(last_upload_result)]} {
            dui item config $page_to_show last_action_result -text $::plugins::otel::settings(last_upload_result)
        } else {
            dui item config $page_to_show last_action_result -text ""
        }
    }


    proc format_shot_start {} {
        set dt $::plugins::otel::settings(last_forward_shot)
        if { $dt eq {} } {
            return [translate "Last shot not found"]
        }
        if { [clock format [clock seconds] -format "%Y%m%d"] eq [clock format $dt -format "%Y%m%d"] } {
            return "[translate {Shot started today at}] [time_format $dt]"
        } else {
            return "[translate {Shot started on}] [clock format $dt -format {%B %d %Y, %H:%M}]"
        }
    }

    proc save_settings {} {
        dui say [translate {Saved}] sound_button_in
        save_plugin_settings otel
    }

    proc page_done {} {
        dui say [translate {Done}] sound_button_in
        save_plugin_settings otel
        dui page close_dialog
    }
}
