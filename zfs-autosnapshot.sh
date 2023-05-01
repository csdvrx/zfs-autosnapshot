#!/bin/sh
# Copyright (C) 2023, CS DVRX, MIT License

# basic idea: 1 snapshot every 6 minutes: 10 per hour, then trim that
# to keep: each one of the last 10 snapshots (covering exactly 1h) 
#  + one per hour  for the last 10 hours     (covering <40% of a day)
#  + one per day   for the last 10 days      (covering 1.5x of a week)
#  + one per month for the last 10 months    (covering >80% of a year)
# if necessary, further trim down that set until it uses <5% of the disk space
# while keeping at least 10% of the filesystem free at all times to avoid slowdowns

# Variables
NOW=$( date +%Y%m%d%H%M%S )
POOL=$( zfs get encryptionroot -Ho value / )
# percentage to leave free
PCTF=5
# find the name of the root dataset
ROOT=$( zfs get -o name available / -H )
# find the available size
FREE=$( zfs get -o value available / -H | numfmt --from=iec )
# find the used size
USED=$( zfs get -o value used -H | grep -v "^0B$" | grep -v "^-$" | numfmt --from=iec | sed -e 's/$/\+/' | tr -d "\n" | awk -e '{print $0"0" }' | bc )
# compute what the total size is, and what 5% of the disk space is
SIZE=$( echo "$FREE + $USED" | bc )
SMAX=$( echo "$PCTF * $SIZE" | bc )
# ratio currently free
RATIO=$( echo "100*$FREE/$SIZE" | bc )

# For debug
echo "Now $NOW: $(( $USED / 1024/1024/1024 ))G used on $ROOT, $(( $FREE / 1024/1024/1024 ))G free [$RATIO %] leaving $SMAX [5%] for snapshots"
# [ $RATIO -gt $(( $PCTF * 2 )) ] && echo ok || echo ko

# the cleanup will only keep the snapshots that fit in 5% of the space
# but to avoid zfs slowdowns keep, at least 10% of the filesystem free at all times
# so only proceed with the snapshot iff 10% are free
# this use bc for the test of equality to avoid conversion issues: 1 means success
[ $RATIO -gt $(( $PCTF * 2 )) ] && echo "zfs snapshot -r $POOL@t_$NOW" && (zfs snapshot -r $POOL@t_$NOW) || (echo "No new snapshot because over 90% full: $RATIO %")
# the above can become (echo "... Over 90% full ... " && exit 1) to not delete anything when >90% full
# but better let the deletions of old snapshots smooth things out in time
# the commands below do a grep to only select snapshots and bookmarks that were made by zfs-autosnapshot
# based on a simple regex: @t_[0-9]{14} for snapshots, and #b_[0-9]{14} for bookmarks

# no easy way to do a oneliner: can only take one dot command
# and then impossible to add sql commands so use a script instead
#sqlite3 /tmp/zfs-autosnapshot-debug.sqlite3 << EOF
sqlite3 << EOF
-- do everything in memory or comment out for debugging
ATTACH DATABASE ':memory:' AS aux1;
CREATE TABLE snapshots (dataset text, isots text not null, size bigint);
-- now import with the dot commands
.separator " "
.import "|zfs list -t snapshot -o name,used -H | grep '@t_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]' | sed -e 's/0B/0/' -e 's/@t_/ /'| numfmt --from=iec --field 3" snapshots 
CREATE TABLE bookmarks (dataset text, isots text not null, size bigint);
-- FIXME : [0-9]\{14\} seem to not work, so I did that ugly
.import "|zfs list -t bookmark -o name,refer -H | grep '#b_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]' | sed -e 's/0B/0/' -e 's/#b_/ /'| numfmt --from=iec --field 3" bookmarks
-- to decide what will be kept, the basics is to do a reverse cumulative sum
-- this is because 'zfs used' for the most recent is 0, for the most ancient is max:
-- SELECT isots, SUM(size) OVER (ROWS UNBOUNDED PRECEDING) AS csize FROM (SELECT isots,SUM(size) AS size FROM snapshots GROUP BY isots ORDER BY isots DESC);
-- do that at each level so the reverse cumulative sum of sizes are correct
-- in each subgroup, for quick eyeballing of the plausibility
CREATE TABLE wanted AS
-- last 10 snaphots every 6 minutes = 1 hour
SELECT * FROM ( SELECT isots, csize, 'last 1h' AS origin FROM (
 SELECT isots, SUM(size) OVER (ROWS UNBOUNDED PRECEDING) AS csize FROM (
  SELECT isots,SUM(size) AS size FROM snapshots GROUP BY isots ORDER BY isots DESC
 ) ) GROUP BY substr(isots,1,12) order by isots DESC LIMIT 10
-- one snapshot per hour for the last 10 hours
) UNION ALL SELECT * from ( SELECT isots, csize, '10 hours' AS origin FROM (
 SELECT isots, SUM(size) OVER (ROWS UNBOUNDED PRECEDING) AS csize FROM (
  SELECT isots,SUM(size) AS size FROM snapshots GROUP BY isots ORDER BY isots DESC
 ) ) GROUP BY substr(isots,1,10) ORDER BY isots DESC LIMIT 10
-- one snapshot per day for the last 10 days
) UNION ALL SELECT * from ( SELECT isots, csize, '10 days' as origin FROM (
 SELECT isots, SUM(size) OVER (ROWS UNBOUNDED PRECEDING) AS csize FROM (
  SELECT isots,SUM(size) AS size FROM snapshots GROUP BY isots ORDER BY isots DESC
 ) ) GROUP BY substr(isots,1,8)  ORDER BY isots DESC LIMIT 10
-- one snapshot per month for the last 10 months
) UNION ALL SELECT * from ( SELECT isots, csize, '10 months' as origin FROM (
 SELECT isots, SUM(size) OVER (ROWS UNBOUNDED PRECEDING) AS csize FROM (
  SELECT isots,SUM(size) AS size FROM snapshots GROUP BY isots ORDER BY isots DESC
 ) ) GROUP BY substr(isots,1,8)  ORDER BY isots DESC LIMIT 10
);

