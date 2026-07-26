#!/bin/sh

host=""
for argument in "$@"; do
    host="$argument"
done

IFS= read -r command
local_path=$(printf '%s\n' "$command" | sed -E 's/.*"([^"]*)"[[:space:]]*$/\1/')

case "$host" in
    success)
        mkdir -p "$(dirname "$local_path")"
        printf 'downloaded' > "$local_path"
        ;;
    folder)
        mkdir -p "$local_path"
        printf 'visible' > "$local_path/visible.txt"
        printf 'hidden' > "$local_path/.hidden"
        ;;
    failure)
        mkdir -p "$(dirname "$local_path")"
        printf 'partial' > "$local_path"
        printf 'Permission denied\n' >&2
        exit 1
        ;;
    notfound)
        printf 'Can'\''t ls: "/workspace" not found\n' >&2
        exit 1
        ;;
    hostkey)
        printf 'Host key verification failed.\nConnection closed\n' >&2
        exit 1
        ;;
    refused)
        printf 'ssh: connect to host 127.0.0.1 port 1: Connection refused\nConnection closed\n' >&2
        exit 1
        ;;
    slow)
        mkdir -p "$(dirname "$local_path")"
        printf 'partial' > "$local_path"
        exec /bin/sleep 60
        ;;
    stubborn)
        mkdir -p "$(dirname "$local_path")"
        trap '' TERM
        printf 'partial' > "$local_path"
        while :; do
            :
        done
        ;;
    *)
        printf 'Unknown fake host\n' >&2
        exit 1
        ;;
esac
