#!/bin/sh

host=""
control_socket=""
for argument in "$@"; do
    host="$argument"
    case "$argument" in
        ControlPath=*) control_socket=${argument#ControlPath=} ;;
    esac
done

IFS= read -r command
local_path=$(printf '%s\n' "$command" | sed -E 's/.*"([^"]*)"[[:space:]]*$/\1/')

case "$host" in
    RelayBarUploadNew-*|RelayBarUploadReplace-*|RelayBarUploadProgress-*|RelayBarUploadMeasureFail-*|RelayBarUploadNoHardLink-*|RelayBarUploadNoRename-*|RelayBarUploadRace-*|RelayBarUploadLinkCollision-*|RelayBarUploadCancel-*|RelayBarUploadPublishCancel-*|RelayBarUploadCleanupFail-*|RelayBarUploadCleanupRetry-*|RelayBarUploadPublishCleanupFail-*|RelayBarUploadDirectory-*|RelayBarUploadSymlink-*|RelayBarUploadCache-*|RelayBarUploadSessionChange-*)
        upload_log="/tmp/$host.log"
        upload_state="/tmp/$host.state"
        printf '%s\n' "$command" >> "$upload_log"

        case "$command" in
            quit*)
                case "$host" in
                    RelayBarUploadNoHardLink-*)
                        printf '%s\n' 'debug2: Server supports extension "posix-rename@openssh.com" revision 1' >&2
                        ;;
                    RelayBarUploadNoRename-*)
                        printf '%s\n' 'debug2: Server supports extension "hardlink@openssh.com" revision 1' >&2
                        ;;
                    *)
                        printf '%s\n' 'debug2: Server supports extension "posix-rename@openssh.com" revision 1' >&2
                        printf '%s\n' 'debug2: Server supports extension "hardlink@openssh.com" revision 1' >&2
                        ;;
                esac
                ;;
            ls*)
                case "$host:$command" in
                    RelayBarUploadMeasureFail-*:*relaybar-upload-*)
                        printf 'Measurement unavailable\n' >&2
                        exit 1
                        ;;
                    RelayBarUploadProgress-*:*relaybar-upload-*)
                        printf '%s\n' "-rw-r--r-- 1 alice staff 3 Aug 30 12:00 $local_path"
                        exit 0
                        ;;
                esac
                printf '%s\n' '-rw-r--r-- 1 alice staff 4 Aug 24 12:00 baseline.txt'
                case "$host" in
                    RelayBarUploadReplace-*|RelayBarUploadNoRename-*)
                        printf '%s\n' '-rw-r--r-- 1 alice staff 8 Aug 24 12:01 release.zip'
                        ;;
                    RelayBarUploadDirectory-*)
                        printf '%s\n' 'drwxr-xr-x 2 alice staff 64 Aug 24 12:01 release.zip'
                        ;;
                    RelayBarUploadSymlink-*)
                        printf '%s\n' 'lrwxr-xr-x 1 alice staff 10 Aug 24 12:01 release.zip -> elsewhere.zip'
                        ;;
                    RelayBarUploadRace-*)
                        if [ -e "$upload_state" ]; then
                            printf '%s\n' '-rw-r--r-- 1 alice staff 8 Aug 24 12:01 release.zip'
                        fi
                        ;;
                    RelayBarUploadLinkCollision-*)
                        if [ -e "$upload_state.collision" ]; then
                            printf '%s\n' '-rw-r--r-- 1 alice staff 8 Aug 24 12:01 release.zip'
                        fi
                        ;;
                esac
                ;;
            put*)
                : > "$upload_state"
                case "$host" in
                    RelayBarUploadProgress-*)
                        /bin/sleep 1.2
                        ;;
                    RelayBarUploadMeasureFail-*)
                        /bin/sleep 0.8
                        ;;
                    RelayBarUploadCancel-*)
                        exec /bin/sleep 60
                        ;;
                    RelayBarUploadCleanupFail-*)
                        printf 'Upload failed\n' >&2
                        exit 1
                        ;;
                    RelayBarUploadSessionChange-*)
                        rm -f "$control_socket"
                        ;;
                esac
                ;;
            ln*)
                case "$host" in
                    RelayBarUploadLinkCollision-*)
                        : > "$upload_state.collision"
                        printf 'Target appeared before hard-link publication\n' >&2
                        exit 1
                        ;;
                esac
                ;;
            rename*)
                ;;
            rm*)
                case "$host" in
                    RelayBarUploadCleanupFail-*|RelayBarUploadPublishCleanupFail-*)
                        printf 'Cleanup failed\n' >&2
                        exit 1
                        ;;
                    RelayBarUploadCleanupRetry-*)
                        if [ ! -s "$upload_state" ]; then
                            printf 'retry\n' > "$upload_state"
                            printf 'Transient cleanup failure\n' >&2
                            exit 1
                        fi
                        rm -f "$upload_state"
                        ;;
                    RelayBarUploadPublishCancel-*)
                        if [ ! -e "$upload_state.cleanup" ]; then
                            : > "$upload_state.cleanup"
                            exec /bin/sleep 60
                        fi
                        rm -f "$upload_state" "$upload_state.cleanup"
                        ;;
                    *)
                        rm -f "$upload_state"
                        ;;
                esac
                ;;
            *)
                printf 'Unknown fake upload command\n' >&2
                exit 1
                ;;
        esac
        exit 0
        ;;
