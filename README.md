## What is zfs-autosnapshot?

zfs-autosnapshot is a shell script that takes snapshots of your root filesystem
automatically, at given intervals, without interfering with your own snapshots.

By itself, this is very simple to do with a systemd or cron timer: you could
just do `zfs snapshot -r` your root filesystem.

In fact you may be tempted to do just that, as zfs snapshot are instantaneous
and do not consume any CPU time or IO, thanks to ZFS copy-on-write, so you may
want to take as many snapshots as possible, like in case you accidentally
removed an important file and have no backups because, oops, you only realized
the file was missing after overwriting your backups (and that's totally *NOT*
taken from a personal example, as I swear, I would never fat finger a rm as
root!)

However, this is not optimal: as time passes, old snapshots requires keeping
old files unique to that snapshot that could otherwise be safely removed. 

For example, after apt upgrade, if /usr/bin/zsh was updated, the old zsh must
be kept just for the sake of the snapshots before that upgrade)

But if a disaster strikes, you may regret not having kept your backups! Yet if
you keep all your backups, you may fill up your filesystem!!

You could decide to have different policies depending on the directory (ex: the
unique files in your /home may be more precious than zsh binaries) but this
would quickly get complicated. It's simpler to just remove old backups.

So what zfs-autosnapshot adds to a simple ` zfs snaphot ` is the automatic
removal of stale snapshots following an heuristic a bit like Ubuntu zsys,
except it's simpler.

## Why is it simpler?

zsys starts from a good idea: keeping snapshots as "wide apart" as possible, to
cover the longest period of time possible, while trimming the redundant
snapshots. For example: if you have 10 backups 1 hour apart of a given day of last
months, if you haven't needed them yet, odds are you won't, so you maybe you
could discard 9 of them and keep just 1, and do the same for the day before, and so on.

However, the implementation of zsys is too complex to my taste, and it is too
Ubuntu-specific. You can easily change the numbers defined by the logic, but
changing the logic itself is harder.

