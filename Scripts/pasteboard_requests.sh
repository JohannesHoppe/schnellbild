#!/bin/bash
# Answers a UI test's requests on the pasteboard, for what only the workflow's
# shell may do (record or capture the screen: the test runner has no screen
# recording permission). Sourced by the workflows (ci.yml, screenshots.yml,
# demo-video.yml), which define the handler:
#   source Scripts/pasteboard_requests.sh
#   handle() { case "$1" in measure:*) …; answer "measured:…" ;; esac }
#   serve_requests handle      # in the background; its PID in $helper
#   …                          # run the tests
#   stop_serving
# The handler gets every text found on the pasteboard, its own answers
# included, and ignores what isn't a request. It answers with `answer`, also
# when it failed, so the test learns of it at once (an answer the test
# doesn't expect fails it): a request is never answered as done when it
# wasn't.

# Puts the answer on the pasteboard for the test to read.
answer() {
    printf '%s' "$1" | pbcopy
}

# Calls the function named $1 with what the pasteboard holds, five times a
# second, in a background process until stop_serving.
serve_requests() {
    (
        # One failed command in a handler must not end the helper (the
        # workflow's steps run with -e)
        set +e
        while :; do
            "$1" "$(pbpaste 2>/dev/null)"
            sleep 0.2
        done
    ) &
    helper=$!
}

stop_serving() {
    kill "$helper" 2>/dev/null || true
}