esac

case "$host" in
    RelayBarDeleteSuccess-*|RelayBarDeleteChanged-*|RelayBarDeleteRejected-*|RelayBarDeleteUnknown-*)
        delete_log="/tmp/$host.log"
        printf '%s\n' "$command" >> "$delete_log"
        case "$command" in
            ls*)
                if printf '%s' "$host" | grep -q 'Changed'; then
                    printf '%s\n' '-rw-r--r-- 1 alice staff 8 Aug 30 12:00 /srv/app/report[1].json'
                else
                    printf '%s\n' '-rw-r--r-- 1 alice staff 7 Aug 30 12:00 /srv/app/report[1].json'
                fi
                ;;
            rm*)
                case "$host" in
                    RelayBarDeleteRejected-*)
                        printf 'Permission denied\n' >&2
                        exit 1
                        ;;
                    RelayBarDeleteUnknown-*)
                        exec /bin/sleep 60
                        ;;
                esac
                ;;
            *)
                printf 'Unknown fake delete command\n' >&2
                exit 1
                ;;
        esac
        exit 0
        ;;
esac

case "$host" in
    listing|shared)
        case "$command" in
        get*)
            mkdir -p "$(dirname "$local_path")"
            printf 'downloaded' > "$local_path"
            ;;
        *)
            printf '%s\n' '-rw-r--r-- 1 alice staff 12 Jul 29 12:00 report.txt'
            printf '%s\n' 'drwxr-xr-x 2 alice staff 64 Jul 29 12:01 output'
            ;;
        esac
        ;;
    directfile)
        printf '%s\n' '-rw-r--r-- 1 linxy97 staff 4096 Aug 3 20:30 /home/linxy97/workspace/2026/youtube-video-transcript/TRANSCRIPTION_LEARNINGS.md'
        ;;
    sharedslow)
        case "$command" in
        get*)
            mkdir -p "$(dirname "$local_path")"
            printf 'partial' > "$local_path"
            exec /bin/sleep 60
            ;;
        *)
            printf '%s\n' '-rw-r--r-- 1 alice staff 12 Jul 29 12:00 report.txt'
            printf '%s\n' 'drwxr-xr-x 2 alice staff 64 Jul 29 12:01 output'
            ;;
        esac
        ;;
    RelayBarCancelledSFTP-*)
        : > "/tmp/$host"
        printf '%s\n' '-rw-r--r-- 1 alice staff 12 Jul 29 12:00 report.txt'
        ;;
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
