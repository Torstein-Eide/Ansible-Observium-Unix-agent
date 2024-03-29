#!/bin/bash
#                _                         _
#           ___ | |__  ___  ___ _ ____   _(_)_   _ _ __ ___
#          / _ \| '_ \/ __|/ _ \ '__\ \ / / | | | | '_ ` _ \
#         | (_) | |_) \__ \  __/ |   \ V /| | |_| | | | | | |
#          \___/|_.__/|___/\___|_|    \_/ |_|\__,_|_| |_| |_|
#                                                 Linux Agent
#
#  Copyright (C) Adam Armstrong 2013, (C) Observium Limited 2013-2017
#
#  Based on Check_MK from Mathias Kettner <mk@mathias-kettner.de>
#
# check_mk is free software;  you can redistribute it and/or modify it
# under the  terms of the  GNU General Public License  as published by
# the Free Software Foundation in version 2.  check_mk is  distributed
# in the hope that it will be useful, but WITHOUT ANY WARRANTY;  with-
# out even the implied warranty of  MERCHANTABILITY  or  FITNESS FOR A
# PARTICULAR PURPOSE. See the  GNU General Public License for more de-
# ails.  You should have  received  a copy of the  GNU  General Public
# License along with GNU Make; see the file  COPYING.  If  not,  write
# to the Free Software Foundation, Inc., 51 Franklin St,  Fifth Floor,
# Boston, MA 02110-1301 USA.

# Remove locale settings to eliminate localized outputs where possible
export LC_ALL=C
unset LANG

export AGENT_LIBDIR="/usr/lib/observium_agent"
export AGENT_CONFDIR="/etc/observium"

# Make sure, locally installed binaries are found
PATH=$PATH:/usr/local/bin

# All executables in SCRIPTSDIR and LOCALDIR will simply be executed
# and their ouput appended to the output of the agent. Scripts define
# their own sections and must output headers with '<<<' and '>>>'
# LOCALDIR is included for backwards compatibility with agents < 1.1.x
SCRIPTSDIR=$AGENT_LIBDIR/scripts-enabled
LOCALDIR=$AGENT_LIBDIR/local

# close standard input (for security reasons) and stderr
if [ "$1" = -d ]
then
    set -xv
else
    exec <&- 2>/dev/null
fi

echo '<<<Observium>>>'
echo Version: 1.1.0
echo AgentOS: linux
echo PluginsDirectory: $PLUGINSDIR
echo LocalDirectory: $LOCALDIR
echo AgentDirectory: $AGENT_CONFDIR

