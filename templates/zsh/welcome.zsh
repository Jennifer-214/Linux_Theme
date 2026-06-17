# ─── Welcome splash ───────────────────────────

function _caramel_welcome() {
  local c1='\e[38;5;{{ANSI_ACCENT1}}m'    # clay
  local c2='\e[38;5;{{ANSI_ACCENT2}}m'    # wheat
  local c3='\e[38;5;{{ANSI_ACCENT3}}m'    # dusty mauve
  local c4='\e[38;5;{{ANSI_ACCENT4}}m'    # sage
  local DM='\e[2;38;5;{{ANSI_ACCENT1}}m'  # dim clay
  local O='\e[0m'

  # Name banner — the welcome_banner install module rewrites the block below
  # from the user's chosen text (default FOX OS). bw is the
  # banner's column span, used to right-anchor it next to the cat.
  # foxml:welcome-banner-begin
  local bw=28
  local b1="${c1}█▀▀${O} ${c2}█▀█${O} ${c3}▀▄▀${O} ${c4}  ${O} ${c1}█▀█${O} ${c2}▄▀▀${O}"
  local b2="${c1}█▀ ${O} ${c2}█ █${O} ${c3} █ ${O} ${c4}  ${O} ${c1}█ █${O} ${c2} ▀▄${O}"
  local b3="${c1}▀  ${O} ${c2}▀▀▀${O} ${c3}▀ ▀${O} ${c4}  ${O} ${c1}▀▀▀${O} ${c2}▀▀ ${O}"
  # foxml:welcome-banner-end

  # Right column position for name banner
  local rc=$((COLUMNS - bw))
  (( rc < 50 )) && rc=50
  local drc=$((rc + 4))

  # Date column — anchored absolutely so the day name and date line up
  # regardless of which row of the cat they share. The cat uses
  # full-width Japanese characters (˚ ˎ 。 、 〵 じ し ノ) that take
  # 2 visual columns each but only 1 width-unit to `echo`, so
  # fixed-space padding produces different visual offsets per row.
  # Bumped from 22 → 25: some fonts render the cat ASCII slightly
  # wider than spec (full-width treatment of `˚`/`ˎ` modifier letters),
  # and a 25-column anchor leaves enough buffer that the date never
  # collides with the cat tail no matter how the font expands the
  # CJK + diacritic chars.
  local dc=25

  local dots="\e[38;5;{{ANSI_ACCENT3}}m●${O} \e[38;5;{{ANSI_ACCENT2}}m●${O} \e[38;5;{{ANSI_ACCENT1}}m●${O} \e[38;5;{{ANSI_ACCENT4}}m●${O} \e[38;5;{{ANSI_ACCENT5}}m●${O} \e[38;5;{{ANSI_ACCENT2}}m●${O} \e[38;5;{{ANSI_ACCENT3}}m●${O} \e[38;5;{{ANSI_ACCENT1}}m●${O}"

  # Nicer date/time
  local dow=$(date '+%A')
  local mon=$(date '+%B')
  local dom=$(date '+%-d')
  local hr=$(date '+%-I')
  local min=$(date '+%M')
  local ap=$(date '+%p' | tr '[:upper:]' '[:lower:]')

  echo ""
  if [[ "{{SHOW_WELCOME}}" == "true" ]]; then
    echo -e "         ${c1}/\\_/\\ ${O}\e[${rc}G${b1}"
    echo -e "        ${c1}(${c3}˚${c1}ˎ ${c3}。${c1}7${O}\e[${dc}G${c1}${dow}${O}\e[${rc}G${b2}"
    echo -e "         ${c1}|、${c3}^${c1} 〵${O}\e[${dc}G${c2}${mon} ${dom}${O} ${DM}·${O} ${c4}${hr}:${min} ${ap}${O}\e[${rc}G${b3}"
    echo -e "         ${c1}じし${c3}ˍ${c1},)ノ${O}${theme_tag}\e[${drc}G${dots}"
  else
    echo -e "         ${c1}/\\_/\\ ${O}"
    echo -e "        ${c1}(${c3}˚${c1}ˎ ${c3}。${c1}7${O}\e[${dc}G${c1}${dow}${O}"
    echo -e "         ${c1}|、${c3}^${c1} 〵${O}\e[${dc}G${c2}${mon} ${dom}${O} ${DM}·${O} ${c4}${hr}:${min} ${ap}${O}"
    echo -e "         ${c1}じし${c3}ˍ${c1},)ノ${O}${theme_tag}"
  fi

  # Todo items (max 3, only if ~/.todo exists and has content)
  if [[ -s ~/.todo ]]; then
    local sep="${DM}──────────────────────────${O}"
    echo -e "                  ${sep}"
    local i=0
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      (( i++ ))
      (( i > 3 )) && break
      echo -e "                  ${DM} ◇${O} ${c4}${line}${O}"
    done < ~/.todo
  fi

  # Random quote — blank + # comment lines ignored; empty/missing file prints nothing
  local qf="$HOME/.config/zsh/quotes.txt"
  if [[ -r "$qf" ]]; then
    local -a quotes
    quotes=("${(@f)$(<$qf)}")     # builtin file read, split on newlines
    quotes=(${quotes:#})          # drop blank lines
    quotes=(${quotes:#\#*})       # drop # comment lines
    (( ${#quotes} )) && echo -e "                  ${c4}${quotes[RANDOM%${#quotes}+1]}${O}"
  fi
  echo ""
}

# ─── Todo helpers ─────────────────────────────
todo() {
  [[ -z "$1" ]] && { [[ -s ~/.todo ]] && nl -ba ~/.todo || echo "nothing to do"; return; }
  if [[ -f ~/.todo ]] && grep -qxF "$*" ~/.todo; then
    echo "already on the list: $*"
    return
  fi
  echo "$*" >> ~/.todo
  echo "added: $*"
}

todone() {
  [[ ! -s ~/.todo ]] && { echo "nothing to do"; return; }
  if [[ -z "$1" ]]; then
    sed -i '1d' ~/.todo
  elif [[ "$1" =~ ^[0-9]+$ ]]; then
    sed -i "${1}d" ~/.todo
  fi
  [[ ! -s ~/.todo ]] && rm -f ~/.todo
  echo "done!"
}

todos() {
  [[ -s ~/.todo ]] && nl -ba ~/.todo || echo "nothing to do"
}

# ─── Seed quotes on first run — never clobbers; empty the file to disable (deleting re-seeds) ───
if [[ ! -e "$HOME/.config/zsh/quotes.txt" ]]; then
  mkdir -p "$HOME/.config/zsh"
  cat > "$HOME/.config/zsh/quotes.txt" <<'QUOTES'
The unconscious is structured like a language. — Lacan
Desire is the desire of the Other. — Lacan
Love is giving something you don't have to someone who doesn't want it. — Lacan
There is no sexual relationship. — Lacan
The woman does not exist. — Lacan
I always speak the truth — not the whole truth, because there's no way to say it all. — Lacan
The unconscious is the discourse of the Other. — Lacan
Anxiety is that which does not deceive. — Lacan
The real is what resists symbolization absolutely. — Lacan
The real is the impossible. — Lacan
The real is that which always returns to the same place. — Lacan
There is no Other of the Other. — Lacan
QUOTES
fi

[[ "{{SHOW_WELCOME}}" == "true" ]] && _caramel_welcome
