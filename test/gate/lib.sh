# shellcheck shell=bash
# Shared helpers for the ESXi release gate (test/gate/run.sh and its steps).
# Source it; it defines functions only and changes nothing on load.
#
# Lab values (the ESXi URL, thumbprint, datastore, pool, network, the
# addresses, the NTP server and the account) never appear in the gate's
# output: run.sh sends its own stdout and stderr through gate_redact before
# anything is printed, and every error here names a setting, never its value.

# The settings the runner-local env file provides.
gate_required_vars=(
  GATE_ESXI_URL GATE_ESXI_THUMBPRINT GATE_ESXI_DATASTORE GATE_ESXI_POOL
  GATE_ESXI_NETWORK GATE_CIDR GATE_GATEWAY GATE_ADDRS GATE_NTP
)

# Every setting whose value gate_redact replaces (the required ones, the
# Sneakers secret name and the account).
gate_redact_vars=(
  "${gate_required_vars[@]}" GATE_SNEAKERS_SECRET GATE_ESXI_USERNAME GATE_ESXI_PASSWORD
)

# The gate uses three addresses: the Root, the Intermediate and the fresh
# install.
gate_addrs_needed=3

gate_log() { printf '[gate] %s\n' "$*" >&2; }
gate_die() { gate_log "ERROR: $*"; exit 1; }

# ---- redaction ---------------------------------------------------------------

