#############################################
#              Home Detection               #
#############################################

# Always resolve to real user home, even under sudo
REALHOME="/home/${SUDO_USER:-$USER}"

#############################################
#              Simple Shortcuts             #
#############################################

alias ll='ls -alh'
alias dir='ls -la'

dfh() { df -h "$@"; }
freeh() { free -h "$@"; }

alias up='cd ..'
alias up2='cd ../..'
alias home='cd'

gs() { git status "$@"; }
ping5() { ping -c 5 "$@"; }
ipinfo() { ip -c a; }
ipconfig() { ip a; }

update() { sudo apt update && sudo apt upgrade; }
rebootnow() { sudo reboot now; }
restartnow() { sudo reboot now; }
restart() { sudo reboot now; }
reboot() { sudo reboot now; }
poweroffnow() { sudo shutdown -h now; }

bashchk() { bash -n "$REALHOME/.bash_aliases"; }

# RELOAD + AUTO-BACKUP
rebash() {
    if bash -n "$REALHOME/.bash_aliases"; then
        # Create a timestamped backup before reloading
        cp "$REALHOME/.bash_aliases" "$REALHOME/.bash_aliases.bak"
        echo "Backup created (~/.bash_aliases.bak)"
        echo "Syntax OK - reloading..."
        source "$REALHOME/.bash_aliases"
    else
        echo "Syntax error - NOT reloading."
    fi
}

#############################################
#              Script Launchers             #
#############################################

backup() { sudo "$REALHOME/backup.sh" "$@"; }
printerstatus() { "$REALHOME/status.sh" "$@"; }
cleandisk() { "$REALHOME/cleandisk.sh" "$@"; }
clean() { "$REALHOME/cleandisk.sh" "$@"; }
nginxlogfix() { sudo "$REALHOME/nginxlogfix.sh"; }
timeshiftclean() { sudo bash "$REALHOME/timeshiftclean.sh" "$@"; }
wifi() { sudo bash "$REALHOME/wifi.sh" "$@"; }
wificonnect() { sudo bash "$REALHOME/wifi.sh" "$@"; }
kiauh() { "$REALHOME/kiauh/kiauh.sh" "$@"; }
shortcuts() { nano "$REALHOME/.bash_aliases"; }

#############################################
#              Search & History             #
#############################################

f() { find . -iname "$@"; }
sf() { sudo find / -iname "$@"; }
sudof() { sudo find / -iname "$@"; }
h() { history | grep "$@"; }
please() { sudo $(history -p !!); }

# COLORIZED & SEARCHABLE ALIASES
aliases() {
  local search_term="$1"

  # 1. Extract TYPE:NAME as a single field so column won't split it
  awk -v search="$search_term" '
    { sub(/^[ \t]+/, "") }

    /^alias / {
      sub(/^alias /, "")
      split($0, a, "=")
      name = a[1]
      if (!search || name ~ search)
        print "A:" name
    }

    /^[a-zA-Z0-9_]+\(\)/ {
      split($0, a, "(")
      name = a[1]
      if (!search || name ~ search)
        print "F:" name
    }
  ' "$REALHOME/.bash_aliases" \
  | sort \
  | column -x -c "$(tput cols)" \
  | awk '
      BEGIN {
        CYAN = "\033[1;36m"
        BLUE = "\033[1;34m"
        RESET = "\033[0m"
      }

      {
        line = $0

        # Colorize prefixes only
        gsub(/A:/, CYAN "A:" RESET, line)
        gsub(/F:/, BLUE "F:" RESET, line)

        print line
      }
    '
}



#############################################
#              Disk Usage Tools             #
#############################################

duh() { du -sh ./* 2>/dev/null | sort -h; }

topdirs() {
    local NUM="${1:-10}"
    local TARGET="${2:-.}"
    sudo du -xh --max-depth=1 "$TARGET" 2>/dev/null | sort -h | tail -n "$NUM"
}

#############################################
#            Custom Environment             #
#############################################

export EDITOR=nano
export VISUAL=nano