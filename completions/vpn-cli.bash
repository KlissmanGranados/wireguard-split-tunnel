# Bash completion for vpn-cli.sh. Usage: source completions/vpn-cli.bash
_VPN_CLI_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)

_vpn_cli() {
  local cur=${COMP_WORDS[COMP_CWORD]} cmd=${COMP_WORDS[1]:-}
  local cmds="menu apply up down toggle status set edit domains verify doctor use import help"
  COMPREPLY=()
  if (( COMP_CWORD == 1 )); then
    COMPREPLY=($(compgen -W "$cmds" -- "$cur")); return 0
  fi
  case "$cmd" in
    apply) COMPREPLY=($(compgen -W "--dry-run --verbose --refresh-discovery" -- "$cur")) ;;
    set)
      if (( COMP_CWORD == 2 )); then
        COMPREPLY=($(compgen -W "name iface resolver discover autoconnect" -- "$cur"))
      elif (( COMP_CWORD == 3 )); then
        case "${COMP_WORDS[2]}" in
          discover|autoconnect) COMPREPLY=($(compgen -W "on off" -- "$cur")) ;;
          resolver) COMPREPLY=($(compgen -W "system" -- "$cur")) ;;
        esac
      fi ;;
    use)
      if (( COMP_CWORD == 2 )); then
        local home=${WG_SPLIT_HOME:-$_VPN_CLI_DIR} f
        local -a names=()
        for f in "$home"/confs/*.conf; do [[ -e $f ]] && names+=("${f##*/}"); done
        COMPREPLY=($(compgen -W "${names[*]}" -- "$cur"))
      fi ;;
    import)
      if [[ $cur == -* ]]; then
        COMPREPLY=($(compgen -W "--force" -- "$cur"))
      else
        local IFS=$'\n'
        COMPREPLY=($(compgen -f -X '!*.conf' -- "$cur") $(compgen -d -- "$cur"))
      fi ;;
  esac
  return 0
}
complete -F _vpn_cli vpn-cli.sh vpn-cli ./vpn-cli.sh
