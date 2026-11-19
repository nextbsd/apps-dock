#!/bin/sh
# The Dock is never at the top in the Mac menu style, live on WindowServer.
#
# Every menu style (nextstep, inwindow, macmenubar), window mode
# (stacking, tiling: each with its own NBModeSettings menu style and Dock
# position), saved Dock position (left, bottom, right, top), and the
# changes between each (mode, style) and every other one and back. After
# each change it checks the Dock's edge (wsctl list, against wsctl
# screen) and that the saved NBModeSettings are as written: the Dock
# never rewrites them. A saved top is the bottom in the Mac style and the
# top again in the other styles.
#
# Run it as the session's user, with the Dock (and Workspace) running.
# It changes NBWindowMode, NBModeSettings and WindowServer's WindowMode,
# which tiles and untiles the windows on screen, and puts them all back
# at the end (also on ^C).
#
#   sh Tests/live-no-top-dock.sh            all positions (about 10 min)
#   QUICK=1 sh Tests/live-no-top-dock.sh    stacking=top, tiling=left only
#   sh Tests/live-no-top-dock.sh --relaunch also start the Dock afresh in
#                                           each mode and style (only from
#                                           a Terminal in the login
#                                           session, so the new Dock
#                                           belongs to it)
#
# The Placement pop-ups (the Dock's Settings and Workspace Preferences)
# are covered headless by Tests/run-no-top-dock.sh here and by
# apps-workspace's Tests/no-top-dock.sh.

set -u

. /System/Library/Makefiles/GNUstep.sh 2>/dev/null || true
WSCTL=${WSCTL:-/usr/libexec/WindowServer/wsctl}
POSTDS=${POSTDS:-$HOME/src/postds/obj/postds}
DOCK_APP=${DOCK_APP:-$HOME/Applications/Dock.app/Dock}
SETTLE=${SETTLE:-1.5}
RELAUNCH=0
[ "${1:-}" = "--relaunch" ] && RELAUNCH=1

for tool in "$WSCTL" "$POSTDS"; do
	[ -x "$tool" ] || { echo "missing $tool" >&2; exit 2; }
done
command -v defaults >/dev/null || { echo "no defaults tool" >&2; exit 2; }

pass=0
fail=0
LOG=$(mktemp /tmp/live-no-top-dock.XXXXXX)
echo "log: $LOG"

# ---- the settings as they were, put back at the end ----

