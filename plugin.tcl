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


    # Kick off the data forward process
    proc upload {content} {
        variable settings

        msg "forwarding log"

        set settings(last_action) "upload"
        set settings(last_forward_shot) $::settings(espresso_clock)
        set settings(last_upload_result) ""
        set timeNano [expr {[clock milliseconds] * 1000000}]

        set content [encoding convertto utf-8 $content]

        http::register https 443 [list ::tls::socket -servername $settings(otlp_endpoint)]

        set url "$settings(otlp_endpoint)/v1/logs"
        set headers [list "Content-Type" "application/json"]

        # Parse the content JSON and extract key-value pairs
        set contentAttrs [list]
        set profileValue ""
        if {[catch {set contentDict [::json::json2dict $content]} err] == 0} {
            # Successfully parsed JSON, add each key-value pair as an attribute
            dict for {key value} $contentDict {
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
        } else {
            # Failed to parse JSON, add the raw content as a single attribute
            lappend contentAttrs [json::write object \
                key [json::write string "raw_content"] \
                value [json::write object \
                    stringValue [json::write string $content] \
                ] \
            ]
        }

        set body [json::write object \
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
                                    timeUnixNano [json::write string $timeNano] \
                                    observedTimeUnixNano [json::write string $timeNano] \
                                    severityText [json::write string "INFO"] \
                                    body [json::write object \
                                        stringValue [json::write string $profileValue] \
                                    ] \
                                    attributes [json::write array {*}$contentAttrs] \
                                ] \
                            ] \
                        ] \
                    ] \
                ] \
            ] \
        ]


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
                msg "Error during forward attempt $retryCount: $err"
                set returnfullcode $err

                # Clean up HTTP token if necessary
                catch { http::cleanup $token }

                if {$retryCount < $maxAttempts} {
                    #after [expr {5000 * $retryCount}]
                    after 1000
                }
            }
        }

        if {$returncode == 401} {
            msg "Forward failed. Unauthorized"
            popup [translate_toast "Forward authentication failed. Please check credentials"]
            set settings(last_upload_result) [translate "Authentication failed. Please check credentials"]
            plugins save_settings otel
            return
        }
        if {[string length $answer] == 0 || $returncode != 200} {
            msg "Forward failed: $returnfullcode"
            popup [translate_toast "Forward failed"]
            set settings(last_upload_result) "[translate {Forward failed}] $returnfullcode"
            plugins save_settings otel
            return
        }

        popup [translate_toast "Forward successful"]
        if {[catch {
            set response [::json::json2dict $answer]
        } err] != 0} {
            msg "Forward successful but unexpected server answer!"
            set settings(last_upload_result) [translate "Forward successful but unexpected server answer"]
            plugins save_settings otel
            return
        }

        msg "Forward successful"
        set settings(last_upload_result) "[translate {Forward successful}]"
        save_plugin_settings otel

        plugins save_settings otel
    }


    proc uploadShotData {} {
        variable settings
        set settings(last_action) "upload"
        set settings(last_forward_shot) $::settings(espresso_clock)
        set settings(last_upload_result) ""

        set min_seconds [ifexists settings(min_seconds) 2]
        if {[espresso_elapsed length] < $min_seconds && [espresso_pressure length] < $min_seconds } {
            set settings(last_upload_result) [translate "Not forwarded: shot was too short"]
            save_plugin_settings otel
            return
        }
        msg "espresso_elapsed range end end = [espresso_elapsed range end end]"
        if {[espresso_elapsed range end end] < $min_seconds } {
            set settings(last_upload_result) [translate "Not forwarded: shot duration was less than $min_seconds seconds"]
            save_plugin_settings otel
            return
        }
        set bev_type [ifexists ::settings(beverage_type) "espresso"]
        if {$bev_type eq "cleaning" || $bev_type eq "calibrate"} {
            set settings(last_upload_result) [translate "Not uploaded: Profile was 'cleaning' or 'calibrate'"]
            save_plugin_settings otel
            return
        }

        set espresso_data [::shot::create]
        ::plugins::otel::upload $espresso_data
    }

    proc async_dispatch {old new} {
        # Prevent uploading of data if last flow was HotWater or HotWaterRinse
        if { $old eq "Espresso" } {
            after 100 ::plugins::otel::uploadShotData
        }
    }

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
        set last_id $::plugins::otel::settings(last_upload_id)
        set data(last_action_result) $::plugins::otel::settings(last_upload_result)
        dui item config $page_to_show last_action_label -text [translate "Last upload:"]
        dui item config $page_to_show last_action -text [::plugins::otel::otel_settings::format_shot_start]
        dui item config $page_to_show last_action_result -text $::plugins::otel::settings(last_upload_result)
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
