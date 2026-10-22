# Wi-Fi debugging for a physical Android phone: connect, pair, qr, lock, usb, status (skiprun android <word>).

wifi_locked_file() { print -r -- "$(state_home)/locked-endpoint" }

# `adb connect` exits 0 on failure: verify against `adb devices` and keep adb's text
# in WIFI_CONNECT_ERR, the only clue why it failed.
wifi_connect_once() {
  local conn=$1
  # A cold daemon fails the first connect with `protocol fault` whatever the phone does.
  "$ADB" start-server >/dev/null 2>&1
  WIFI_CONNECT_ERR=$("$ADB" connect "$conn" 2>&1)
  case "$("$ADB" devices)" in
    *"$conn"*offline*) "$ADB" reconnect offline >/dev/null 2>&1; sleep 1 ;;
  esac
  "$ADB" devices | awk -v target="$conn" '$1 == target && $2 == "device" { found = 1 } END { exit !found }'
}

# Android closes the listener and picks a new port when the Wireless debugging screen
# closes or the phone dozes; on a refused port re-resolve instead of failing on a dead one.
wifi_connect_retry() {
  local conn=$1 tries=${2:-3} fresh="" attempt
  for attempt in $(seq 1 $tries); do
    if wifi_connect_once "$conn"; then
      WIFI_CONN_ADDR=$conn
      return 0
    fi
    # Only an errno means "the port moved"; a bare "failed to connect" is a rejected
    # TLS handshake (the phone dropped this host's pairing) that no port-chasing fixes.
    case $WIFI_CONNECT_ERR in
      *"Connection refused"*|*"onnection reset"*) ;;
      *) break ;;
    esac
    (( attempt == tries )) && break
    warn "$conn refused the connection — the phone re-numbered its port. Re-resolving..."
    fresh=$(wifi_mdns "_adb-tls-connect._tcp" 8)
    [[ -z $fresh ]] && { warn "the phone is no longer advertising a connect port"; break }
    [[ $fresh == "$conn" ]] && print -r -- "   (mDNS still says $fresh — likely a stale cache entry)"
    conn=$fresh
  done
  WIFI_CONN_ADDR=$conn
  return 1
}

wifi_diagnose() {
  local conn=$1
  print -r -- "❌ Could not connect to $conn." >&2
  [[ -n $WIFI_CONNECT_ERR ]] && print -r -- "   adb said: $WIFI_CONNECT_ERR" >&2
  case $WIFI_CONNECT_ERR in
    *"Connection refused"*)
      cat >&2 <<MSG
   → The phone answered but nothing listens on that port. Pairing is NOT the
     problem: Android closes the wireless-debug port when the Wireless debugging
     screen closes or the phone dozes.
   Fix: open Developer options → Wireless debugging, LEAVE IT OPEN, enable
        'Stay awake', then: skiprun android connect
        If the screen IS open and shows THIS port, adbd is stuck: toggle
        Wireless debugging off/on, or reboot the phone.
MSG
      ;;
    *"No route to host"*|*"Operation timed out"*|*"timeout"*)
      print -r -- "   → The phone is not reachable at all (other Wi-Fi, or AP/client isolation)." >&2
      print -r -- "   Fix: same Wi-Fi, the phone's hotspot, or a cable: skiprun android usb" >&2
      ;;
    *"failed to authenticate"*|*"device unauthorized"*)
      print -r -- "   → Reached and listening, but this host is not trusted: skiprun android pair (or qr)" >&2
      ;;
    *"protocol fault"*)
      print -r -- "   → Local adb daemon glitch, not the phone: adb kill-server, then skiprun android connect" >&2
      ;;
    *"failed to connect"*)
      if nc -z -w 2 "${conn%:*}" "${conn##*:}" >/dev/null 2>&1; then
        print -r -- "   → The port IS open but the phone rejected the TLS handshake: it no longer" >&2
        print -r -- "     trusts this host (a reboot can drop the pairing). Re-pair: skiprun android qr" >&2
      else
        print -r -- "   → The listener is gone (screen closed / phone dozed). Reopen the Wireless" >&2
        print -r -- "     debugging screen and retry: skiprun android connect" >&2
      fi
      ;;
    *)
      if wifi_is_paired; then
        print -r -- "   → This host is already paired, so re-pairing will not help. Try the cable: skiprun android usb" >&2
      else
        print -r -- "   → Never paired on this network (or after a factory reset): skiprun android pair" >&2
        print -r -- "     If pairing keeps failing on this Wi-Fi: skiprun android usb" >&2
      fi
      ;;
  esac
  "$ADB" devices | grep -q "$conn.*offline" && print -r -- "   Note: the device shows 'offline' — try: adb reconnect offline" >&2
  return 1
}

