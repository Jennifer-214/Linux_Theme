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
# ── Branchless & bit-twiddling ──
Branchless min(a,b): b ^ ((a ^ b) & -(a < b)) — no jump, nothing to mispredict.
x & (x - 1) clears the lowest set bit — Kernighan's trick counts bits in one step per one.
x & -x isolates the lowest set bit; it's the heartbeat of the Fenwick tree.
Branchless abs: with m = x >> 31, the answer is (x ^ m) - m. Sign extension does the work.
Two's complement makes -x just ~x + 1, so arithmetic and bit masks compose for free.
XOR swap needs no temporary: a ^= b; b ^= a; a ^= b — just never let a and b alias.
Is x a power of two? x && !(x & (x - 1)) — exactly one bit set.
x | (x + 1) sets the lowest clear bit — the mirror of x & (x - 1).
Branchless sign: (x > 0) - (x < 0) yields -1, 0, or +1 with no branch.
Opposite signs? (a ^ b) < 0 is true exactly when a and b disagree on the sign bit.
Floor average without overflow: (a & b) + ((a ^ b) >> 1) — no a + b to overflow.
Modulo a power of two is just a mask: x & (n - 1) when n is 2^k.
Binary to Gray code: x ^ (x >> 1) — consecutive values differ by a single bit.
popcount and count-trailing-zeros are each a single instruction now (POPCNT, TZCNT); they used to be loops.
Set / clear / toggle / test bit n: x | (1<<n), x & ~(1<<n), x ^ (1<<n), (x>>n) & 1.
Multiplying or dividing by a power of two is just << or >> — the compiler already knows.
# ── Mechanical sympathy ──
An L1 cache hit is about 4 cycles; a trip to main memory is hundreds. The whole game is staying close.
A mispredicted branch costs ~15-20 cycles; a predicted one is nearly free. Branchless code buys certainty.
Branch predictors are tiny learners in silicon, guessing your code's future millions of times a second.
Floating point isn't associative: (a+b)+c is not a+(b+c). Fixed-point keeps the books exact.
NOP does nothing on purpose — alignment, timing, and hot-patching all lean on it.
# ── Neat history ──
The first computer "bug" was literal: a moth taped into Harvard's Mark II logbook, 1947.
Grace Hopper handed out "nanoseconds" — 11.8-inch wires, how far light travels in one.
# ── Aphorisms ──
There are only two hard things in computer science: cache invalidation and naming things. — Phil Karlton
Make it work, make it right, make it fast. — Kent Beck
Premature optimization is the root of all evil. — Donald Knuth
You don't have to be an engineer to drive fast — but you do to drive an F1 car. — Jackie Stewart
The fastest code is the code that never runs.
Simplicity is prerequisite for reliability. — Edsger Dijkstra
Testing shows the presence, not the absence, of bugs. — Edsger Dijkstra
Debugging is twice as hard as writing the code in the first place. — Brian Kernighan
Programs must be written for people to read, and only incidentally for machines to execute. — Abelson & Sussman, SICP
Talk is cheap. Show me the code. — Linus Torvalds
Given enough eyeballs, all bugs are shallow. — Linus's Law
The cheapest, fastest, and most reliable components are those that aren't there. — Gordon Bell
When in doubt, use brute force. — Ken Thompson
Deleted code is debugged code.
QUOTES
fi

[[ "{{SHOW_WELCOME}}" == "true" ]] && _caramel_welcome
