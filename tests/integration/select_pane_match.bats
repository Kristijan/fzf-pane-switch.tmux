#!/usr/bin/env bats

bats_require_minimum_version 1.11.0
load ../test_helper

setup() {
    if [[ "${RUN_FZF_PANE_SWITCH_INTEGRATION:-false}" != true ]]; then
        skip 'set RUN_FZF_PANE_SWITCH_INTEGRATION=true to run real tmux/fzf integration tests'
    fi

    REPO_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    export REPO_DIR
    REAL_TMUX="${TMUX_INTEGRATION_BINARY:-$(PATH='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin' command -v tmux)}"
    REAL_FZF="${FZF_INTEGRATION_BINARY:-$(PATH='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin' command -v fzf)}"
    REAL_PYTHON="${PYTHON_INTEGRATION_BINARY:-$(PATH='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin' command -v python3)}"
    [[ -x "${REAL_TMUX}" && -x "${REAL_FZF}" && -x "${REAL_PYTHON}" ]] ||
        skip 'real tmux, fzf, and Python 3 are required'
    export REAL_TMUX REAL_FZF REAL_PYTHON
    export TMUX_TEST_SOCKET="fzf-pane-switch-integration-$$-${BATS_TEST_NUMBER}"
    PATH="$(dirname "${REAL_FZF}"):$(dirname "${REAL_TMUX}"):/usr/bin:/bin:/usr/sbin:/sbin"
    export PATH

    tmux() {
        "${REAL_TMUX}" -L "${TMUX_TEST_SOCKET}" "$@"
    }
    export -f tmux

    "${REAL_TMUX}" -L "${TMUX_TEST_SOCKET}" -f /dev/null new-session -d \
        -s integration -x 120 -y 40 \
        "printf 'integration-alpha-token\\n'; exec sleep 60"
    "${REAL_TMUX}" -L "${TMUX_TEST_SOCKET}" new-window -d -t integration: \
        "printf 'integration-beta-token\\n'; exec sleep 60"

    match_dir="$(mktemp -d "${BATS_TEST_TMPDIR}/fzf-pane-switch.XXXXXX")"
    export match_dir
    export TMPDIR="${BATS_TEST_TMPDIR}"
    export FZF_PANE_SWITCH_LAYOUT='one-row'
    export FZF_PANE_SWITCH_PANE_FORMAT='#{pane_id} #{window_name}'
    field_separator=$'\037'
    export field_separator

    while IFS= read -r pane_id; do
        printf '%s%spane%sintegration target\0' \
            "${pane_id}" "${field_separator}" "${field_separator}" \
            >> "${match_dir}/metadata.1"
        printf '%s%spane%sintegration target%sintegration target\0' \
            "${pane_id}" "${field_separator}" "${field_separator}" "${field_separator}" \
            >> "${match_dir}/metadata-search.1"
    done < <(tmux list-panes -aF '#{pane_id}')
    printf '1\n' > "${match_dir}/generation"
    printf 'indexing\n' > "${match_dir}/state.1"
}

teardown() {
    if [[ -n "${REAL_TMUX:-}" && -n "${TMUX_TEST_SOCKET:-}" ]]; then
        "${REAL_TMUX}" -L "${TMUX_TEST_SOCKET}" kill-server 2>/dev/null || true
    fi
}

require_backdrop_versions() {
    local tmux_version fzf_version
    tmux_version="$(tmux -V | awk '{print $2}')"
    fzf_version="$("${REAL_FZF}" --version | awk '{print $1}')"
    # Use the launcher's version comparison, avoiding a minor-version regex
    # which would incorrectly skip a future tmux 3.10.
    [[ "${tmux_version}" == 3.8* || "${tmux_version}" == 3.9* ||
        "${tmux_version}" == 3.[1-9][0-9]* || "${tmux_version}" == [4-9].* ]] ||
        skip 'tmux 3.8 or later is required for backdrop dimming'
    local major minor patch
    IFS=. read -r major minor patch <<< "${fzf_version}"
    if (( major == 0 && (minor < 74 || (minor == 74 && patch < 5)) )); then
        skip 'fzf 0.74.5 or later is required for backdrop dimming'
    fi
}