# Pairing is a persistent record in adb_known_hosts.pb keyed by the phone's guid; it
# survives reboots and port changes, which separates "trusted but unreachable" from "never paired".
wifi_is_paired() {
  local hosts=$HOME/.android/adb_known_hosts.pb
  [[ -s $hosts ]] || return 1
  if [[ -n $1 ]]; then
    strings "$hosts" 2>/dev/null | grep -q "$1"
  else
    strings "$hosts" 2>/dev/null | grep -q '^adb-'
  fi
}

# After a pair, watch mDNS and connect the moment the phone advertises its connect port:
# pair and connect are two ports and `adb pair` never reveals the second.
wifi_await_connect() {
  local guid=$1 wait=${2:-30} conn=""
  print -r -- "⏳ Paired. Waiting up to ${wait}s for the phone to advertise its connect port..."
  for _ in $(seq 1 $(( (wait + 4) / 5 ))); do
    conn=$(wifi_mdns "_adb-tls-connect._tcp" 1)
    if [[ -n $conn ]] && wifi_connect_once "$conn"; then
      WIFI_CONN_ADDR=$conn
      ok "Connected ($conn). Now: skiprun android --device"
      print -r -- "   Tip: skiprun android lock pins a fixed port that survives screen-off (until reboot)."
      return 0
    fi
  done
  print
  if wifi_is_paired "$guid"; then
    ok "Pairing is STORED${guid:+ ($guid)} — do NOT pair again."
  fi
  cat <<MSG
⚠️  But the phone never advertised a connect port over mDNS in ${wait}s.
   Usual causes: the phone dozed / the Wireless debugging screen closed, or this
   Wi-Fi blocks mDNS between devices.

   Do this: Developer options → enable 'Stay awake', open 'Wireless debugging'
   and LEAVE IT ON SCREEN. It shows 'IP address & Port' at the top — that is the
   CONNECT port (not the pairing one). Enter it here, or press Enter to skip.
MSG
  print -n -- "   CONNECT IP:PORT (Enter = skip): "; read -r conn
  [[ -z $conn ]] && { print -r -- "   Skipped. The cable route needs neither mDNS nor pairing: skiprun android usb"; return 1 }
  if wifi_connect_retry "$conn"; then
    ok "Connected ($WIFI_CONN_ADDR). Now: skiprun android --device"
    return 0
  fi
  wifi_diagnose "$WIFI_CONN_ADDR"
}

# dns-sd never exits on its own: run it for a fixed window and kill it by PID (pkill -f
# would match the substring anywhere, including an unrelated dns-sd).
wifi_dnssd() {
  local out=$1 window=$2; shift 2
  (dns-sd "$@" > "$out" 2>/dev/null & print $! > "$out.pid")
  sleep "$window"
  kill "$(cat "$out.pid" 2>/dev/null)" 2>/dev/null
  rm -f "$out.pid"
}

# adb hands a `.local` name to getaddrinfo and takes the first answer, link-local IPv6 on a
# dual-stack phone, then dies with "No route to host" against an open port. Resolve to IPv4.
wifi_ipv4() {
  local host=${1%.}
  case $host in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) print -r -- "$host"; return 0 ;;
  esac
  local ip; ip=$(dscacheutil -q host -a name "$host" 2>/dev/null | awk -F': ' '/^ip_address/ { print $2; exit }')
  [[ -z $ip ]] && ip=$(ping -c 1 -t 1 "$host" 2>/dev/null | sed -n '1s/.*(\([0-9.]*\)).*/\1/p')
  [[ -n $ip ]] && { print -r -- "$ip"; return 0 }
  return 1
}

