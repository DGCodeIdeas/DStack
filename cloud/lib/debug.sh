#!/usr/bin/env bash
# =============================================================================
# DStack Debug/Verbosity Helper
# =============================================================================
# Source this near the top of a script, right after `set -euo pipefail`:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/debug.sh"
#
# Toggle with an environment variable — identical behavior for local runs and
# for scripts invoked remotely over SSH:
#   DEBUG=1 bash cloud/install-local.sh
#   DEBUG=1 bash cloud/provision-ec2.sh --existing --ip 1.2.3.4
#
# On the remote-execution paths (provision-ec2.sh, run-on-existing-ec2.sh),
# DEBUG is threaded through explicitly as one of the injected `export` lines
# in the generated remote script — the same mechanism already used for
# RDS_ENDPOINT, GITHUB_TOKEN, etc. It is NOT passed via SSH's env-forwarding
# (AcceptEnv/SendEnv), which requires sshd_config changes on the target host
# and won't survive a fresh EC2 instance or AMI change.
#
# This does not affect SSH's own connection-level verbosity (auth, key
# exchange, protocol negotiation) — that's a separate concern, and if you
# need it, just add -v / -vv / -vvv to the ssh command itself. What this
# toggles is tracing of what the *script* does once it's running, which is
# what you want for debugging an install or deploy step.
# =============================================================================

if [[ "${DEBUG:-0}" == "1" ]]; then
    _debug_src="${BASH_SOURCE[1]:-${BASH_SOURCE[0]:-stdin}}"
    _debug_src="${_debug_src##*/}"
    export PS4="+ [\\D{%H:%M:%S}] ${_debug_src}:"'${LINENO}:${FUNCNAME[0]:-main}(): '
    unset _debug_src
    set -x
fi