@test "real tmux rapid backdrop invocations leave exactly one owner and clean up" {
    require_backdrop_versions
    tmux split-window -d -t integration:0
    tmux set-option -g window-style 'fg=cyan'
    tmux set-option -g @fzf_pane_switch_preview-pane false
    tmux set-option -g @fzf_pane_switch_backdrop-dim '60%'
    tmux run-shell "${REPO_DIR}/select_pane.tmux"
    export BACKDROP_SCENARIO=double-launch
    run "${REAL_PYTHON}" "${REPO_DIR}/tests/integration/drive_backdrop.py" \
        "${REAL_TMUX}" "${TMUX_TEST_SOCKET}"
    assert_status 0
}

@test "real tmux backdrop preserves a replaced hook" {
    require_backdrop_versions
    tmux split-window -d -t integration:0
    tmux set-option -g window-style 'fg=cyan'
    tmux set-option -g @fzf_pane_switch_preview-pane false
    tmux set-option -g @fzf_pane_switch_backdrop-dim '60%'
    tmux run-shell "${REPO_DIR}/select_pane.tmux"
    export BACKDROP_SCENARIO=replace-hook
    run "${REAL_PYTHON}" "${REPO_DIR}/tests/integration/drive_backdrop.py" \
        "${REAL_TMUX}" "${TMUX_TEST_SOCKET}"
    assert_status 0
}

@test "real tmux signal during backdrop setup restores state" {
    require_backdrop_versions
    tmux split-window -d -t integration:0
    tmux set-option -g window-style 'fg=cyan'
    tmux set-option -g @fzf_pane_switch_preview-pane false
    tmux set-option -g @fzf_pane_switch_backdrop-dim '60%'
    export BACKDROP_SIGNAL_MARKER="${BATS_TEST_TMPDIR}/setup-interrupted"
    tmux set-environment -g REAL_TMUX "${REAL_TMUX}"
    tmux set-environment -g BACKDROP_SIGNAL_MARKER "${BACKDROP_SIGNAL_MARKER}"
    tmux set-environment -g PATH "${REPO_DIR}/tests/integration/fixtures:${PATH}"
    tmux set-environment -gu 'BASH_FUNC_tmux%%'
    tmux set-option -g default-shell /bin/sh
    tmux run-shell "${REPO_DIR}/select_pane.tmux"
    export BACKDROP_SCENARIO=signal-setup
    run "${REAL_PYTHON}" "${REPO_DIR}/tests/integration/drive_backdrop.py" \
        "${REAL_TMUX}" "${TMUX_TEST_SOCKET}"
    assert_status 0
}

@test "real tmux backdrop setup does not overwrite a racing style change" {
    require_backdrop_versions
    tmux split-window -d -t integration:0
    tmux set-option -g window-style 'fg=cyan'
    tmux set-option -g @fzf_pane_switch_preview-pane false
    tmux set-option -g @fzf_pane_switch_backdrop-dim '60%'
    export BACKDROP_SIGNAL_MARKER="${BATS_TEST_TMPDIR}/setup-interrupted"
    tmux set-environment -g REAL_TMUX "${REAL_TMUX}"
    tmux set-environment -g BACKDROP_SIGNAL_MARKER "${BACKDROP_SIGNAL_MARKER}"
    tmux set-environment -g BACKDROP_SETUP_ACTION style-change
    tmux set-environment -g PATH "${REPO_DIR}/tests/integration/fixtures:${PATH}"
    tmux set-environment -gu 'BASH_FUNC_tmux%%'
    tmux set-option -g default-shell /bin/sh
    tmux run-shell "${REPO_DIR}/select_pane.tmux"
    export BACKDROP_SCENARIO=style-setup
    run "${REAL_PYTHON}" "${REPO_DIR}/tests/integration/drive_backdrop.py" \
        "${REAL_TMUX}" "${TMUX_TEST_SOCKET}"
    assert_status 0
}