# Resolve a service through macOS dns-sd, not `adb mdns services` (adb's backend misses live
# advertisements and serves dead cached ports). Every candidate is TCP-probed before it is returned.
wifi_mdns() {
  local service=$1 tries=${2:-1}
  local scratch=${${TMPDIR:-/tmp}%/}/skiprun-mdns.$$ name="" hostport="" hit="" ip=""
  for _ in $(seq 1 $tries); do
    wifi_dnssd "$scratch" 2 -B "$service" local.
    name=$(awk '/ Add /{ name = $NF } END { print name }' "$scratch")
    if [[ -n $name ]]; then
      wifi_dnssd "$scratch" 2 -L "$name" "$service" local.
      hostport=$(grep -oE "at [^ ]+:[0-9]+" "$scratch" | head -n 1 | cut -d' ' -f2)
      if [[ -n $hostport ]]; then
        ip=$(wifi_ipv4 "${hostport%:*}")
        if [[ -n $ip ]] && nc -z -w 1 "$ip" "${hostport##*:}" >/dev/null 2>&1; then
          rm -f "$scratch"
          print -r -- "$ip:${hostport##*:}"
          return 0
        fi
      fi
    fi
    hit=$("$ADB" mdns services 2>/dev/null | grep "$service" | grep -oE "[0-9.]+:[0-9]+" | head -n 1)
    if [[ -n $hit ]] && nc -z -w 1 "${hit%:*}" "${hit##*:}" >/dev/null 2>&1; then
      rm -f "$scratch"
      print -r -- "$hit"
      return 0
    fi
    sleep 1
  done
  rm -f "$scratch"
  return 1
}

wifi_pair() {
  # A stale server is the usual cause of `protocol fault` during the pairing handshake.
  "$ADB" kill-server >/dev/null 2>&1
  "$ADB" start-server >/dev/null 2>&1
  print -r -- "On the phone: Developer options → Wireless debugging → 'Pair device with pairing code'."
  print -r -- "   Keep that dialog OPEN and the screen awake — closing it kills the pairing port."
  print -n -- "Press Enter once the pairing dialog is showing... "; read -r _
  local pair; pair=$(wifi_mdns "_adb-tls-pairing._tcp" 10)
  if [[ -n $pair ]]; then
    print -r -- "🔍 Found the pairing endpoint over mDNS: $pair"
  else
    warn "no _adb-tls-pairing._tcp over mDNS — the phone is not reachable that way"
    print -r -- "   (AP/client isolation or a guest network blocks this; the phone's hotspot is the quick workaround.)"
    print -n -- "Enter the pairing IP:PORT from the dialog: "; read -r pair
  fi
  local code; print -n -- "Enter the 6-digit pairing code: "; read -r code
  local out; out=$("$ADB" pair "$pair" "$code" 2>&1)
  print -r -- "$out"
  case $out in
    *"Successfully paired"*) ;;
    *)
      cat >&2 <<MSG
❌ Pairing failed. Most common causes, in order:
   1. The pairing dialog closed / the screen slept → reopen it and retry at once.
   2. Wrong port — the PAIRING port differs from the connect port shown above it.
   3. The Wi-Fi blocks device-to-device traffic → the phone's hotspot, or a cable
      once: skiprun android usb
MSG
      return 1 ;;
  esac
  local guid; guid=$(print -r -- "$out" | grep -oE "adb-[A-Za-z0-9]+-[A-Za-z0-9]+" | head -n 1)
  wifi_await_connect "$guid" 30
}

