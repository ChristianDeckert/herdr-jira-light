# Renders Jira wiki markup (descriptions, comments) for the terminal: headings, lists, code, quote and
# table blocks, and inline bold, monospace, links, mentions and images. Uses the caller's B D R K colors.
: ${B:=$'\e[1m'} ${D:=$'\e[2m'} ${R:=$'\e[0m'} ${K:=$'\e[35m'}
JL_UL=$'\e[4m' JL_CODE=$'\e[36m'

jl_vlen() { # text -> REPLY visible length
  setopt local_options extended_glob
  REPLY=${#${(S)1//$'\e'\[[0-9;]#m/}}
}

# Appends the text word-wrapped to MARKUP. The first line starts with one prefix, the others with the
# second (same visible width keeps list items aligned). Plain words longer than a line are cut.
jl_wrap_into() { # width text first-prefix next-prefix
  local w=$1 word cur=$3 curlen wl nlen room started=0
  jl_vlen "$3"; curlen=$REPLY
  jl_vlen "$4"; nlen=$REPLY
  for word in ${=2}; do
    jl_vlen "$word"; wl=$REPLY
    if (( started && curlen + 1 + wl > w )); then
      MARKUP+=("$cur$R"); cur=$4 curlen=$nlen started=0
    fi
    while (( ! started && curlen + wl > w && w - curlen > 0 )) && [[ $word != *$'\e'* ]]; do
      room=$(( w - curlen ))
      MARKUP+=("$cur${word[1,room]}"); word=${word[room+1,-1]} wl=${#word} cur=$4 curlen=$nlen
    done
    if (( started )); then cur+=" $word"; (( curlen += 1 + wl ))
    else cur+=$word; (( curlen += wl )); started=1
    fi
  done
  (( started )) && MARKUP+=("$cur$R")
}

jl_inline() { # text -> REPLY
  setopt local_options extended_glob
  local s=$1
  s=${s//\{color[^\}]#\}/}
  s=${s//\\\\/ }
  s=${s//(#b)\{\{([^\}]##)\}\}/$JL_CODE${match[1]}$R}
  s=${s//(#b)\[\~([^\]]##)\]/$K@${match[1]}$R}
  s=${s//(#b)\[([^\]|]##)\|([^\]]##)\]/$JL_UL${match[1]}$R}
  s=${s//(#b)\[((http|https|mailto):[^\]]##)\]/$JL_UL${match[1]}$R}
  s=${s//(#b)\!([^!|[:space:]]##)(\|[^!]#)#\!/${D}[${match[1]}]$R}
  s=${s//(#b)((#s)|[[:space:](])\*([^*[:space:]]|[^*[:space:]][^*]#[^*[:space:]])\*/${match[1]}$B${match[2]}$R}
  REPLY=$s
}

# Appends the rendered text to MARKUP, wrapped to width.
jl_markup() { # width text
  setopt local_options extended_glob
  local w=$1 line block="" marks depth bullet pre next joined c
  local -a num=(0 0 0 0 0 0 0 0) cells
  for line in "${(@f)2}"; do
    line=${line%$'\r'}
    if [[ -n $block ]]; then
      if [[ $line == *"{$block}"* ]]; then block=""; continue; fi
      if [[ $block == quote ]]; then jl_inline "$line"; jl_wrap_into $w "$REPLY" "$D│$R " "$D│$R "
      else MARKUP+=("$D│$R $JL_CODE$line$R")
      fi
      continue
    fi
    [[ $line == [[:space:]]#(\*##|\###|-)[[:space:]]* ]] || num=(0 0 0 0 0 0 0 0)
    case $line in
      [[:space:]]#\{(code|noformat)*\}*)
        block=${${line##[[:space:]]#\{}%%[:\}]*}
        line=${line#*\}}
        if [[ $line == *"{$block}"* ]]; then MARKUP+=("$D│$R $JL_CODE${line%%\{$block\}*}$R"); block=""
        elif [[ -n ${line//[[:space:]]/} ]]; then MARKUP+=("$D│$R $JL_CODE$line$R")
        fi ;;
      [[:space:]]#\{quote\}*)
        block=quote line=${line#*\{quote\}}
        [[ -n ${line//[[:space:]]/} ]] && { jl_inline "$line"; jl_wrap_into $w "$REPLY" "$D│$R " "$D│$R " } ;;
      h[1-6].\ *)
        [[ -n $MARKUP[-1] ]] && (( ${#MARKUP} )) && MARKUP+=("")
        jl_inline "${line#h[1-6]. }"; jl_wrap_into $w "$B$K${REPLY//$R/$R$B$K}" "" "" ;;
      bq.\ *) jl_inline "${line#bq. }"; jl_wrap_into $w "$REPLY" "$D│$R " "$D│$R " ;;
      [[:space:]]#----[-]#[[:space:]]#) MARKUP+=("$D${(l:w::─:)}$R") ;;
      [[:space:]]#(\*##|\###|-)[[:space:]]*)
        line=${line##[[:space:]]#}
        marks=${line%%[[:space:]]*} line=${line#$marks}
        depth=${#marks}; [[ $marks == - ]] && depth=1
        (( depth > 8 )) && depth=8
        pre="${(l:(depth - 1) * 2:: :)}"
        if [[ $marks[-1] == \# ]]; then
          (( num[depth]++ )); num[depth+1,-1]=(0 0 0 0 0 0 0 0); num=(${num[1,8]})
          bullet="$num[depth]."
        else
          (( depth % 2 )) && bullet="•" || bullet="◦"
          num[depth,-1]=(0 0 0 0 0 0 0 0); num=(${num[1,8]})
        fi
        next="$pre${(l:${#bullet} + 1:: :)}"
        jl_inline "${line##[[:space:]]#}"; jl_wrap_into $w "$REPLY" "$pre$K$bullet$R " "$next" ;;
      [[:space:]]#\|*)
        line=${line##[[:space:]]#}
        cells=("${(@s:|:)line}")
        cells=(${cells:#}) # empty cells are the separators of || headers
        if [[ $line == \|\|* ]]; then pre=$B; else pre=""; fi
        joined=""
        for c in $cells; do jl_inline "${c## #}"; joined+="${joined:+ $D│$R }$pre${REPLY%% #}$R"; done
        jl_wrap_into $w "$joined" "" "" ;;
      [[:space:]]#)
        (( ${#MARKUP} )) && [[ -n $MARKUP[-1] ]] && MARKUP+=("") ;;
      *) jl_inline "$line"; jl_wrap_into $w "$REPLY" "" "" ;;
    esac
  done
  while (( ${#MARKUP} )) && [[ -z $MARKUP[-1] ]]; do MARKUP[-1]=(); done
}
