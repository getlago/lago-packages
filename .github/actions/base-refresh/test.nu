#!/usr/bin/env nu
# Unit tests of the pure parts of the base-refresh scripts: `nu test.nu`.
use std/assert
use lib.nu [to-cell-path yaml-value]
use plan.nu [parse-release starts-with-layers]
use describe.nu [apk-packages package-diff by-cve]
use bump.nu edit-tag

def test-parse-release [] {
  assert equal (parse-release 'abc1234') {release: 'abc1234', short: 'abc1234'}
  assert equal (parse-release 'sha-abc1234-base.0123456789ab') {release: 'sha-abc1234', short: 'abc1234'}
  assert equal (parse-release 'rev-rec-abc1234.build-42') {release: 'rev-rec-abc1234.build-42', short: 'abc1234'}
  assert equal (parse-release 'v1.55.0') null
  assert equal (parse-release 'latest') null
}

def test-starts-with-layers [] {
  assert (starts-with-layers [a b c] [a b])
  assert not (starts-with-layers [a x c] [a b])
  assert not (starts-with-layers [a] [a b])
}

def test-yaml-value [] {
  let dir = mktemp -d
  "a:\n  b:\n    - c: 'x:1'\n" | save $"($dir)/one.yaml"
  "kind: A\n---\nimage:\n  tag: v2\n" | save $"($dir)/multi.yaml"
  assert equal (yaml-value $"($dir)/one.yaml" '.a.b[0].c') 'x:1'
  assert equal (yaml-value $"($dir)/one.yaml" '.a.missing') null
  assert equal (yaml-value $"($dir)/multi.yaml" '.image.tag') 'v2'
  assert equal (to-cell-path '.a.b[0].c' | describe) 'cell-path'
  rm -r $dir
}

def test-edit-tag [] {
  let content = "image:\n  repository: foo\n  tag: \"abc1234\" # deployed\nother:\n  tag: def5678\n"
  assert equal (edit-tag $content 'tag' 'abc1234' 'abc1234-base.0123456789ab') "image:\n  repository: foo\n  tag: \"abc1234-base.0123456789ab\" # deployed\nother:\n  tag: def5678\n"
  # A full image reference keeps its repository.
  assert equal (edit-tag "    image: r.io/x:abc1234\n" 'image' 'abc1234' 'new') "    image: r.io/x:new\n"
  # The dot of a tag is literal, and two matching lines refuse the edit.
  assert equal (edit-tag "tag: abc1234xbuild\n" 'tag' 'abc1234.build' 'new') null
  assert equal (edit-tag "tag: a1\ntag: a1\n" 'tag' 'a1' 'new') null
}

def test-apk-packages [] {
  let db = "C:x\nP:busybox\nV:1.37-r1\n\nP:openssl\nV:3.5.1-r0\nA:x86_64\n"
  assert equal (apk-packages $db) [[package version]; [busybox 1.37-r1] [openssl 3.5.1-r0]]
}

def test-package-diff [] {
  let old = [[package version]; [a 1] [b 1] [c 1]]
  let new = [[package version]; [b 1] [c 2] [d 1]]
  assert equal (package-diff $old $new) [[package old new]; [a 1 '-'] [c 1 2] [d '-' 1]]
}

def test-by-cve [] {
  let findings = [[id severity pkg]; [CVE-2 HIGH openssl] [CVE-1 LOW zlib] [CVE-2 HIGH libssl3]]
  assert equal (by-cve $findings) ['- CVE-1 (LOW): `zlib`' '- CVE-2 (HIGH): `openssl`, `libssl3`']
  let many = 1..52 | each {|i| {id: $"CVE-($i | fill -a r -c '0' -w 3)", severity: LOW, pkg: p} }
  let items = by-cve $many
  assert equal ($items | length) 51
  assert equal ($items | last) '- … and 2 more'
}

def main [] {
  test-parse-release
  test-starts-with-layers
  test-yaml-value
  test-edit-tag
  test-apk-packages
  test-package-diff
  test-by-cve
  print 'base-refresh: all tests passed'
}