wifi_connect() {
  local locked; locked=$(wifi_locked_file)
  # A pinned endpoint outlives screen-off and Mac sleep; a stale one (phone rebooted) falls through.
  if [[ -s $locked ]] && wifi_connect_once "$(cat "$locked")"; then
    ok "Reconnected to the locked endpoint ($(cat "$locked")). Now: skiprun android --device"
    return 0
  fi
  local conn; conn=$(wifi_mdns "_adb-tls-connect._tcp" 3)
  if [[ -z $conn ]]; then
    warn "could not find the phone over mDNS (is Wireless debugging ON and on the same Wi-Fi?)"
    wifi_is_paired && print -r -- "   (This host IS paired — only the connect is missing.)"
    print -n -- "Enter the phone's IP:PORT from the Wireless debugging screen: "; read -r conn
    [[ -n $conn ]] || die "no address given"
  fi
  if wifi_connect_retry "$conn"; then
    ok "Connected over Wi-Fi ($WIFI_CONN_ADDR). Now: skiprun android --device"
    print -r -- "   Tip: skiprun android lock pins a fixed port that survives screen-off (until reboot)."
  else
    wifi_diagnose "$WIFI_CONN_ADDR"
    return 1
  fi
}

# Android 14+ re-randomizes the wireless-debug port after every doze on purpose. `adb tcpip 5555`
# over a live connection restarts adbd on a fixed port that ignores the Wireless debugging screen.
wifi_lock() {
  local locked; locked=$(wifi_locked_file)
  local serial; serial=$("$ADB" devices | awk '$2 == "device" && $1 ~ /:/ { print $1; exit }')
  [[ -n $serial ]] || die "no Wi-Fi device connected — skiprun android connect first, then lock"
  local ip; ip=$("$ADB" -s "$serial" shell -n ip route 2>/dev/null | awk '/wlan0/ && /src/ { for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1) }' | head -n 1 | tr -d '\r')
  [[ -n $ip ]] || ip=${serial%%:*}
  say "Restarting the phone's adbd on fixed port 5555 (drops the current session)..."
  "$ADB" -s "$serial" tcpip 5555 >/dev/null 2>&1
  sleep 3
  if wifi_connect_once "$ip:5555"; then
    "$ADB" disconnect "$serial" >/dev/null 2>&1
    mkdir -p "${locked:h}"
    print -r -- "$ip:5555" > "$locked"
    print -r -- "🔒 Locked to $ip:5555 until the phone reboots — the screen can sleep now."
    print -r -- "   After a reboot: skiprun android connect, then skiprun android lock."
  else
    print -r -- "❌ Port 5555 did not come up, and the restart dropped the dynamic session too." >&2
    print -r -- "   Recover: toggle Wireless debugging off/on on the phone, then skiprun android connect." >&2
    return 1
  fi
}

# QR pairing: the phone scans the string Android Studio normally shows; the bundled script
# renders it in the terminal. Often succeeds where code pairing hits `protocol fault`.
wifi_qr() {
  local qr=$SKIPRUN_LIBEXEC/adb-qr-pair.py
  [[ -f $qr ]] || die "missing $qr"
  "$ADB" kill-server >/dev/null 2>&1
  "$ADB" start-server >/dev/null 2>&1
  # The service name must start with ADB_WIFI_ for the phone to accept it.
  local name="ADB_WIFI_$RANDOM"
  local code; code=$(printf '%06d' $(( RANDOM % 1000000 )))
  python3 "$qr" "WIFI:T:ADB;S:$name;P:$code;;" || die "could not render the QR"
  print
  print -r -- "On the phone: Developer options → Wireless debugging → 'Pair device with QR code'"
  print -r -- "Point the camera at the QR above. Waiting up to 60s..."
  # After the scan the phone advertises a pairing service named $name; `adb pair` only
  # speaks HOST:PORT, so resolve the name with dns-sd (adb's own mDNS stays empty here).
  local pair_addr="" scratch=${${TMPDIR:-/tmp}%/}/skiprun-qr.$$ hostport="" ip=""
  for _ in $(seq 1 12); do
    wifi_dnssd "$scratch" 3 -L "$name" _adb-tls-pairing._tcp local.
    hostport=$(grep -oE "at [^ ]+:[0-9]+" "$scratch" | head -n 1 | cut -d' ' -f2)
    if [[ -n $hostport ]]; then
      ip=$(wifi_ipv4 "${hostport%:*}")
      if [[ -n $ip ]] && nc -z -w 1 "$ip" "${hostport##*:}" >/dev/null 2>&1; then
        pair_addr="$ip:${hostport##*:}"
        break
      fi
    fi
  done
  rm -f "$scratch"
  if [[ -z $pair_addr ]]; then
    print -r -- "❌ The phone never advertised pairing service '$name'." >&2
    print -r -- "   Either the QR was not scanned, or this Wi-Fi blocks mDNS between devices." >&2
    print -r -- "   Fallbacks: skiprun android pair (code), or skiprun android usb (cable)." >&2
    return 1
  fi
  print -r -- "🔍 Phone answered at $pair_addr — pairing..."
  local out; out=$("$ADB" pair "$pair_addr" "$code" 2>&1)
  print -r -- "$out"
  case $out in
    *"Successfully paired"*) ;;
    *) print -r -- "❌ Pairing handshake failed. Fallback: skiprun android usb (cable)." >&2; return 1 ;;
  esac
  local guid; guid=$(print -r -- "$out" | grep -oE "adb-[A-Za-z0-9]+-[A-Za-z0-9]+" | head -n 1)
  wifi_await_connect "$guid" 30
}

