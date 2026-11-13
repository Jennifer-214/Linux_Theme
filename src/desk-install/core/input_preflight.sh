# The bootstrap reads the native policy table before it can build the orchestrator. No eval or sourced user data.
desk_input_mode=0
declare -A desk_input_flags=() desk_input_values=()
while IFS= read -r desk_input_rule; do
    if [[ $desk_input_rule =~ ^DESK_INPUT_OPTION\(\"([^\"]+)\",[[:space:]]*([0-9]+)\)$ ]]; then
        desk_input_flags[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
    elif [[ $desk_input_rule =~ ^DESK_INPUT_VALUE\(\"([^\"]+)\"\)$ ]]; then
        desk_input_values[${BASH_REMATCH[1]}]=1
    fi
done < "$SCRIPT_DIR/src/desk-install/core/input_options.def"
desk_input_skip=0
for desk_input_arg in "$@"; do
    if (( desk_input_skip )); then desk_input_skip=0; continue; fi
    [[ $desk_input_arg == -- ]] && break
    desk_input_value=${desk_input_flags[$desk_input_arg]:-0}
    if (( desk_input_value > desk_input_mode )); then desk_input_mode=$desk_input_value; fi
    if [[ ${desk_input_values[$desk_input_arg]:-0} == 1 ]]; then desk_input_skip=1; fi
done
if (( desk_input_mode == 0 )) && { [[ ! -t 0 ]] || [[ ! -t 1 ]]; }; then
    printf '%s\n' 'Interactive installation requires a terminal for input and output.' \
        'Run in a terminal; use --yes only for an intentional unattended install.' >&2
    exit 1
fi
# Inspection bypasses self-update, sudo and make install; only repository build artifacts may be refreshed.
if (( desk_input_mode == 2 )); then
    make --no-print-directory -C "$SCRIPT_DIR/src/desk-install" >&2
    exec "$FOX_INSTALL_BIN" "$@"
fi
unset desk_input_rule desk_input_flags desk_input_values desk_input_value desk_input_arg desk_input_mode desk_input_skip
