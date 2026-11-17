[
  .[]
  | ((.labels // []) | map(.name)) as $names
  | select(($names | index("maintenance") // index("update-failed")) | not)
  | select(($names | map(select(startswith("type/"))) | length) != 1)
  | "#\(.number) \(.title)"
]
| join("; ")