# Cable fallback: authorize over USB once, then switch that device to TCP/IP. Needs neither pairing nor mDNS.
wifi_usb() {
  local serial; serial=$(adb_online_serials | grep -v '^emulator-' | grep -v '_tcp' | grep -v ':' | head -n 1)
  [[ -n $serial ]] || die "no USB device: plug in a DATA cable, unlock the phone, tap 'Allow USB debugging' (check 'Always')"
  local ip; ip=$("$ADB" -s "$serial" shell -n ip route 2>/dev/null | awk '/wlan0/ && /src/ { for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1) }' | head -n 1 | tr -d '\r')
  [[ -n $ip ]] || die "the phone has no wlan0 IP — connect it to Wi-Fi first"
  "$ADB" -s "$serial" tcpip 5555 >/dev/null 2>&1
  sleep 2
  if wifi_connect_once "$ip:5555"; then
    ok "Connected over Wi-Fi ($ip:5555) — the cable can come out. Now: skiprun android --device"
  else
    [[ -n $WIFI_CONNECT_ERR ]] && print -r -- "   adb said: $WIFI_CONNECT_ERR" >&2
    print -r -- "❌ tcpip 5555 did not take (some networks block it). Keep the cable in and run: skiprun android --device" >&2
    return 1
  fi
}

wifi_status() {
  local locked; locked=$(wifi_locked_file)
  print -r -- "— Pairing (persistent, survives reboots):"
  if wifi_is_paired; then
    print -r -- "  ✅ paired ($(strings "$HOME/.android/adb_known_hosts.pb" 2>/dev/null | head -n 1))"
  else
    print -r -- "  ❌ not paired → skiprun android qr"
  fi
  print -r -- "— Locked endpoint (skiprun android lock, survives screen-off until reboot):"
  if [[ -s $locked ]]; then
    local pinned; pinned=$(cat "$locked")
    if nc -z -w 1 "${pinned%:*}" "${pinned##*:}" >/dev/null 2>&1; then
      print -r -- "  ✅ $pinned (port open)"
    else
      print -r -- "  ⚠️  $pinned stored but the port is closed (phone rebooted?) → skiprun android connect, then lock"
    fi
  else
    print -r -- "  ∅ none → after connecting: skiprun android lock"
  fi
  print -r -- "— Live mDNS advertisement (needs the Wireless debugging screen open):"
  local conn; conn=$(wifi_mdns "_adb-tls-connect._tcp" 1)
  if [[ -n $conn ]]; then
    print -r -- "  ✅ advertising at $conn"
  else
    print -r -- "  ∅ nothing live (screen closed, phone dozing, or adbd stuck → toggle / reboot the phone)"
  fi
  print -r -- "— adb connection:"
  "$ADB" devices 2>/dev/null | tail -n +2 | grep -v '^$' | sed 's/^/  /'
  if "$ADB" devices 2>/dev/null | awk '$2 == "device" && $1 ~ /:/ { found = 1 } END { exit !found }'; then
    print -r -- "  ✅ Wi-Fi device connected — skiprun android --device will work"
  else
    print -r -- "  ❌ no Wi-Fi device connected → skiprun android connect"
  fi
}