-- what is not to be kept is to be deleted, but this is just a want
-- the list of what is needed will be further constrained by the size budget
ALTER TABLE snapshots ADD COLUMN unwanted BOOL;
UPDATE snapshots SET unwanted = 1 WHERE isots IN (SELECT DISTINCT isots FROM snapshots WHERE isots NOT IN (SELECT isots FROM wanted) ORDER BY isots);

-- but careful as the component csize as previous step is included in the last one
-- ie the size of last 10 snaphots=1 hour is included in the size of the last 10 hours etc
-- so do a reverse csum over only what is being kept
CREATE TABLE needed AS SELECT isots, csize FROM (SELECT isots, unwanted, SUM(size) OVER (ROWS UNBOUNDED PRECEDING) AS csize FROM (SELECT isots, unwanted, SUM(size) AS size FROM snapshots GROUP BY isots ORDER BY isots DESC)) WHERE unwanted IS NOT 1;

ALTER TABLE needed ADD COLUMN toobig BOOL;
UPDATE needed SET toobig = 1 WHERE csize >= $SMAX;

-- show what we need to keep
SELECT 'Keeping up to ' || round($SMAX/1024/1024) || ' MB on $ROOT, so only snapshots dated:';
SELECT needed.isots, wanted.origin || ',', 'current size', (needed.csize/1024/1024), 'MB' FROM needed, wanted WHERE needed.isots=wanted.isots AND needed.toobig IS NOT 1 GROUP BY needed.isots ORDER BY wanted.origin,needed.isots DESC;
-- select for deletion what is unwanted (not in the set of 30)
-- and what is not needed (goes over the size budget)
CREATE TABLE destroy AS SELECT DISTINCT isots FROM (SELECT isots FROM snapshots WHERE unwanted IS 1 UNION ALL SELECT isots FROM needed WHERE toobig IS 1) ORDER BY ISOTS ;
SELECT 'Converting to bookmark old snapshots on $ROOT', COUNT(DISTINCT isots) || ' datasets dated:' FROM destroy;
SELECT isots FROM destroy;
.once "| sh "
SELECT 'sudo zfs bookmark ' || dataset || '@t_' || snapshots.isots || ' \\#b_' || snapshots.isots FROM snapshots, destroy WHERE snapshots.isots=destroy.isots AND snapshots.isots NOT IN (select isots from bookmarks );
SELECT 'Reclaiming space by destroying these old snapshots:';
.once "| sh "
--SELECT 'sudo zfs destroy -p -r $ROOT@t_' || isots FROM destroy;
-- allow for nothing to be destroyed by adding a conditional
SELECT  ' [ ' || count (distinct isots) || ' -gt 1 ] && sudo zfs destroy -p -r $ROOT@t_' || isots FROM destroy;
-- that's all folks
EOF
