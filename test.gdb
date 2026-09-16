set pagination off
set confirm off
set breakpoint pending on

break wl_log

commands
    silent

    set $msg = $arg1

    if $msg != 0
        printf "\n=== wl_log ===\n"
        printf "message = %s\n", $msg

        if strstr($msg, "already has listener") != 0
            printf "\n=== DUPLICATE WAYLAND LISTENER ===\n"
            bt 30
            quit
        end
    end

    continue
end

run