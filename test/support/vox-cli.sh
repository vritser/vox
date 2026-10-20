#!/bin/sh
# Synthetic NDJSON fixture. No microphone, credentials, or network access.
printf '%s\n' '{"v":1,"type":"started"}'
IFS= read -r control || exit 2
case "$control" in
  '{"v":1,"type":"stop"}')
    printf '%s\n' '{"v":1,"type":"final","segment_id":"1","text":"synthetic CLI"}'
    printf '%s\n' '{"v":1,"type":"completed"}'
    exit "${1:-0}"
    ;;
  '{"v":1,"type":"cancel"}') exit 0 ;;
  *) exit 3 ;;
esac