# If we are called via xinetd, try to find only_from configuration
if [ -n "$REMOTE_HOST" ]
then
    echo -n 'OnlyFrom: '
    echo $(sed -n '/^service[[:space:]]*observium_agent/,/}/s/^[[:space:]]*only_from[[:space:]]*=[[:space:]]*\(.*\)/\1/p' /etc/xinetd.d/* | head -n1)
fi

# Show filesystems. -P Prevents wrapping long mount points
# Hide NFS mounts to prevent hanging
echo '<<<df>>>'
df -PTlk -x smbfs -x tmpfs -x cifs -x iso9660 -x udf -x nfsv4 | sed 1d
# VMWare shows its own filesystems with 'vdf'. Just one
# problem: it outputs not 7 but only 6 columns
if which vdf > /dev/null
then
   vdf -P | grep ^/vmfs/volumes | sed 's/ / vmfs /'
fi

# Check NFS mounts by accessing them with stat -f (System
# call statfs()). If this lasts more then 2 seconds we
# consider it as hanging. We need waitmax.
if type waitmax >/dev/null
then
    STAT_VERSION=$(stat --version | head -1 | cut -d" " -f4)
    STAT_BROKE="5.3.0"

    echo '<<<nfsmounts>>>'
    sed -n '/ nfs /s/[^ ]* \([^ ]*\) .*/\1/p' < /proc/mounts |
        while read MP
	do
	 if [ $STAT_VERSION != $STAT_BROKE ]; then
	    waitmax -s 9 2 stat -f -c "$MP ok %b %f %a %s" "$MP" || \
		echo "$MP hanging 0 0 0 0"
	 else
	    waitmax -s 9 2 stat -f -c "$MP ok %b %f %a %s" "$MP" && \
	    printf '\n'|| echo "$MP hanging 0 0 0 0"
	 fi
	done
fi

# Check mount options. Filesystems may switch to 'ro' in case
# of a read error.
echo '<<<mounts>>>'
grep ^/dev < /proc/mounts

# processes including username, without kernel processes
echo '<<<ps>>>'
ps ax -o user,vsz,rss,pcpu,command --columns 10000 | sed -e 1d -e 's/ *\([^ ]*\) *\([^ ]*\) *\([^ ]*\) *\([^ ]*\) */(\1,\2,\3,\4) /'

# Memory Usage
echo '<<<mem>>>'
egrep -v '^Swap:|^Mem:|total:' < /proc/meminfo

# Load and active processes.
echo '<<<cpu>>>'
echo "$(cat /proc/loadavg) $(grep -E '^CPU|^processor' < /proc/cpuinfo | wc -l)"

# Uptime
echo '<<<uptime>>>'
cat /proc/uptime

# Network interfaces (Link, Autoneg, Speed)
# This requires ethtool
if which ethtool > /dev/null
then
  echo '<<<netif>>>'
  for eth in $(cat /proc/net/dev | sed -rn -e 's/[[:space:]]*//g' -e  '/ *([^:]):.*/s//\1/p' | egrep -vx '(lo|sit.*)')
  do
    echo $eth $(ethtool $eth | egrep '(Speed|Duplex|Link detected|Auto-negotiation):' | cut -d: -f2 | sed 's/ *//g')
  done
fi

# New variant: Information about speed and state in one section
echo '<<<lnx_if:sep(58)>>>'
sed 1,2d /proc/net/dev
if which ethtool > /dev/null
then
    for eth in $(sed -e 1,2d < /proc/net/dev | cut -d':' -f1)
    do
      echo "[$eth]"
      ethtool $eth | egrep '(Speed|Duplex|Link detected|Auto-negotiation):'
    done
fi

# Number of TCP connections in the various states
echo '<<<tcp_conn_stats>>>'
netstat -nt | awk ' /^tcp/ { c[$6]++; } END { for (x in c) { print x, c[x]; } }'

# Multipath devices.
if which multipath >/dev/null ; then
    echo '<<<multipath>>>'
    multipath -l
fi

# Soft-RAID
echo '<<<md>>>'
cat /proc/mdstat

# Disk performance counters
echo '<<<diskstat>>>'
date +%s
egrep ' (x?[shv]d[a-z]*|cciss/c[0-9]+d[0-9]+) ' < /proc/diskstats

# Kernel performance counters
echo '<<<kernel>>>'
date +%s
cat /proc/vmstat /proc/stat

# Network performance counters (Packets, collisions, etc)
echo '<<<netctr>>>'
# Exact timestamp because counters depend upon the time
date +%s
sed -e 1,2d -e 's/:/ /g' < /proc/net/dev

if which vcbVmName > /dev/null 2>&1 ; then
   echo '<<<vmware_state>>>'
   vcbVmName -s any
fi

if which ntpq > /dev/null 2>&1 ; then
   echo '<<<ntp>>>'
   # remote heading, make first column space separated
   waitmax 2 ntpq -p | sed -e 1,2d -e 's/^\(.\)/\1 /' -e 's/^ /%/'
fi

# Postfix mailqueue monitoring
#
# Only handle mailq when postfix user is present. The mailq command is also
# available when postfix is not installed. But it produces different outputs
# which are not handled by the check at the moment. So try to filter out the
# systems not using postfix by searching for the postfix user.a
#
# Cannot take the whole output. This could produce several MB of agent output
# on blocking queues.
# Only handle the last 6 lines (includes the summary line at the bottom and
# the last message in the queue. The last message is not used at the moment
# but it could be used to get the timestamp of the last message.
if which mailq >/dev/null 2>&1 && getent passwd postfix >/dev/null 2>&1; then
  echo '<<<postfix_mailq>>>'
  mailq | tail -n 6
fi

# First run all scripts in $SCRIPTSDIR
if cd $SCRIPTSDIR
then
  for skript in $(ls|grep -v '~$')
  do
    if [ -x "$skript" ]; then
        ./$skript
    fi
  done
fi

# Then, run all scripts directly in $LOCALDIR
if cd $LOCALDIR
then
  for skript in $(ls|grep -v '~$')
  do
    if [ -x "$skript" ] ; then
        ./$skript
    fi
  done
fi
