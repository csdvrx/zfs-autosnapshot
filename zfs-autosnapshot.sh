#!/bin/sh
# Copyright (C) 2021, CS DVRX, MIT License

# basic idea: 1 snapshot every 6 minutes: 10 per hour, then trim that
# to keep: each one of the last 10 snapshots (covering exactly 1h) 
#  + one per hour  for the last 10 hours     (covering <40% of a day)
#  + one per day   for the last 10 days      (covering 1.5x of a week)
# if necessary, further trim down that set until it uses <5% of the disk space
# while keeping at least 10% of the filesystem free at all times to avoid slowdowns
# FIXME: consider adding:
#    one per month for the last 10 months    (covering >80% of a year)

# Variables
NOW=$( date +%Y%m%d%H%M%S )
# find the name of the root dataset
ROOT=$( zfs get -o name available / -H )
# find the total size
SIZE=$( zfs get -o value available / -H | numfmt --from=iec )
# 5% maximum will be used for snapshots
SMAX=$( echo 0.05*$SIZE | bc )
# find the used size
USED=$( zfs get -o value used / -H | numfmt --from=iec )
# ratio currently in use
RATIO=$( echo 100*$USED/$SIZE | bc )

# the cleanup will only keep the snapshots that fit in 5% of the space
# but to avoid zfs slowdowns keep, at least 10% of the filesystem free at all times
# so only proceed with the snapshot iff 10% are free
[ $RATIO -gt 10 ] && zfs snapshot -r $ROOT@t_$NOW || (echo "Over 90% full" && exit 1)

# no easy way to do a oneliner: can only take one dot command
# and then impossible to add sql commands so use a script instead
# sqlite3 /tmp/debug.sqlite3 << EOF
sqlite3 << EOF
-- do everything in memory or comment out for debugging
ATTACH DATABASE ':memory:' AS aux1;
CREATE TABLE snapshots (dataset text, isots text not null, size bigint);
-- now import with the dot commands
.separator " "
.import "|zfs list -t snapshot -o name,used -H | grep '@t_' | sed -e 's/0B/0/' -e 's/@t_/ /'| numfmt --from=iec --field 3" snapshots 
-- to decide what will be kept, the basics is to do a reverse cumulative sum
-- this is because zfs used space for the most recent is 0, for the most ancient is max
-- so do that at each level so the reverse cumulative sum of sizes are correct
-- in each subgroup, for quick eyeballing of the plausibility
CREATE TABLE wanted AS
-- last 10 snaphots every 6 minutes gives 1 hour
SELECT * FROM ( SELECT isots, csize, "last 1h" AS origin FROM (
 SELECT isots, SUM(size) OVER (ROWS UNBOUNDED PRECEDING) AS csize FROM (
  SELECT isots,SUM(size) AS size FROM snapshots GROUP BY isots ORDER BY isots DESC
 ) ) GROUP BY substr(isots,1,12) order by isots DESC LIMIT 10
-- one snapshot per hour for the last 10 hours
) UNION ALL SELECT * from ( select isots, csize, "10 hour" as origin from (
 SELECT isots, SUM(size) OVER (ROWS UNBOUNDED PRECEDING) AS csize FROM (
  SELECT isots,SUM(size) AS size FROM snapshots GROUP BY isots ORDER BY isots DESC
 ) ) GROUP BY substr(isots,1,10) ORDER BY isots DESC LIMIT 10
-- one snapshot per day for the last 10 days
) union all select * from ( select isots, csize, "10 days" as origin from (
 SELECT isots, SUM(size) OVER (ROWS UNBOUNDED PRECEDING) AS csize FROM (
  SELECT isots,SUM(size) AS size FROM snapshots GROUP BY isots ORDER BY isots DESC
 ) ) GROUP BY substr(isots,1,8)  ORDER BY isots DESC LIMIT 10
);

-- what is not to be kept is to be deleted, but this is just a want
-- the list of what is needed will be further constrained by the size budget
ALTER TABLE snapshots ADD COLUMN unwanted BOOL;
UPDATE snapshots SET unwanted = 1 WHERE isots IN (SELECT DISTINCT isots FROM snapshots WHERE isots NOT IN (SELECT isots FROM wanted) ORDER BY isots);

-- but careful as the component csize as previous step included in the last one
-- ie the size of last 10 snaphots=1 hour included in the size of the last 10 hours etc
-- so do a reverse csum over only what is being kept
CREATE TABLE needed AS SELECT isots, csize FROM (SELECT isots, unwanted, SUM(size) OVER (ROWS UNBOUNDED PRECEDING) AS csize FROM (SELECT isots, unwanted, SUM(size) AS size FROM snapshots GROUP BY isots ORDER BY isots DESC)) WHERE unwanted IS NOT 1;

ALTER TABLE needed ADD COLUMN toobig BOOL;
UPDATE needed SET toobig = 1 WHERE csize >= $SMAX;

-- show what we need to keep
SELECT "Keeping up to " || CAST($SMAX/1024/1024 AS INT) || " MB on $ROOT, so only:";
--.once "| awk -F '|' '{print $1 \" \" $2 \" MB \"}'"
SELECT needed.isots, wanted.origin || ",", "current size", (needed.csize/1024/1024), "MB" FROM needed, wanted WHERE needed.isots=wanted.isots AND needed.toobig IS NOT 1 GROUP BY needed.isots ORDER BY wanted.origin,needed.isots DESC;
-- select for deletion what is unwanted (not in the set of 30)
-- and what is not needed (goes over the size budget)
CREATE TABLE destroy AS SELECT DISTINCT isots FROM (SELECT isots FROM snapshots WHERE unwanted IS 1 UNION ALL SELECT isots FROM needed WHERE toobig IS 1) ORDER BY ISOTS ;
SELECT "Destroying recursively on $ROOT", COUNT(DISTINCT isots) || " datasets" FROM destroy;
SELECT isots FROM destroy;
.once "| sh "
SELECT "sudo zfs destroy -r $ROOT@t_" || isots FROM destroy;
-- that's all folks
EOF
