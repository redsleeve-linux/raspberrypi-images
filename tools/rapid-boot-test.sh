#!/bin/bash
# Rapid reboot test against a running Pi: reboot N times, poll SSH every 15 s, run a health check
# after each boot (sshd start time, failed units, cloud-init status, journal errors).
# Usage: tools/rapid-boot-test.sh <pi-address> [count] [password]
# Needs sshpass. The Pi is left running after the last check.
PI=${1:?usage: $0 <pi-address> [count] [password]}
N=${2:-15}
PW=${3:-redsleeve}
SSH="sshpass -p $PW ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"

CHECK='
up=$(cut -d. -f1 /proc/uptime)
sshd_s=$(( $(systemctl show sshd.service -p InactiveExitTimestampMonotonic --value)/1000000 ))
ci_s=$(( $(systemctl show cloud-init.service -p ActiveEnterTimestampMonotonic --value)/1000000 ))
mu_s=$(( $(systemctl show multi-user.target -p ActiveEnterTimestampMonotonic --value)/1000000 ))
failed=$(systemctl --failed --no-legend --plain | awk "{print \$1}" | tr "\n" " ")
nfailed=$(systemctl --failed --no-legend --plain | wc -l)
ci=$(cloud-init status 2>/dev/null | awk -F": " "/^status/{print \$2}")
errs=$(journalctl -b -p err --no-pager 2>/dev/null | grep -vE "audit|AVC|setregdomain|No entries" | wc -l)
echo "SUMMARY uptime=${up}s sshd_start=${sshd_s}s cloud-init_done=${ci_s}s multi-user=${mu_s}s failed=${nfailed} cloud-init=${ci} journal_errors=${errs} sshd=$(systemctl is-active sshd) NM=$(systemctl is-active NetworkManager) firewalld=$(systemctl is-active firewalld) chronyd=$(systemctl is-active chronyd)"
[ "$nfailed" -gt 0 ] && echo "FAILED UNITS: $failed"
[ "$errs" -gt 0 ] && journalctl -b -p err --no-pager 2>/dev/null | grep -vE "audit|AVC|setregdomain|No entries" | tail -5
exit 0
'

echo "=== $(date +%T) target ==="
$SSH redsleeve@$PI 'sudo bash -c "echo BUILDTIME=\$(cat /etc/BUILDTIME); grep -o root=PARTUUID=[0-9a-f-]* /boot/cmdline.txt; echo sshd.socket=\$(systemctl is-enabled sshd.socket 2>&1)"' || { echo "cannot reach $PI"; exit 1; }
good=0
for i in $(seq 1 "$N"); do
    t0=$(date +%s)
    echo "=== $(date +%T) boot $i/$N: reboot ==="
    $SSH redsleeve@$PI "sudo bash -c 'nohup sh -c \"sleep 2; systemctl reboot\" >/dev/null 2>&1 &'"
    sleep 25
    up=0
    while [ $(( $(date +%s) - t0 )) -lt 300 ]; do
        if $SSH redsleeve@$PI true 2>/dev/null; then up=1; break; fi
        sleep 15
    done
    if [ $up -eq 0 ]; then
        echo "$(date +%T) boot $i: SSH NOT REACHABLE after 5 min (ping: $(ping -c1 -W2 "$PI" >/dev/null 2>&1 && echo up || echo down)). Stopping."
        echo "=== result: good=$good of $((i-1)) completed, boot $i BAD ==="
        exit 2
    fi
    echo "$(date +%T) boot $i: SSH up after $(( $(date +%s) - t0 )) s"
    $SSH redsleeve@$PI "sudo bash -c '$CHECK'"
    good=$((good+1))
done
echo "=== result: good=$good of $N ==="
