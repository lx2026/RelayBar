#!/bin/sh

set -eu

log_file="${RELAYBAR_FAKE_SSH_LOG:-}"
pid_file="${RELAYBAR_FAKE_SSH_PID:-}"
ready_file="${RELAYBAR_FAKE_SSH_READY_FILE:-}"
counter_file="${RELAYBAR_FAKE_SSH_COUNTER:-}"
fail_spec="${RELAYBAR_FAKE_SSH_FAIL_SPEC:-}"
delay_spec="${RELAYBAR_FAKE_SSH_DELAY_SPEC:-}"
# A forward that ignores SIGTERM, so a stopped launch's control operation stays
# alive while the next launch starts. Used to exercise launch-generation scoping.
ignore_term_spec="${RELAYBAR_FAKE_SSH_IGNORE_TERM_SPEC:-}"
# Lets process-shutdown tests prove RelayBar escalates a wedged master to
# SIGKILL instead of waiting forever for a termination callback.
ignore_master_term="${RELAYBAR_FAKE_SSH_IGNORE_MASTER_TERM:-}"

if [ -n "$log_file" ]; then
    {
        printf 'BEGIN\n'
        for argument in "$@"; do
            printf 'ARG:%s\n' "$argument"
        done
        printf 'END\n'
    } >> "$log_file"
fi

control_socket=""
operation=""
forward_option=""
forward_spec=""
previous=""

for argument in "$@"; do
    if [ "$previous" = "-S" ]; then
        control_socket="$argument"
    elif [ "$previous" = "-O" ]; then
        operation="$argument"
    elif [ "$previous" = "-L" ] || [ "$previous" = "-D" ] || [ "$previous" = "-R" ]; then
        forward_option="$previous"
        forward_spec="$argument"
    fi
    previous="$argument"
done

is_master=0
for argument in "$@"; do
    if [ "$argument" = "-M" ]; then
        is_master=1
    fi
done

if [ "$is_master" -eq 1 ]; then
    if [ "${RELAYBAR_FAKE_SSH_FAIL_MASTER:-}" = "1" ]; then
        printf 'fake connection failure\n' >&2
        exit 255
    fi
    if [ -z "$control_socket" ]; then
        printf 'missing fake control socket\n' >&2
        exit 2
    fi
    if [ -n "$pid_file" ]; then
        printf '%s\n' "$$" > "$pid_file"
    fi
    if [ "$ignore_master_term" = "1" ]; then
        trap '' TERM INT
        trap 'rm -f "$control_socket" "$pid_file"' EXIT
    else
        trap 'rm -f "$control_socket" "$pid_file"; exit 0' TERM INT EXIT
    fi
    if [ -n "$ready_file" ]; then
        while [ ! -f "$ready_file" ]; do
            :
        done
    fi
    : > "$control_socket"
    while :; do
        sleep 1
    done
fi

if [ "$operation" = "forward" ]; then
    if [ -n "$ignore_term_spec" ] && [ "$forward_spec" = "$ignore_term_spec" ]; then
        trap '' TERM INT
        sleep 1
        exit 0
    fi

    if [ -n "$delay_spec" ] && [ "$forward_spec" = "$delay_spec" ]; then
        trap 'exit 124' TERM INT
        sleep 2
    fi

    if [ -n "$fail_spec" ] && [ "$forward_spec" = "$fail_spec" ]; then
        printf 'fake forwarding failure for %s\n' "$forward_spec" >&2
        exit 23
    fi

    if [ "$forward_option" = "-R" ]; then
        case "$forward_spec" in
            0|*:0|0:*|*:0:*)
                next_port=47000
                if [ -n "$counter_file" ] && [ -f "$counter_file" ]; then
                    next_port=$(cat "$counter_file")
                fi
                printf '%s\n' "$next_port"
                if [ -n "$counter_file" ]; then
                    printf '%s\n' "$((next_port + 1))" > "$counter_file"
                fi
                ;;
        esac
    fi
    exit 0
fi

printf 'unsupported fake ssh invocation\n' >&2
exit 2
