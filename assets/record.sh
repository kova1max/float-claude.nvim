#!/bin/sh
# Records the README's GIFs from the VHS tapes in this directory:
#
#   assets/record.sh             # all of them
#   assets/record.sh edit lsp    # just these
#
# Needs vhs (https://github.com/charmbracelet/vhs, with its ttyd and ffmpeg),
# git, and lua-language-server for lsp.tape. Neovim runs assets/demo/init.lua in
# throwaway XDG directories, with the tokyonight colorscheme and the repo's
# fake CLI (tests/fake_claude.lua) scripting Claude's replies, so no account is
# needed and every recording is the same.
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" XDG_STATE_HOME="$tmp/state" XDG_CACHE_HOME="$tmp/cache"
export TOKYONIGHT="$tmp/tokyonight.nvim"
git clone --quiet --depth 1 --branch v4.14.1 https://github.com/folke/tokyonight.nvim "$TOKYONIGHT"
[ $# -gt 0 ] || set -- answer edit review hide lsp
for name in "$@"; do
  FLOAT_CLAUDE_DEMO="$name" vhs "assets/$name.tape"
done