@test "real tmux backdrop recovers an owner PID with a different start time" {
    require_backdrop_versions
    tmux split-window -d -t integration:0
    tmux set-option -g window-style 'fg=cyan'
    tmux set-option -w -t integration:0 @fzf_pane_switch_backdrop-owner "$$:old-process-start"
    tmux set-option -g @fzf_pane_switch_preview-pane false
    tmux set-option -g @fzf_pane_switch_backdrop-dim '60%'
    tmux run-shell "${REPO_DIR}/select_pane.tmux"
    run "${REAL_PYTHON}" "${REPO_DIR}/tests/integration/drive_backdrop.py" \
        "${REAL_TMUX}" "${TMUX_TEST_SOCKET}"
    assert_status 0
}

@test "real tmux backdrop restores a local style containing nested formats" {
    require_backdrop_versions
    local original_style='fg=cyan,bg=default #{?pane_active,bold,none}'
    tmux split-window -d -t integration:0
    tmux set-option -w -t integration:0 window-style "${original_style}"
    tmux set-option -g @fzf_pane_switch_preview-pane false
    tmux set-option -g @fzf_pane_switch_backdrop-dim '60%'
    tmux run-shell "${REPO_DIR}/select_pane.tmux"
    run "${REAL_PYTHON}" "${REPO_DIR}/tests/integration/drive_backdrop.py" \
        "${REAL_TMUX}" "${TMUX_TEST_SOCKET}" 'fg=cyan' "${original_style}"
    assert_status 0
}

@test "real tmux backdrop selection targets only the originating client" {
    require_backdrop_versions
    tmux split-window -d -t integration:0
    tmux new-session -d -s observer
    tmux set-option -g window-style 'fg=cyan'
    tmux set-option -g @fzf_pane_switch_preview-pane false
    tmux set-option -g @fzf_pane_switch_backdrop-dim '60%'
    tmux run-shell "${REPO_DIR}/select_pane.tmux"
    export BACKDROP_SCENARIO=multi-client
    run "${REAL_PYTHON}" "${REPO_DIR}/tests/integration/drive_backdrop.py" \
        "${REAL_TMUX}" "${TMUX_TEST_SOCKET}"
    assert_status 0
}

@test "real tmux capture and fzf filtering survive repeated snapshot refresh" {
    run bash "${REPO_DIR}/select_pane.sh" --match-index "${match_dir}" 30
    assert_status 0
    assert_value_equal 'ready' "$(command cat "${match_dir}/state.1")"
    assert_file_contains "${match_dir}/index.1" 'integration-beta-token'

    bash "${REPO_DIR}/select_pane.sh" --match-filter "${match_dir}" \
        integration-beta-token > "${BATS_TEST_TMPDIR}/filtered"
    assert_file_contains "${BATS_TEST_TMPDIR}/filtered" 'integration target'

    tmux send-keys -t integration:1.0 "printf 'integration-refresh-token\\n'" Enter
    run bash "${REPO_DIR}/select_pane.sh" --match-refresh "${match_dir}"
    assert_status 0
    run bash "${REPO_DIR}/select_pane.sh" --match-index "${match_dir}" 30
    assert_status 0

    assert_value_equal '2' "$(command cat "${match_dir}/generation")"
    assert_value_equal 'ready' "$(command cat "${match_dir}/state.2")"
    assert_file_contains "${match_dir}/index.2" 'integration-refresh-token'
    refute_path_exists "${match_dir}/index.1"
}

@test "real fzf Ctrl-R refresh completes and clears its indexing state" {
    tmux set-environment -g TMPDIR "${BATS_TEST_TMPDIR}"
    tmux set-option -g @fzf_pane_switch_preview-pane false
    tmux set-option -g @fzf_pane_switch_preview-pane-match true
    tmux set-option -g @fzf_pane_switch_refresh true
    tmux set-option -g @fzf_pane_switch_footer true
    tmux set-option -g @fzf_pane_switch_layout one-row
    tmux run-shell "${REPO_DIR}/select_pane.tmux"

    run "${REAL_PYTHON}" "${REPO_DIR}/tests/integration/drive_switcher.py" \
        "${REAL_TMUX}" "${TMUX_TEST_SOCKET}" "${BATS_TEST_TMPDIR}"

    assert_status 0
}