I believe it's easier to do while being as generic as possibe with a few lines
of SQL code (maybe it's because I work with databases :) so I did just that!

## When are snapshots considered "stale" and removed? 

For now, the basic idea is to take 1 snapshot every 6 minutes while keeping at
least 10% of the filesystem free at all times to avoid zfs COW slowdowns.

This means there are 10 snapshots per hour, which rounds nicely in the metric
system. However, as there are 24 hours per day, with 240 snapshots per day, the
logic starts breaking up.

So we keep:
 - each one of the   last 10 snapshots     (covering exactly 1h) 
 - plus one per hour for the last 10 hours (covering <40% of a day)
 - plus one per day  for the last 10 days  (covering 1.5x of a week)

It's not perfectly aligned (about half a day vs more than a week) but it's good enough!

However, this is just a target of what we wish we could keep - but maybe we
don't want to fill the filesystem with snapshots?

So if necessary, we further trim down that list until it uses <5% of the disk
space total.

A future version of the script may add 1 snapshot per month for the last 12 months
(test in progress to guesstimate how much disk space is needed with a regular
Ubuntu)

## Example

Here is a typical output of the script, if you launch it manually:

```{zfs-autosnapshot.sh run by hand}
% zfs-autosnapshot.sh
Keeping up to 58720 MB on nvme/7275, so only:
20210312182814 10 days, current size 0 MB
20210306232257 10 days, current size 72 MB
20210305235825 10 days, current size 215 MB
20210304235710 10 days, current size 364 MB
20210312175856 10 hour, current size 31 MB
20210306225711 10 hour, current size 117 MB
20210306215736 10 hour, current size 136 MB
20210306205408 10 hour, current size 161 MB
20210306011225 10 hour, current size 167 MB
20210306005825 10 hour, current size 174 MB
20210305225924 10 hour, current size 235 MB
20210312182455 last 1h, current size 1 MB
20210312181755 last 1h, current size 2 MB
20210312181152 last 1h, current size 9 MB
20210312180529 last 1h, current size 17 MB
20210312175201 last 1h, current size 49 MB
20210312174557 last 1h, current size 63 MB
20210306231557 last 1h, current size 84 MB
Destroying recursively on nvme/7275 1 datasets
20210306230935
```

I have kept my computer suspended for a week, so I have a gap between March 6
and March 12, 2021.

I started working on the script on March 3, so my 10 days target will only have
entries for March 4,5,6 and 12 (which is today in UTC time - all the times are
in UTC to avoid timezone issues)

As I just turned my computer on, the last 10 hours of work are mostly from when
the computer was not suspended, so on March 5 and March 6, along with just one
hour for today: this gives 7 entries instead of the target of 10 entries.

Finally, for the last hour, the entries are split between today March 12, and 6
days ago on March 6 when the computer was on.

The snapshots are then sorted by growing size, and what doesn't fit is
automatically selected for destruction.

Here, everything fits, but the snapshot taken on March 6 at 11:09pm is selected
for destruction as there's no reason to keep it: it's not important for the
last 1h or the last 10h or the last 10 days (since there's already one on March
6 at 11:22).

This real life example gives you an idea of the heuristic that decides which
snapshots will be kept, and which will be erased.

## That's neat but I have more dataset than Ubuntu. How can I use it with my custom zfs setup?

As long as you use zfs on your root partition, you have nothing to change: the
scripts automatically finds your root filesystem, and then recursively
snapshots.

Likewise, if you like to make your own snapshots, they are safe: script will
not touch a snapshot unless it starts with "@t_", as I find Ubuntu defaults idiotic
and therefore, I manage my datasets and my snapshots myself, like you.
(I mean, seriously Ubuntu, a separate boot pool? Just to keep using grub instead of
retiring it and moving to systemd UEFI boot? Not taking advantage of the EFI
partition for rescue? Thanks but no thanks, I live in the 21st century!)

Here is another example: I have just one pool, with a separate zfs dataset for
each important directory, created with:

```{zfs datasets I use}
	zfs create -o mountpoint=/ nvme/7275
	zfs create -o mountpoint=/etc nvme/7275/etc 
	zfs create -o mountpoint=/opt nvme/7275/opt 
	zfs create -o mountpoint=/usr nvme/7275/usr 
	# for optimization
	zfs create -o mountpoint=/img recordsize=1M primarycache=metadata secondarycache=none nvme/7275/img
	zfs create -o mountpoint=/img/qcow2 recordsize=64k nvme/7275/images/qcow2
	# for safety
	zfs create -o mountpoint=/var nvme/7275/var 
	zfs create -o mountpoint=/var/tmp nvme/7275/var/tmp 
	zfs create -o mountpoint=/tmp nvme/7275/tmp 
	zfs set exec=off nvme/7275/var
	zfs set setuid=on nvme/7275/var/tmp
	zfs set setuid=off devices=off sync=disabled nvme/7275/tmp
	# for systemd-journald
	zfs create -o mountpoint=/var/log nvme/7275/var/log 
	zfs set acltype=posixacl nvme/7275/var/log
	# for postgresql optimization
	zfs create -o mountpoint=/var/lib nvme/7275/var/lib 
	zfs create -o mountpoint=/var/lib/postgresql nvme/7275/var/lib/postgresql 
	zfs set recordsize=8K primarycache=metadata logbias=throughput nvme/7275/var/lib/postgresql
```

The snapshots are visible with `zfs list -t snapshot`, for example for the root filesystem:

```{zfs snapshots for /}
% zfs list -t snapshot nvme/7275
NAME                             USED  AVAIL     REFER  MOUNTPOINT
nvme/7275@1_install               80K      -       96K  -
nvme/7275@2_configured           513M      -      513M  -
nvme/7275@3_preupgrade_libc      120K      -      164K  -
nvme/7275@4_kernel-upgrade       104K      -      164K  -
nvme/7275@5_apt-upgrade           88K      -      156K  -
nvme/7275@6_apt-upgrade           88K      -      156K  -
nvme/7275@7_apt-upgrade           72K      -      156K  -
nvme/7275@t_20210304235710        72K      -      156K  -
nvme/7275@t_20210305225924         0B      -      156K  -
nvme/7275@t_20210305235825         0B      -      156K  -
nvme/7275@t_20210306005825         0B      -      156K  -
nvme/7275@t_20210306011225         0B      -      156K  -
nvme/7275@t_20210306205408        64K      -      156K  -
nvme/7275@t_20210306215736         0B      -      156K  -
nvme/7275@t_20210306225711         0B      -      156K  -
nvme/7275@t_20210306232257         0B      -      156K  -
nvme/7275@8_pre-wine64-install    48K      -      156K  -
nvme/7275@t_20210312174557        48K      -      156K  -
nvme/7275@t_20210312175201         0B      -      156K  -
nvme/7275@t_20210312175856         0B      -      156K  -
nvme/7275@t_20210312180529         0B      -      156K  -
nvme/7275@t_20210312181152         0B      -      156K  -
nvme/7275@t_20210312181755         0B      -      156K  -
nvme/7275@t_20210312182455         0B      -      156K  -
nvme/7275@t_20210312182814         0B      -      156K  -
nvme/7275@t_20210312183155         0B      -      156K  -
```
As you can see, the root filesystem uses very little space, since most of actual data goes into the datasets

You may have noticed I didn't have a separate dataset for /home, but after
upgrading my libc, I changed my mind and decided to create a standalone dataset
for /home with: `zfs create -o mountpoint=/home nvme/7275/home`

Therefore, the zfs list for /home is incomplete (as the dataset didn't exist
when I did the snapshot 1 and 2) but that doesn't cause any problem:

```{zfs snapshots for /home}
% zfs list -t snapshot nvme/7275/home
nvme/7275/home@3_preupgrade_libc     1006M      -      606G  -
nvme/7275/home@4_kernel-upgrade       638M      -      607G  -
nvme/7275/home@5_apt-upgrade          216M      -      607G  -
nvme/7275/home@6_apt-upgrade          375M      -      612G  -
nvme/7275/home@7_apt-upgrade          137M      -      612G  -
nvme/7275/home@t_20210304235710      71.9M      -      612G  -
nvme/7275/home@t_20210305225924      8.16M      -      612G  -
nvme/7275/home@t_20210305235825      6.53M      -      612G  -
nvme/7275/home@t_20210306005825      1.63M      -      612G  -
nvme/7275/home@t_20210306011225      1.64M      -      612G  -
nvme/7275/home@t_20210306205408      10.9M      -      612G  -
nvme/7275/home@t_20210306215736      9.05M      -      612G  -
nvme/7275/home@t_20210306225711      14.9M      -      612G  -
nvme/7275/home@t_20210306232257      3.66M      -      612G  -
nvme/7275/home@8_pre-wine64-install  5.22M      -      612G  -
nvme/7275/home@t_20210312175201      6.82M      -      612G  -
nvme/7275/home@t_20210312175856         7M      -      612G  -
nvme/7275/home@t_20210312180529      3.12M      -      612G  -
nvme/7275/home@t_20210312181152         2M      -      612G  -
nvme/7275/home@t_20210312181755      1.17M      -      612G  -
nvme/7275/home@t_20210312182455       628K      -      612G  -
nvme/7275/home@t_20210312182814      1.36M      -      612G  -
nvme/7275/home@t_20210312183155      1.84M      -      612G  -
nvme/7275/home@t_20210312183851      1.93M      -      612G  -
nvme/7275/home@t_20210312184455       712K      -      612G  -
```

zfs-autosnapshot makes recursive backups automatically, and likewise removes
them automatically, but it will not touch the backup I make manually (like
3_preupgrade_libc, or the more recent 8_pre-wine64-install that I did today as
soon as resumed the computer)

If doing a snapshots would leave less than 10% of the filesystem free,
zfs-autosnapshot will not proceed.

Since I have 612G free, I should be good for a while, even with my 8 manual
snapshots!

## Installation

Install sqlite3: `apt install sqlite3`

Put zfs-autosnapshot.sh in /usr/local/bin : `mv zfs-autosnapshot.sh /usr/local/bin`

Make zfs-autosnapshot.sh executable: `chmod 755 /usr/local/bin/zfs-autosnapshot.sh`

Put everything else in /etc/systemd/system: `mv 6min* zfs-auto* /etc/systemd/system`

Reload systemd: `systemctl daemon-reload`

Enable it with `systemctl enable zfs-autosnapshot@6min.service`

## BTW, why use a 6min.target instead of zfs-autosnapshot.timer?

I wanted to play with systemd timers, and see how one timer could trigger many
different things.

This also lets you define extra timers (ex: 5min.service) if you want a more
precise control of zfs-autosnapshot, for example to execute it at both
periodicity (ex: every 5min and 6min).

As the logic is written in SQL, it will not change much: you will have a finer
granularity of snapshots, but only 10 snapshots of the last hour will be kept
which may be wasteful.

You may have different tastes, so feel free to rename 6min.timer to
zfs-autosnapshot.timer

## Why use sqlite?

I think SQL is more easily accessible to non programmers: for example, the
logic for the last 1 hour with the cumulative size is:

```{selecting 1 timestamp alomg with the cumulative size}
SELECT * FROM ( SELECT isots, csize, "last 1h" AS origin FROM (
 SELECT isots, SUM(size) OVER (ROWS UNBOUNDED PRECEDING) AS csize FROM (
  SELECT isots,SUM(size) AS size FROM snapshots GROUP BY isots ORDER BY isots DESC
 ) ) GROUP BY substr(isots,1,12) order by isots DESC LIMIT 10
```

Also, if you replace sqlite3 by `sqlite3 /tmp/debug.sqlite3`, you can keep a
trace of what was executed, which can help you with the debugging if you don't like my logic.

## I have an idea for an improvement!

Please submit it! As long as zfs-autosnapshot remains simpler than zsys, new features are welcome!
