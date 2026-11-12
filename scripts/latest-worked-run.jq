map(select(.event != "pull_request")) as $own
| ($own | map(select(.conclusion != "skipped")) | .[0]) as $r
| (if ($own | length) > 0 then (($now - ($own[0].createdAt | fromdateiso8601)) / 86400 | floor) else 0 end) as $days
| if $scheduled and $days > 3 then "stopped/\($days)"
  elif $r != null then ($r.status + "/" + ($r.conclusion // "null"))
  elif ($own | length) > 0 then "cadence-only/\($own | length)"
  else "none" end