read_value() {	# DOMAIN KEY: the value as `defaults write` takes it, or empty
	out=$(defaults read "$1" "$2" 2>/dev/null) || return 0
	out=${out#"$1 $2 "}
	out=${out#\'}
	out=${out%\'}
	printf '%s' "$out"
}

ORIG_MODES=$(read_value NSGlobalDomain NBModeSettings)
ORIG_MODE=$(read_value NSGlobalDomain NBWindowMode)
ORIG_WS_MODE=$(read_value org.nextbsd.WindowServer WindowMode)
echo "saved: NBWindowMode=${ORIG_MODE:-(none)} WindowServer WindowMode=${ORIG_WS_MODE:-(none)}" | tee -a "$LOG"
echo "saved: NBModeSettings=${ORIG_MODES:-(none)}" | tee -a "$LOG"

restore() {
	trap - EXIT INT TERM HUP
	echo "putting the settings back" | tee -a "$LOG"
	if [ -n "$ORIG_MODES" ]; then
		defaults write NSGlobalDomain NBModeSettings "$ORIG_MODES"
	else
		defaults delete NSGlobalDomain NBModeSettings 2>/dev/null
	fi
	if [ -n "$ORIG_MODE" ]; then
		defaults write NSGlobalDomain NBWindowMode "$ORIG_MODE"
	else
		defaults delete NSGlobalDomain NBWindowMode 2>/dev/null
	fi
	ws=${ORIG_WS_MODE:-${ORIG_MODE:-stacking}}
	[ -n "$ORIG_WS_MODE" ] && defaults write org.nextbsd.WindowServer WindowMode "$ORIG_WS_MODE"
	"$WSCTL" settings set WindowMode "$ws" >/dev/null 2>&1
	"$POSTDS"
	sleep "$SETTLE"
	echo "Dock now: $(dock_edge)" | tee -a "$LOG"
}
trap restore EXIT
trap 'exit 130' INT TERM HUP

# ---- what the Dock does ----

# The Dock's edge from its "AppsDock" window: across the screen's
# middle (so a left or right Dock on another display still counts),
# horizontal ones top or bottom, vertical ones left or right. Prints
# "EDGE x,y,WxH menubar=N".
dock_edge() {
	scr=$("$WSCTL" screen 2>/dev/null)
	sw=$(printf '%s\n' "$scr" | sed -n 's/^screen \([0-9]*\)x\([0-9]*\).*/\1/p')
	sh_=$(printf '%s\n' "$scr" | sed -n 's/^screen \([0-9]*\)x\([0-9]*\).*/\2/p')
	mb=$(printf '%s\n' "$scr" | sed -n 's/^menubar \([0-9]*\).*/\1/p')
	f=$("$WSCTL" list 2>/dev/null | grep ' Dock ' | grep '"AppsDock"' | head -1 |
	    sed -n 's/.*frame=\(-*[0-9]*\),\(-*[0-9]*\),\([0-9]*\)x\([0-9]*\).*/\1 \2 \3 \4/p')
	[ -n "$f" ] || { echo "none"; return; }
	set -- $f
	if [ "$3" -gt "$4" ]; then
		if [ $(($2 + $4 / 2)) -lt $((sh_ / 2)) ]; then e=top; else e=bottom; fi
	else
		if [ $(($1 + $3 / 2)) -lt $((sw / 2)) ]; then e=left; else e=right; fi
	fi
	echo "$e $1,$2,$3x$4 menubar=${mb:-?}"
}

expected_edge() {	# POSITION STYLE
	if [ "$1" = top ] && [ "$2" = macmenubar ]; then echo bottom; else echo "$1"; fi
}

modes_plist() {	# SSTYLE SPOS TSTYLE TPOS
	echo "{stacking = {NBMenuStyle = $1; NBDockPosition = $2;}; tiling = {NBMenuStyle = $3; NBDockPosition = $4;};}"
}

normalize() { tr -d ' \t\n"' ; }

# apply MODE SSTYLE SPOS TSTYLE TPOS: as Workspace Preferences would.
apply() {
	defaults write NSGlobalDomain NBModeSettings "$(modes_plist "$2" "$3" "$4" "$5")"
	defaults write NSGlobalDomain NBWindowMode "$1"
	defaults write org.nextbsd.WindowServer WindowMode "$1"
	"$WSCTL" settings set WindowMode "$1" >/dev/null 2>&1
	"$POSTDS"
	sleep "$SETTLE"
}

# check LABEL MODE SSTYLE SPOS TSTYLE TPOS
check() {
	label=$1; mode=$2
	if [ "$mode" = stacking ]; then style=$3; pos=$4; else style=$5; pos=$6; fi
	want=$(expected_edge "$pos" "$style")
	got=$(dock_edge)
	saved=$(read_value NSGlobalDomain NBModeSettings | normalize)
	wrote=$(modes_plist "$3" "$4" "$5" "$6" | normalize)
	ok=1
	[ "${got%% *}" = "$want" ] || ok=0
	# Saved positions survive: compare the Dock positions only (the
	# order of keys in `defaults read` may differ).
	sp=$(printf '%s' "$saved" | sed -n 's/.*stacking={\([^}]*\)}.*/\1/p')
	tp=$(printf '%s' "$saved" | sed -n 's/.*tiling={\([^}]*\)}.*/\1/p')
	case "$sp" in *NBDockPosition=$4\;*) ;; *) ok=0 ;; esac
	case "$tp" in *NBDockPosition=$6\;*) ;; *) ok=0 ;; esac
	case "$sp" in *NBMenuStyle=$3\;*) ;; *) ok=0 ;; esac
	case "$tp" in *NBMenuStyle=$5\;*) ;; *) ok=0 ;; esac
	line="$label | $mode style=$style saved=$pos -> want $want, Dock $got"
	if [ $ok = 1 ]; then
		pass=$((pass + 1)); echo "ok   $line" >>"$LOG"
	else
		fail=$((fail + 1)); echo "FAIL $line | saved now $saved (wrote $wrote)" | tee -a "$LOG"
	fi
}