@test "real tmux floating switcher dims on focus and restores window state" {
    require_backdrop_versions

    tmux split-window -d -t integration:0
    tmux set-option -g window-style 'fg=cyan'
    tmux set-option -g @fzf_pane_switch_preview-pane false
    tmux set-option -g @fzf_pane_switch_backdrop-dim '60%'
    tmux run-shell "${REPO_DIR}/select_pane.tmux"

    run "${REAL_PYTHON}" "${REPO_DIR}/tests/integration/drive_backdrop.py" \
        "${REAL_TMUX}" "${TMUX_TEST_SOCKET}"

    assert_status 0
}

@test "real tmux floating switcher recovers stale backdrop state" {
    require_backdrop_versions
    local stale_hook

    stale_hook='window-pane-changed[fzf-pane-switch-99999999]'
    tmux split-window -d -t integration:0
    tmux set-option -w -t integration:0 @fzf_pane_switch_backdrop-owner 99999999
    tmux set-option -w -t integration:0 @fzf_pane_switch_backdrop-was-local true
    tmux set-option -w -t integration:0 @fzf_pane_switch_backdrop-previous-style 'fg=yellow'
    tmux set-option -w -t integration:0 @fzf_pane_switch_backdrop-installed-style 'fg=magenta'
    tmux set-option -w -t integration:0 @fzf_pane_switch_backdrop-hook "${stale_hook}"
    tmux set-hook -w -t integration:0 "${stale_hook}" "set-option -wF -t @0 window-style '#{window-style}'"
    tmux set-option -w -t integration:0 window-style 'fg=magenta'
    tmux set-option -g @fzf_pane_switch_preview-pane false
    tmux set-option -g @fzf_pane_switch_backdrop-dim '60%'
    tmux run-shell "${REPO_DIR}/select_pane.tmux"

    run "${REAL_PYTHON}" "${REPO_DIR}/tests/integration/drive_backdrop.py" \
        "${REAL_TMUX}" "${TMUX_TEST_SOCKET}" 'fg=yellow' 'fg=yellow'

    assert_status 0
}

@test "real tmux floating switcher preserves a concurrent style change" {
    require_backdrop_versions

    tmux split-window -d -t integration:0
    tmux set-option -g window-style 'fg=cyan'
    tmux set-option -g @fzf_pane_switch_preview-pane false
    tmux set-option -g @fzf_pane_switch_backdrop-dim '60%'
    tmux run-shell "${REPO_DIR}/select_pane.tmux"

    run "${REAL_PYTHON}" "${REPO_DIR}/tests/integration/drive_backdrop.py" \
        "${REAL_TMUX}" "${TMUX_TEST_SOCKET}" 'fg=cyan' 'fg=green' 'fg=green'

    assert_status 0
}

@test "real tmux floating switcher initially previews the originating pane" {
    require_backdrop_versions

    tmux split-window -d -t integration:0
    tmux set-option -g window-style 'fg=cyan'
    tmux set-option -g @fzf_pane_switch_preview-pane true
    tmux set-option -g @fzf_pane_switch_preview-pane-match true
    tmux set-option -g @fzf_pane_switch_layout tree
    tmux set-option -g @fzf_pane_switch_backdrop-dim '60%'
    tmux run-shell "${REPO_DIR}/select_pane.tmux"
    export EXPECTED_PREVIEW_TOKEN='integration-alpha'

    run "${REAL_PYTHON}" "${REPO_DIR}/tests/integration/drive_backdrop.py" \
        "${REAL_TMUX}" "${TMUX_TEST_SOCKET}"

    assert_status 0
}
