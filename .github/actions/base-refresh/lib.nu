# Helpers shared by the base-refresh scripts.

export def fail [msg: string] {
  error make --unspanned {msg: $msg}
}

# Runs an external command on the piped input and returns its stdout. A non-zero exit stops the script.
export def --wrapped cmd [...args: string]: any -> string {
  let r = $in | ^($args.0) ...($args | skip 1) | complete
  if $r.exit_code != 0 { fail $"($args | str join ' '): ($r.stderr | str trim)" }
  $r.stdout
}

# Like cmd, but returns null on a non-zero exit.
export def --wrapped try-cmd [...args: string]: any -> any {
  let r = $in | ^($args.0) ...($args | skip 1) | complete
  if $r.exit_code == 0 { $r.stdout }
}

# The value at a yq path (.a.b[0].c) in a YAML file, null when absent. With several documents: the first that has it.
export def yaml-value [file: string, path: string]: nothing -> any {
  let cp = $path | str replace -ar '\[(\d+)\]' '.$1' | str trim -l -c '.' | split row '.'
    | each {|s| if ($s =~ '^\d+$') { $s | into int } else { $s } } | into cell-path
  let data = open --raw $file | from yaml
  if ($data | describe) =~ '^(list|table)' { $data | each {|doc| $doc | get -o $cp } | compact | get -o 0 } else { $data | get -o $cp }
}

export def git-root []: nothing -> string {
  cmd git rev-parse --show-toplevel | str trim
}
