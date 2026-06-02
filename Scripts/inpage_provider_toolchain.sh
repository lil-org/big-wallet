inpage_provider_append_tool_path() {
    if [ -d "$1" ]; then
        if [ -n "${inpage_provider_tool_path:-}" ]; then
            inpage_provider_tool_path="$inpage_provider_tool_path:$1"
        else
            inpage_provider_tool_path="$1"
        fi
    fi
}

inpage_provider_prepare_tool_path() {
    inpage_provider_tool_path=""

    if [ -n "${HOME:-}" ]; then
        inpage_provider_append_tool_path "$HOME/.volta/bin"
        inpage_provider_append_tool_path "$HOME/.asdf/shims"
        inpage_provider_append_tool_path "$HOME/.local/bin"
    fi

    inpage_provider_append_tool_path /opt/homebrew/bin
    inpage_provider_append_tool_path /usr/local/bin

    if [ -n "$inpage_provider_tool_path" ]; then
        PATH="$inpage_provider_tool_path:$PATH"
    fi
    export PATH
}

require_inpage_provider_toolchain() {
    if ! command -v node >/dev/null 2>&1; then
        echo "error: Node.js 18 or newer is required to build the inpage script" >&2
        return 1
    fi

    if ! node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 18 ? 0 : 1)'; then
        echo "error: Node.js 18 or newer is required to build the inpage script" >&2
        return 1
    fi

    if ! command -v npm >/dev/null 2>&1; then
        echo "error: npm 9 or newer is required to build the inpage script" >&2
        return 1
    fi

    inpage_provider_npm_version=$(npm --version) || {
        echo "error: npm 9 or newer is required to build the inpage script" >&2
        return 1
    }
    inpage_provider_npm_major=${inpage_provider_npm_version%%.*}
    case "$inpage_provider_npm_major" in
        ""|*[!0-9]*)
            echo "error: npm 9 or newer is required to build the inpage script" >&2
            return 1
            ;;
    esac

    if [ "$inpage_provider_npm_major" -lt 9 ]; then
        echo "error: npm 9 or newer is required to build the inpage script" >&2
        return 1
    fi
}
