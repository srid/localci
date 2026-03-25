let is_tty = Unix.isatty Unix.stderr

let sgr code s =
  if is_tty then Printf.sprintf "\027[%sm%s\027[0m" code s else s

let bold s = sgr "1" s
let dim s = sgr "2" s
let cyan_bold s = sgr "1;36" s
let green_bold s = sgr "1;32" s
let yellow_bold s = sgr "1;33" s
let red_bold s = sgr "1;31" s
let green s = sgr "32" s
let yellow s = sgr "33" s

let msg fmt = Printf.ksprintf (fun s -> Printf.eprintf "%s %s\n%!" (cyan_bold "==>") s) fmt
let info fmt = Printf.ksprintf (fun s -> Printf.eprintf "    %s\n%!" (dim s)) fmt
let err fmt = Printf.ksprintf (fun s -> Printf.eprintf "%s %s\n%!" (red_bold "Error:") s) fmt
let ok fmt = Printf.ksprintf (fun s -> Printf.eprintf "%s %s\n%!" (green_bold "==>") s) fmt
let warn fmt = Printf.ksprintf (fun s -> Printf.eprintf "%s %s\n%!" (yellow_bold "==>") s) fmt

let fmt_duration secs =
  let s = int_of_float secs in
  if s >= 3600 then Printf.sprintf "%dh%02dm%02ds" (s / 3600) ((s mod 3600) / 60) (s mod 60)
  else if s >= 60 then Printf.sprintf "%dm%02ds" (s / 60) (s mod 60)
  else Printf.sprintf "%ds" s

let short_sha sha =
  if String.length sha > 12 then String.sub sha 0 12 else sha
