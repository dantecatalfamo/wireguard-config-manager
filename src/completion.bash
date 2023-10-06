#!/usr/bin/env bash

function _wgcm_completions {
    if [ "${#COMP_WORDS[@]}" -eq 2 ]; then
        COMPREPLY=($(compgen -W "names list add peer unpeer route allow unallow remove export openbsd genpsk setpsk clearpsk keepalive set dump bash" "${COMP_WORDS[1]}"))
    fi
    case "${COMP_WORDS[1]}" in
        names)
        ;;
        list)
            if [ "${#COMP_WORDS[@]}" -eq 3 ]; then
                COMPREPLY=($(compgen -W "$(wgcm names)" "${COMP_WORDS[-1]}"))
            fi
        ;;
        add)
        ;;
        peer)
            if [ "${#COMP_WORDS[@]}" -lt 5 ]; then
                COMPREPLY=($(compgen -W "$(wgcm names)" "${COMP_WORDS[-1]}"))
            fi
        ;;
        unpeer)
            if [ "${#COMP_WORDS[@]}" -lt 5 ]; then
                COMPREPLY=($(compgen -W "$(wgcm names)" "${COMP_WORDS[-1]}"))
            fi
        ;;
        route)
            if [ "${#COMP_WORDS[@]}" -lt 5 ]; then
                COMPREPLY=($(compgen -W "$(wgcm names)" "${COMP_WORDS[-1]}"))
            fi
        ;;
        allow)
            if [ "${#COMP_WORDS[@]}" -lt 5 ]; then
                COMPREPLY=($(compgen -W "$(wgcm names)" "${COMP_WORDS[-1]}"))
            fi
        ;;
        unallow)
            if [ "${#COMP_WORDS[@]}" -lt 5 ]; then
                COMPREPLY=($(compgen -W "$(wgcm names)" "${COMP_WORDS[-1]}"))
            fi
        ;;
        remove)
            if [ "${#COMP_WORDS[@]}" -eq 3 ]; then
                COMPREPLY=($(compgen -W "$(wgcm names)" "${COMP_WORDS[-1]}"))
            fi
        ;;
        export)
            if [ "${#COMP_WORDS[@]}" -eq 3 ]; then
                COMPREPLY=($(compgen -W "$(wgcm names)" "${COMP_WORDS[-1]}"))
            fi
        ;;
        openbsd)
            if [ "${#COMP_WORDS[@]}" -eq 3 ]; then
                COMPREPLY=($(compgen -W "$(wgcm names)" "${COMP_WORDS[-1]}"))
            fi
        ;;
        genpsk)
            if [ "${#COMP_WORDS[@]}" -lt 5 ]; then
                COMPREPLY=($(compgen -W "$(wgcm names)" "${COMP_WORDS[-1]}"))
            fi
        ;;
        setpsk)
            if [ "${#COMP_WORDS[@]}" -lt 5 ]; then
                COMPREPLY=($(compgen -W "$(wgcm names)" "${COMP_WORDS[-1]}"))
            fi
            ;;
        clearpsk)
            if [ "${#COMP_WORDS[@]}" -lt 5 ]; then
                COMPREPLY=($(compgen -W "$(wgcm names)" "${COMP_WORDS[-1]}"))
            fi
        ;;
        keepalive)
            if [ "${#COMP_WORDS[@]}" -lt 5 ]; then
                COMPREPLY=($(compgen -W "$(wgcm names)" "${COMP_WORDS[-1]}"))
            fi
        ;;
        set)
            if [ "${#COMP_WORDS[@]}" -eq 3 ]; then
                COMPREPLY=($(compgen -W "$(wgcm names)" "${COMP_WORDS[-1]}"))
            elif [ "${#COMP_WORDS[@]}" -eq 4 ]; then
                COMPREPLY=($(compgen -W "name comment privkey hostname address port dns table mtu pre_up post_up pre_down post_down" "${COMP_WORDS[-1]}"))
            fi
        ;;
        dump)
            if [ "${#COMP_WORDS[@]}" -eq 3 ]; then
                COMPREPLY=($(compgen -A directory "${COMP_WORDS[-1]}"))
            fi
        ;;
    esac
}

complete -F _wgcm_completions wgcm
