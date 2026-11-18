[
  .[]
  | ((.labels // []) | map(.name)) as $names
  | select(($names | index("maintenance") // index("update-failed")) | not)
  | select(.title | test("^[^:/]+: ") | not)
  | "#\(.number) \(.title)"
]
| join("; ")