rot() {	# the next position round: left bottom right top
	case $1 in left) echo bottom ;; bottom) echo right ;; right) echo top ;; *) echo left ;; esac
}

STYLES="nextstep inwindow macmenubar"
MODES="stacking tiling"
if [ "${QUICK:-0}" = 1 ]; then POSITIONS=top; else POSITIONS="left bottom right top"; fi

[ "$(dock_edge)" != none ] || { echo "no Dock window in wsctl list" >&2; exit 2; }

# ---- every (mode, style) to every other one, and back ----

for p in $POSITIONS; do
	q=$(rot "$p")	# tiling's own position, never the same as stacking's
	echo "== stacking=$p tiling=$q" | tee -a "$LOG"
	for m1 in $MODES; do for s1 in $STYLES; do
	for m2 in $MODES; do for s2 in $STYLES; do
		[ "$m1$s1" = "$m2$s2" ] && continue
		# Both configurations: the style of each mode in each.
		if [ "$m1" = "$m2" ]; then
			other=nextstep
			if [ "$m1" = stacking ]; then
				a="$s1 $p $other $q"; b="$s2 $p $other $q"
			else
				a="$other $p $s1 $q"; b="$other $p $s2 $q"
			fi
		else
			if [ "$m1" = stacking ]; then
				a="$s1 $p $s2 $q"
			else
				a="$s2 $p $s1 $q"
			fi
			b=$a
		fi
		apply "$m1" $a; check "from      $m1/$s1" "$m1" $a
		apply "$m2" $b; check "to        $m2/$s2" "$m2" $b
		apply "$m1" $a; check "back from $m2/$s2" "$m1" $a
	done; done
	done; done
	echo "   so far: $pass ok, $fail failed" | tee -a "$LOG"
done

# ---- at launch ----

in_session() {	# is this shell a descendant of loginwindow?
	pid=$$
	while [ "$pid" -gt 1 ] 2>/dev/null; do
		cmd=$(ps -o command= -p "$pid" 2>/dev/null)
		case "$cmd" in *loginwindow.app/loginwindow*) return 0 ;; esac
		pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
		[ -n "$pid" ] || return 1
	done
	return 1
}

relaunch_dock() {
	pkill -TERM -U "$(id -u)" -x Dock
	n=0
	while pgrep -U "$(id -u)" -x Dock >/dev/null && [ $n -lt 20 ]; do sleep 0.5; n=$((n + 1)); done
	pkill -KILL -U "$(id -u)" -x Dock 2>/dev/null
	nohup "$DOCK_APP" >>"$HOME/Library/Logs/LoginWindowSession.log" 2>&1 &
	n=0
	while [ "$(dock_edge)" = none ] && [ $n -lt 30 ]; do sleep 0.5; n=$((n + 1)); done
	sleep 2
}

if [ $RELAUNCH = 1 ]; then
	if ! in_session; then
		echo "--relaunch: not in the login session (run it from a Terminal" \
		    "opened in the session); launch checks skipped" | tee -a "$LOG"
	else
		for m in $MODES; do for s in $STYLES; do for p in top left; do
			q=$(rot "$p")
			if [ "$m" = stacking ]; then c="$s $p nextstep $q"; else c="nextstep $q $s $p"; fi
			apply "$m" $c
			relaunch_dock
			check "launch    $m/$s" "$m" $c
		done; done; done
	fi
fi

echo "$pass ok, $fail failed (log $LOG)"
[ $fail = 0 ]
