# Helpers shared by the base-refresh scripts.

# Stops the script with a message, no source span.
export def fail [msg: string] {
  error make --unspanned {msg: $msg}
}

# Runs an external command on the piped input and returns its stdout. A
# non-zero exit stops the script with the command's stderr.
export def --wrapped cmd [...args: string]: any -> string {
  let r = $in | ^($args.0) ...($args | skip 1) | complete
  if $r.exit_code != 0 {
    fail $"($args | str join ' '): ($r.stderr | str trim)"
  }
  $r.stdout
}

# Like cmd, but returns null on a non-zero exit.
export def --wrapped try-cmd [...args: string]: any -> any {
  let r = $in | ^($args.0) ...($args | skip 1) | complete
  if $r.exit_code == 0 { $r.stdout }
}

# A yq path (.a.b[0].c) as a cell path.
export def to-cell-path [path: string]: nothing -> cell-path {
  $path
  | str replace -ar '\[(\d+)\]' '.$1'
  | str trim -l -c '.'
  | split row '.'
  | each {|s| if ($s =~ '^\d+$') { $s | into int } else { $s } }
  | into cell-path
}

# The value at a yq path in a YAML file, null when absent. A file with
# several documents gives the first document that has the path.
export def yaml-value [file: string, path: string]: nothing -> any {
  let cp = to-cell-path $path
  let data = open --raw $file | from yaml
  if ($data | describe) =~ '^(list|table)' {
    $data | each {|doc| $doc | get -o $cp } | compact | get -o 0
  } else {
    $data | get -o $cp
  }
}

# The repository root of the current directory.
export def git-root []: nothing -> string {
  cmd git rev-parse --show-toplevel | str trim
}
