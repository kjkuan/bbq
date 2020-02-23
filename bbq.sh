#!/usr/bin/env bash
#
# bbq - Simple Bash message queues using Linux named pipes.
#
# bbq.sh provides a few convenient Bash functions for creating and working with
# Linux named pipes (FIFO).  Its primary use case is to set up multiple worker
# processes getting work from a single job queue in your shell script; please
# see the examples/basic script for an example usage.
#
if [[ ${bbq_SOURCED:-} ]]; then
	return 0
fi
bbq_error () { echo "$@" >&2; }
bbq_debug () { if [[ ${bbq_DEBUG:-} ]]; then echo "$@" >&2; fi; }

if [[ $BASH_SOURCE == "$0" ]]; then
	bbq_error "Please source bbq.sh instead of running it!"
	exit 1
fi

# Set it to enable some debugging outputs.
bbq_DEBUG=

# The default number of worker processes to run by bbq-start
bbq_WORKER_COUNT=4

# The named pipe to be used by default to serve as a message queue.
bbq_FIFO=

# Each "job" in bbq is a ${bbq_CHUNK_SIZE}-byte chunk of bash commands
# written to $bbq_FIFO that is used as a message queue.
#
bbq_CHUNK_SIZE=1024  # bytes; on Linux the limit is 4k.


# Create a named pipe (FIFO) and set it as the default FIFO ($bbq_FIFO).
#
# If an argument is provided it's taken to be the path of the FIFO to be
# created; otherwise, a random file name will be chosen for the FIFO in the
# current directory.
#
bbq-new () {  # [queue]
	local queue=${1:-}
	[[ $queue ]] || queue=bbq-$$-$RANDOM
	[[ $queue == /* ]] || queue=$PWD/$queue
	mkfifo -m 0600 "$queue" || return $?
    bbq_FIFO=$queue
}

# Start worker processes in the background to process the queue and wait for
# them to end.
#
# Arguments:
#
#   queue  - Optional. Path to the named pipe for the workers to read
#            messages/commands from. If ommitted then the queue is
#            taken to be $bbq_FIFO, and in which case, it will also be
#            deleted at the end.
#
# Options:
#
#    -w COUNT  - Number of worker processes to create that work on the queue.
#                Default is 4 workers.
#
bbq-start () {  # [-w COUNT] [queue]
    (declare -A workers  # pid -> exit code
     bbq_owns_the_pipe=
     trap '
         kill ${!workers[*]} >/dev/null 2>&1 || true
         if [[ $bbq_owns_the_pipe ]]; then rm -f "$bbq_FIFO"; fi
     ' EXIT
     _bbq_start_workers "$@"
    ) &
}

# Enqueue arbitrary Bash commands as a fixed length string into the $bbq_FIFO.
#
# Arguments:
#
#   command  - Arbitrary Bash command to add to the queue.
#
#   queue    - Optional. If ommitted, $bbq_FIFO is assumed; otherwise, it
#              should be a path to a message queue created by bbq-new.
#
# This command MUST ONLY be run after bbq-start.
#
# NOTE: This command may block on writing to the pipe if the pipe buffer is full.
#       Therefore, it's recommended that you run it as the last part of your
#       script. Alternatively, you can also run it in the background (i.e.,
#       with '&') directly or indirectly to avoid blocking the flow of your
#       script.
#
bbq () {  # <command> [queue]
    local code=$1 queue=${2:-$bbq_FIFO}
    if (( ${#code} > bbq_CHUNK_SIZE )); then
        bbq_error "Encoded message exceeds allowed chunk size ($bbq_CHUNK_SIZE): $code"
        return 1
    fi
	[[ $queue ]] || return $?

    # Accoridng to docs and google, on linux, read/write less than PIPE_BUF (4k
    # bytes) on a FIFO is atomic. So, we don't need to lock before writes.
    #
    # See also 'man fifo' and 'man 7 pipe'.
    #
    printf "%-${bbq_CHUNK_SIZE}s" "${code:0:$bbq_CHUNK_SIZE}" >"$bbq_FIFO"
}

# Internal implementation for bbq-start()
#
_bbq_start_workers () {  # [-w COUNT] [queue]
	local option; OPTIND=1
    while getopts ':w:' option "$@"; do
        case $option in
			w) bbq_WORKER_COUNT=$OPTARG ;;
            :) bbq_error "$FUNCNAME: Missing option argument for -$OPTARG"; return 1 ;;
            \?) bbq_error "$FUNCNAME: Unknown option: -$OPTARG"; return 1 ;;
        esac
    done
    shift $((OPTIND - 1))

    bbq_WORKER_COUNT=${bbq_WORKER_COUNT:-4}
    printf "%d" "$bbq_WORKER_COUNT" >/dev/null 2>&1 \
        && (( bbq_WORKER_COUNT > 0 )) || {
            bbq_error "Worker count should be > 0"
            return 1
        }

	local queue=${1:-}
	if [[ $queue ]]; then
		[[ $queue == /* ]] || queue=$PWD/$queue
		bbq_FIFO=$queue
	else
		bbq_owns_the_pipe=1
	fi
	[[ -p ${bbq_FIFO:?required} ]] || {
		bbq_error "$bbq_FIFO must be a named pipe!"
		return 1
	}

    # Fork the workers to do work.
    # This needs to be done before we can enqueue anything without blocking.
    #
    local i
    for ((i=0; i < $bbq_WORKER_COUNT; i++)); do
        _bbq_worker & workers[$!]=
    done

    # Keep a write FD open to the FIFO to prevent the read ends from
    # getting EOFs, which happens when all write FDs are closed.
    #
    local write_fd; exec {write_fd}>"$bbq_FIFO" || return $?

    # Wait for the worker processes to exit
    local pid failed=
    for pid in ${!workers[*]}; do
        wait $pid && workers[$pid]=0 || {
            workers[$pid]=$?
            bbq_error "Worker $pid exited! (rc=${workers[$pid]})"
            failed=1
        }
    done
    [[ ! $failed ]]
}

# Represents a background worker sub process that takes commands from FIFO.
#
_bbq_worker () {
    local read_fd
    exec {read_fd}<"${bbq_FIFO:?required}" || return $?

    local code
    _bbq_pop () {
        local rc
        flock $read_fd || return $?
        read -u $read_fd -rN "$bbq_CHUNK_SIZE" code || rc=$?
        flock -u $read_fd || return $?
        return $rc
    }
    while true; do
        code=; _bbq_pop || {
            bbq_debug "Worker $BASHPID: Failed dequeuing! code=$code"
            continue
        }
        eval "$code"
        # NOTE:
        #   - If you 'set -e' then the worker could die due to a non-zero
        #     exit from evaluating $code.
        #   - If all your workers exited (i.e., no more FDs reading on the
        #     pipe) then the enqueue operation will either block on opening the write end,
        #     or you get a SIGPIPE when writing to the pipe.
    done
    bbq_debug "Worker $BASHPID quit"
    eval "exec $read_fd>&-"
}

bbq_SOURCED=1