# gate_redact copies stdin to stdout line by line, replacing the value of
# every setting in gate_redact_vars with [NAME], the host inside
# GATE_ESXI_URL with [GATE_ESXI_HOST], each address in GATE_ADDRS with
# [GATE_ADDR_<n>], and any other IPv4 address with [ipv4]. Values reach perl
# through its environment, never its arguments, so they never show in a
# process listing. Longer values are replaced first, so a value that contains
# another (the pool path holding the host name) is replaced whole.
gate_redact() {
  perl -e '
    use strict; use warnings;
    $| = 1;
    my @pairs;
    for my $n (@ARGV) {
      my $v = $ENV{$n};
      next unless defined $v && length $v;
      push @pairs, [$v, "[$n]"];
    }
    @ARGV = ();
    if (defined $ENV{GATE_ESXI_URL} && $ENV{GATE_ESXI_URL} =~ m{^[a-z][a-z0-9+.-]*://(?:[^@/]*@)?(\[[^\]]+\]|[^/:]+)}i) {
      push @pairs, [$1, "[GATE_ESXI_HOST]"];
    }
    if (defined $ENV{GATE_ADDRS}) {
      my $i = 0;
      for my $a (split " ", $ENV{GATE_ADDRS}) { $i++; push @pairs, [$a, "[GATE_ADDR_$i]"]; }
    }
    @pairs = sort { length($b->[0]) <=> length($a->[0]) } @pairs;
    my @res;
    for my $p (@pairs) {
      my ($v, $t) = @$p;
      my $q = quotemeta $v;
      my $re = $v =~ /^\d{1,3}(?:\.\d{1,3}){3}$/
        ? qr/(?<![0-9A-Za-z.])$q(?![0-9])/
        : qr/$q/;
      push @res, [$re, $t];
    }
    while (my $l = <STDIN>) {
      for my $r (@res) { $l =~ s/$r->[0]/$r->[1]/g; }
      $l =~ s/(?<![0-9A-Za-z.])(?:\d{1,3}\.){3}\d{1,3}(?![0-9]|\.\d)/[ipv4]/g;
      print $l;
    }
  ' "${gate_redact_vars[@]}"
}

# gate_mask_github registers every lab value with the Actions log masker.
# Belt and braces only: gate_redact already keeps the values out of the
# output. It must run before gate_start_redaction, since a redacted
# ::add-mask:: line would mask the placeholder instead of the value.
gate_mask_github() {
  [ "${GITHUB_ACTIONS:-}" = true ] || return 0
  local n v a
  for n in "${gate_redact_vars[@]}"; do
    v="${!n:-}"
    [ -n "$v" ] && printf '::add-mask::%s\n' "$v"
  done
  for a in ${GATE_ADDRS:-}; do printf '::add-mask::%s\n' "$a"; done
  return 0
}

# gate_start_redaction sends the rest of this shell's stdout and stderr
# through gate_redact.
gate_start_redaction() {
  exec > >(gate_redact) 2> >(gate_redact >&2)
}

# ---- settings and the account -------------------------------------------------

# gate_load_env sources the runner-local settings file (GATE_ENV_FILE,
# default /etc/cryptos-gate/lab-esxi.env) when it exists, so a local run can
# export the same names from its own sourced file instead, then checks every
# setting the gate needs. Errors name the setting, never a value.
gate_load_env() {
  local file="${GATE_ENV_FILE:-/etc/cryptos-gate/lab-esxi.env}" n missing=()
  if [ -f "$file" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$file"
    set +a
  fi
  for n in "${gate_required_vars[@]}"; do
    [ -n "${!n:-}" ] || missing+=("$n")
  done
  if [ "${#missing[@]}" -ne 0 ]; then
    gate_log "missing settings: ${missing[*]} (set them in $file on the runner, or export them for a local run)"
    return 1
  fi
  gate_check_addrs
}

gate_is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local i
  for i in 1 2 3 4; do
    [ "${BASH_REMATCH[$i]}" -le 255 ] || return 1
  done
}

gate_check_addrs() {
  local a n=0 prefix
  for a in $GATE_ADDRS; do
    gate_is_ipv4 "$a" || { gate_log "GATE_ADDRS: entry $((n + 1)) is not an IPv4 address"; return 1; }
    n=$((n + 1))
  done
  [ "$n" -ge "$gate_addrs_needed" ] || { gate_log "GATE_ADDRS: the gate needs $gate_addrs_needed addresses, got $n"; return 1; }
  gate_is_ipv4 "$GATE_GATEWAY" || { gate_log "GATE_GATEWAY is not an IPv4 address"; return 1; }
  prefix="${GATE_CIDR#*/}"
  if [ "$prefix" = "$GATE_CIDR" ] || ! [[ "$prefix" =~ ^[0-9]+$ ]] || [ "$prefix" -lt 8 ] || [ "$prefix" -gt 30 ] \
      || ! gate_is_ipv4 "${GATE_CIDR%/*}"; then
    gate_log "GATE_CIDR is not an IPv4 network in a.b.c.d/nn form (nn 8-30)"
    return 1
  fi
  return 0
}

# gate_addr <n> prints the n-th (1-based) address of GATE_ADDRS.
gate_addr() {
  local i=0 a
  for a in $GATE_ADDRS; do
    i=$((i + 1))
    [ "$i" = "$1" ] && { printf '%s\n' "$a"; return 0; }
  done
  return 1
}

gate_prefix() { printf '%s\n' "${GATE_CIDR#*/}"; }

# gate_fetch_account makes the ESXi account available to govc. The runner
# wrapper fetches it from Sneakers (the secret GATE_SNEAKERS_SECRET names,
# fields username and password, with the runner's scoped read-only token) and
# exports it as GATE_ESXI_USERNAME and GATE_ESXI_PASSWORD; this is the one
# place the gate reads it. GitHub holds no part of it.
gate_fetch_account() {
  local missing=()
  [ -n "${GATE_ESXI_USERNAME:-}" ] || missing+=(GATE_ESXI_USERNAME)
  [ -n "${GATE_ESXI_PASSWORD:-}" ] || missing+=(GATE_ESXI_PASSWORD)
  if [ "${#missing[@]}" -ne 0 ]; then
    gate_log "missing ${missing[*]}: the runner wrapper exports the ESXi account fetched from Sneakers (secret named by GATE_SNEAKERS_SECRET)"
    return 1
  fi
  return 0
}

# ---- per-run keys (tmpfs only) ------------------------------------------------

# gate_keys_init makes the run's key directory on /dev/shm. Every key the
# gate makes (the Secure Boot keys K and W, the bootstrap admin, the leaf
# keys) lives there and nowhere else, and gate_keys_shred destroys it.
gate_keys_init() {
  [ -d /dev/shm ] && [ -w /dev/shm ] || { gate_log "/dev/shm is not writable; the gate keeps its keys on tmpfs only"; return 1; }
  GATE_KEYDIR="$(mktemp -d /dev/shm/cryptos-gate-key.XXXXXX)"
  chmod 700 "$GATE_KEYDIR"
  export GATE_KEYDIR
}

gate_keys_shred() {
  [ -n "${GATE_KEYDIR:-}" ] && [ -d "$GATE_KEYDIR" ] || return 0
  find "$GATE_KEYDIR" -type f -exec shred -u {} + 2>/dev/null || true
  rm -rf "$GATE_KEYDIR"
}

# ---- state between steps ------------------------------------------------------

# Steps run in subshells, so what one step records for a later one goes
# through files under $GATE_WORK/state.
gate_state_set() { mkdir -p "$GATE_WORK/state"; printf '%s\n' "$2" > "$GATE_WORK/state/$1"; }
gate_state_get() { cat "$GATE_WORK/state/$1" 2>/dev/null; }

# ---- govc -----------------------------------------------------------------------

# gate_govc runs govc against the lab ESXi. The account and target reach
# govc through its environment for this one call only, and the server
# certificate is checked against GATE_ESXI_THUMBPRINT (no -k).
gate_govc() {
  local host
  host="$(gate_esxi_host)"
  if [ ! -f "$GATE_KEYDIR/known_hosts" ]; then
    printf '%s %s\n' "$host" "$GATE_ESXI_THUMBPRINT" > "$GATE_KEYDIR/known_hosts"
  fi
  GOVC_URL="$GATE_ESXI_URL" GOVC_USERNAME="$GATE_ESXI_USERNAME" GOVC_PASSWORD="$GATE_ESXI_PASSWORD" \
    GOVC_TLS_KNOWN_HOSTS="$GATE_KEYDIR/known_hosts" GOVC_INSECURE=false \
    GOVC_DATASTORE="$GATE_ESXI_DATASTORE" GOVC_NETWORK="$GATE_ESXI_NETWORK" \
    GOVC_RESOURCE_POOL="$GATE_ESXI_POOL" \
    "${GATE_GOVC:-govc}" "$@"
}

gate_esxi_host() {
  local u="${GATE_ESXI_URL#*://}"
  u="${u#*@}"
  u="${u%%/*}"
  printf '%s\n' "${u%%:*}"
}

# Every file the gate writes goes under this folder on GATE_ESXI_DATASTORE.
gate_ds_dir() { printf 'cryptos-gate-%s\n' "$GATE_RUN_ID"; }
gate_vm_name() { printf 'cryptos-gate-%s-%s\n' "$GATE_RUN_ID" "$1"; }

# gate_vm_mac <role-index> prints a fixed MAC in VMware's manually assigned
# range (00:50:56:00:00:00-00:50:56:3f:ff:ff), unique per run and role, so a
# maintenance node's DHCP address can be found by its MAC.
gate_vm_mac() {
  local h
  h="$(printf '%s-%s' "$GATE_RUN_ID" "$1" | sha256sum | cut -c1-6)"
  printf '00:50:56:%02x:%s:%s\n' $(( 0x${h:0:2} & 0x3f )) "${h:2:2}" "${h:4:2}"
}

gate_upload_iso() {
  local local_iso="$1" name="$2" dir
  dir="$(gate_ds_dir)"
  gate_govc datastore.mkdir -p -ds "$GATE_ESXI_DATASTORE" "$dir"
  gate_govc datastore.upload -ds "$GATE_ESXI_DATASTORE" "$local_iso" "$dir/$name" >/dev/null
  printf '%s\n' "$dir/$name" >> "$GATE_WORK/uploaded"
}

# gate_vm_create <role> <role-index> <iso name on the datastore>: an EFI VM
# (Secure Boot off) in GATE_ESXI_POOL with its disk on GATE_ESXI_DATASTORE,
# booting the ISO, with an NVMe disk, an e1000e NIC with the gate's MAC, and
# a serial port wired to a file in the gate's datastore folder.
gate_vm_create() {
  local role="$1" idx="$2" iso="$3" name dir
  name="$(gate_vm_name "$role")"
  dir="$(gate_ds_dir)"
  printf '%s\n' "$name" >> "$GATE_WORK/vms"
  gate_govc vm.create -on=false -pool "$GATE_ESXI_POOL" -ds "$GATE_ESXI_DATASTORE" \
    -g other6xLinux64Guest -firmware=efi -c 2 -m 2048 \
    -disk "${GATE_DISK_GB:-16}GB" -disk.controller nvme \
    -net "$GATE_ESXI_NETWORK" -net.adapter e1000e -net.address "$(gate_vm_mac "$idx")" \
    -iso "$dir/$iso" -iso-datastore "$GATE_ESXI_DATASTORE" \
    "$name"
  gate_govc device.boot -vm "$name" -order cdrom,disk -secure=false
  gate_govc device.serial.add -vm "$name" >/dev/null
  gate_govc device.serial.connect -vm "$name" "[$GATE_ESXI_DATASTORE] $dir/$role-serial.log"
}

gate_vm_power_on() { gate_govc vm.power -on "$(gate_vm_name "$1")" >/dev/null; }
gate_vm_power_cut() { gate_govc vm.power -off -force "$(gate_vm_name "$1")" >/dev/null; }
gate_vm_eject() { gate_govc device.cdrom.eject -vm "$(gate_vm_name "$1")"; }

# gate_teardown destroys every VM this run created and removes the run's
# folder from the datastore. It only ever names this run's VMs and folder.
gate_teardown() {
  local name rc=0
  if [ -f "$GATE_WORK/vms" ]; then
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      gate_govc vm.power -off -force "$name" >/dev/null 2>&1 || true
      gate_govc vm.destroy "$name" || rc=1
    done < "$GATE_WORK/vms"
    rm -f "$GATE_WORK/vms"
  fi
  if [ -f "$GATE_WORK/uploaded" ]; then
    gate_govc datastore.rm -f -ds "$GATE_ESXI_DATASTORE" "$(gate_ds_dir)" || rc=1
    rm -f "$GATE_WORK/uploaded"
  fi
  return "$rc"
}

# ---- finding a maintenance node --------------------------------------------------

# gate_find_maint_addr <role> <role-index> prints the DHCP address a node
# booted from the ISO took. The prod image shows it on the framebuffer only,
# so it is found by the VM's MAC: GATE_DISCOVER_CMD (a runner-local command
# that takes the MAC and prints the address) when set, else govc vm.ip
# -esxcli (needs /Net/GuestIPHack on the host), else the runner's neighbour
# table after a ping sweep of GATE_CIDR (needs the runner on that network).
gate_find_maint_addr() {
  local role="$1" mac addr deadline
  mac="$(gate_vm_mac "$2")"
  deadline=$((SECONDS + ${GATE_DISCOVER_TIMEOUT:-600}))
  while [ "$SECONDS" -lt "$deadline" ]; do
    addr=""
    if [ -n "${GATE_DISCOVER_CMD:-}" ]; then
      addr="$(bash -c "$GATE_DISCOVER_CMD" _ "$mac" 2>/dev/null | head -n1 || true)"
    else
      addr="$(gate_govc vm.ip -esxcli -v4 -wait 10s "$(gate_vm_name "$role")" 2>/dev/null | head -n1 || true)"
      if ! gate_is_ipv4 "$addr"; then
        gate_ping_sweep
        addr="$(ip neigh show 2>/dev/null | awk -v m="$mac" 'tolower($0) ~ m {print $1; exit}')"
      fi
    fi
    if gate_is_ipv4 "$addr" && gate_tcp_up "$addr" 443; then
      printf '%s\n' "$addr"
      return 0
    fi
    sleep 5
  done
  gate_log "$role: no maintenance address found for its MAC within ${GATE_DISCOVER_TIMEOUT:-600}s"
  return 1
}

gate_ping_sweep() {
  local base="${GATE_CIDR%/*}" prefix i n start a b c d
  prefix="$(gate_prefix)"
  [ "$prefix" -ge 22 ] || return 0
  IFS=. read -r a b c d <<<"$base"
  start=$(( (a << 24) | (b << 16) | (c << 8) | d ))
  n=$(( 1 << (32 - prefix) ))
  for ((i = 1; i < n - 1; i++)); do
    local x=$((start + i))
    printf '%d.%d.%d.%d\n' $(( (x >> 24) & 255 )) $(( (x >> 16) & 255 )) $(( (x >> 8) & 255 )) $(( x & 255 ))
  done | xargs -P 64 -I{} ping -c1 -W1 {} >/dev/null 2>&1 || true
}

# ---- reaching a node ---------------------------------------------------------------

gate_tcp_up() { timeout 3 bash -c ">/dev/tcp/$1/$2" 2>/dev/null; }

gate_node_dir() { printf '%s/nodes/%s\n' "$GATE_WORK" "$1"; }

# gate_ctl <role> <args...> runs the candidate cryptosctl against a node as
# the bootstrap admin, trusting the node's pin or its root.
gate_ctl() {
  local role="$1" d
  shift
  d="$(gate_node_dir "$role")"
  "$GATE_CRYPTOSCTL" --endpoint "$(cat "$d/addr"):443" \
    --identity "$GATE_KEYDIR/admin.crt" --identity-key "$GATE_KEYDIR/admin.key" \
    --trust "$d/trust.pem" "$@"
}

gate_ctl_insecure() {
  local addr="$1"
  shift
  "$GATE_CRYPTOSCTL" --endpoint "$addr:443" --insecure "$@"
}

# gate_pin <role> saves whatever certificate the node presents now as its
# trust (before it has a CA the certificate is self-signed and new each boot).
gate_pin() {
  local d
  d="$(gate_node_dir "$1")"
  "$GATE_CRYPTOSCTL" --endpoint "$(cat "$d/addr"):443" --trust "$d/trust.pem" trust fetch >/dev/null
}

# gate_pin_ca <role> waits until the node's listener presents a chain signed
# by its CA and trusts the root at the end of that chain.
gate_pin_ca() {
  local d deadline chain
  d="$(gate_node_dir "$1")"
  deadline=$((SECONDS + 120))
  while [ "$SECONDS" -lt "$deadline" ]; do
    chain="$(gate_server_chain "$(cat "$d/addr")")"
    if [ "$(printf '%s\n' "$chain" | grep -c 'BEGIN CERTIFICATE')" -ge 2 ]; then
      printf '%s\n' "$chain" | awk '/BEGIN CERTIFICATE/{buf=""} {buf=buf $0 "\n"} /END CERTIFICATE/{last=buf} END{printf "%s", last}' > "$d/trust.pem"
      if openssl x509 -in "$d/trust.pem" -noout -text 2>/dev/null | grep -q 'CA:TRUE'; then
        return 0
      fi
    fi
    sleep 2
  done
  gate_log "$1: the listener did not present a CA-signed chain within 120s"
  return 1
}

gate_server_chain() {
  openssl s_client -connect "$1:443" -showcerts </dev/null 2>/dev/null \
    | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/'
}

gate_status_field() {
  # gate_status_field <text> <label>: the value after "<label>:".
  printf '%s\n' "$1" | awk -v l="$2:" 'index($0, l) == 1 { sub(l, ""); gsub(/^[ \t]+|[ \t]+$/, ""); print; exit }'
}

gate_boot_count() { gate_status_field "$(gate_ctl "$1" status)" "Boot count"; }
gate_running_image() { gate_status_field "$(gate_ctl "$1" image status)" "Running image"; }
gate_next_image() { gate_status_field "$(gate_ctl "$1" image status)" "Next boot image"; }

# gate_wait_up <role> [boots-before]: waits for the node's API to answer
# (after a power-on), and when boots-before is given, for a boot count above
# it (after a reboot over the API, the old boot answers for a moment).
gate_wait_up() {
  local role="$1" before="${2:-}" addr deadline n
  addr="$(cat "$(gate_node_dir "$role")/addr")"
  deadline=$((SECONDS + ${GATE_BOOT_TIMEOUT:-900}))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if gate_tcp_up "$addr" 443; then
      n="$(gate_boot_count "$role" 2>/dev/null || true)"
      if [ -n "$n" ] && { [ -z "$before" ] || [ "$n" -gt "$before" ]; }; then
        return 0
      fi
    fi
    sleep 3
  done
  gate_log "$role: the API did not come back within ${GATE_BOOT_TIMEOUT:-900}s"
  return 1
}

# ---- certificates -------------------------------------------------------------------

gate_cert_serial() { openssl x509 -in "$1" -noout -serial | cut -d= -f2 | tr '[:upper:]' '[:lower:]'; }
gate_cert_spki() { openssl x509 -in "$1" -noout -pubkey | openssl pkey -pubin -outform DER | sha256sum | cut -d' ' -f1; }

# gate_first_cert <in> <out>: the first PEM certificate of a bundle.
gate_first_cert() {
  awk '/BEGIN CERTIFICATE/{p=1} p{print} /END CERTIFICATE/{exit}' "$1" > "$2"
}

# gate_new_csr <name> <dns>: a throwaway P-384 key (in the key dir) and CSR;
# prints the CSR path.
gate_new_csr() {
  local name="$1" dns="$2"
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-384 -nodes \
    -keyout "$GATE_KEYDIR/$name.key" -subj "/CN=$dns" -addext "subjectAltName=DNS:$dns" \
    -out "$GATE_WORK/$name.csr" 2>/dev/null
  printf '%s\n' "$GATE_WORK/$name.csr"
}

# gate_new_admin makes the run's bootstrap admin identity in the key dir.
gate_new_admin() {
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
    -keyout "$GATE_KEYDIR/admin.key" -out "$GATE_KEYDIR/admin.crt" \
    -subj "/CN=CryptOS gate bootstrap admin" \
    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=clientAuth" 2>/dev/null
}

# ---- machine configs ----------------------------------------------------------------

gate_indent() { sed "s/^/$1/" "$2"; }

gate_root_config() {
  local name="$1" addr="$2" cn="$3"
  cat <<EOF
apiVersion: cryptos.dev/v1alpha1
kind: MachineConfig
metadata: {name: $name}
role: {kind: root}
network: {interface: eth0, address: $addr/$(gate_prefix), gateway: $GATE_GATEWAY, ntp_servers: [$GATE_NTP]}
state_key: {mode: nodeid}
bootstrap:
  admin_cert_pem: |
$(gate_indent '    ' "$GATE_KEYDIR/admin.crt")
pki:
  root_key_alg: ECDSA-P384
  root_subject: {common_name: "$cn", organization: "CryptOS Gate", country: "US"}
  root_validity_years: 10
  profiles:
    - name: sub-ca
      key_alg: ECDSA-P384
      subject: {common_name: sub-ca}
      validity_days: 1825
      basic_constraints: {is_ca: true, path_len: 0}
      key_usage: [digital_signature, cert_sign, crl_sign]
EOF
}

gate_int_config() {
  local name="$1" addr="$2" cn="$3" root_pem="$4"
  cat <<EOF
apiVersion: cryptos.dev/v1alpha1
kind: MachineConfig
metadata: {name: $name}
role: {kind: intermediate}
network: {interface: eth0, address: $addr/$(gate_prefix), gateway: $GATE_GATEWAY, ntp_servers: [$GATE_NTP]}
state_key: {mode: nodeid}
bootstrap:
  admin_cert_pem: |
$(gate_indent '    ' "$GATE_KEYDIR/admin.crt")
pki:
  root_key_alg: ECDSA-P384
  root_subject: {common_name: "$cn", organization: "CryptOS Gate", country: "US"}
  root_validity_years: 5
  path_len_constraint: 0
  revocation_base_url: http://$addr
  parent:
    ca_cert_pem: |
$(gate_indent '      ' "$root_pem")
  profiles:
    - name: tls-server
      key_alg: ECDSA-P384
      subject: {common_name: tls-server}
      validity_days: 30
      basic_constraints: {is_ca: false}
      key_usage: [digital_signature]
      ext_key_usage: [server_auth]
      allow_request_sans: true
EOF
}

# ---- installing a node from an ISO -----------------------------------------------------

# gate_install <role> <role-index> <iso name on the datastore> <config-file>:
# create the VM, boot the ISO into maintenance, eject the CD so the next boot
# is from disk, apply the config (the node installs and reboots onto its
# static address), wait for it and pin its self-signed certificate.
gate_install() {
  local role="$1" idx="$2" iso="$3" cfg="$4" d maint
  d="$(gate_node_dir "$role")"
  mkdir -p "$d"
  gate_addr "$idx" > "$d/addr"
  gate_vm_create "$role" "$idx" "$iso"
  gate_vm_power_on "$role"
  maint="$(gate_find_maint_addr "$role" "$idx")"
  gate_log "$role: maintenance node answering; applying its config"
  gate_vm_eject "$role"
  gate_ctl_insecure "$maint" config apply -f "$cfg"
  gate_wait_tcp "$(cat "$d/addr")" 443
  gate_pin "$role"
  gate_wait_up "$role"
}

gate_wait_tcp() {
  local deadline=$((SECONDS + ${GATE_BOOT_TIMEOUT:-900}))
  while [ "$SECONDS" -lt "$deadline" ]; do
    gate_tcp_up "$1" "$2" && return 0
    sleep 3
  done
  gate_log "nothing answered on port $2 within ${GATE_BOOT_TIMEOUT:-900}s"
  return 1
}

# ---- the step runner and its summary ------------------------------------------------------

gate_results=()

# gate_note <text> adds a note to the current step's summary row.
gate_note() { printf '%s; ' "$*" >> "$GATE_WORK/step-notes"; }

# gate_skip <reason>: the current step reports skip (with the reason) rather
# than pass when it returns.
gate_skip() { gate_note "$*"; : > "$GATE_WORK/step-skip"; }

# gate_fail <reason>: log the reason, note it and fail the current step.
gate_fail() { gate_log "$*"; gate_note "$*"; return 1; }

# gate_step <id> <title> <function> [dependency ids...]: runs the function in
# a subshell with errexit on, so its first failing command fails the step,
# and records pass, fail or skip (a dependency did not pass, or GATE_ONLY
# leaves it out).
gate_step() {
  local id="$1" title="$2" fn="$3" dep result notes start rc
  shift 3
  : > "$GATE_WORK/step-notes"
  rm -f "$GATE_WORK/step-skip"
  result=""
  if [ -n "${GATE_ONLY:-}" ] && [[ ",$GATE_ONLY," != *",$id,"* ]]; then
    result="skip"
    gate_note "not in GATE_ONLY"
  fi
  if [ -z "$result" ]; then
    for dep in "$@"; do
      if [ "$(gate_state_get "step-$dep")" != pass ]; then
        result="skip"
        gate_note "needs step $dep"
        break
      fi
    done
  fi
  start=$SECONDS
  if [ -z "$result" ]; then
    gate_log "step $id: $title"
    set +e
    ( set -e; "$fn" )
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      result="fail"
    elif [ -f "$GATE_WORK/step-skip" ]; then
      result="skip"
    else
      result="pass"
    fi
    gate_log "step $id: $result"
  fi
  gate_state_set "step-$id" "$result"
  notes="$(sed 's/; $//' "$GATE_WORK/step-notes")"
  gate_results+=("$id|$title|$result|$((SECONDS - start))s|$notes")
}

gate_summary() {
  local row
  printf '| # | Step | Result | Time | Notes |\n|---|---|---|---|---|\n'
  for row in "${gate_results[@]}"; do
    IFS='|' read -r id title result took notes <<<"$row"
    printf '| %s | %s | %s | %s | %s |\n' "$id" "$title" "$result" "$took" "$notes"
  done
}

gate_failed() {
  local row
  for row in "${gate_results[@]}"; do
    [[ "$row" == *"|fail|"* ]] && return 0
  done
  return 1
}
