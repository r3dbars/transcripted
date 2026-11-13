#!/bin/bash
# Pure argument parsing shared by the beta entrypoint and its isolated tests.
parse_beta_build_arguments() {
    USER_NAME="beta"
    if [ "${1:-}" = "--user-name" ]; then
        if [ "$#" -ne 2 ]; then
            printf '%s\n' 'Usage: build-beta.sh --user-name <user-name>' >&2
            return 2
        fi
        USER_NAME="${2:-beta}"
        return 0
    fi

    # Legacy shape: [ignored-token [user-name]]. Never retain or print the first
    # argument, or reinterpret a lone legacy token as the requested user name.
    USER_NAME="${2:-beta}"
}
