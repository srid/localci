let is_in_repo () =
  match
    Exec.read_cmd ~quiet_err:true "git"
      [ "rev-parse"; "--is-inside-work-tree" ]
  with
  | Ok _ -> true
  | Error _ -> false

let is_tree_clean () =
  match Exec.read_cmd ~quiet_err:true "git" [ "status"; "--porcelain" ] with
  | Ok s -> String.length s = 0
  | Error _ -> false

let resolve_ref ref = Exec.read_cmd "git" [ "rev-parse"; ref ]

let pipe_git_archive sha consumer_prog consumer_args =
  let pipe_r, pipe_w = Unix.pipe ~cloexec:true () in
  let archive_pid =
    Unix.create_process "git"
      [| "git"; "archive"; "--format=tar"; sha |]
      Unix.stdin pipe_w Unix.stderr
  in
  Unix.close pipe_w;
  let consumer_argv = Array.of_list (consumer_prog :: consumer_args) in
  let consumer_pid =
    Unix.create_process consumer_prog consumer_argv pipe_r Unix.stdout
      Unix.stderr
  in
  Unix.close pipe_r;
  let _, consumer_status = Unix.waitpid [] consumer_pid in
  let _, archive_status = Unix.waitpid [] archive_pid in
  match consumer_status, archive_status with
  | Unix.WEXITED 0, Unix.WEXITED 0 -> Ok ()
  | _ -> Error "extraction failed"

let extract_local sha dir =
  Exec.mkdir_p dir;
  match pipe_git_archive sha "tar" [ "-C"; dir; "-x" ] with
  | Error _ as e -> e
  | Ok () ->
    let chmod_pid =
      Unix.create_process "chmod"
        [| "chmod"; "-R"; "u+w"; dir |]
        Unix.stdin Unix.stdout Unix.stderr
    in
    let _, status = Unix.waitpid [] chmod_pid in
    (match status with
     | Unix.WEXITED 0 -> Ok ()
     | _ -> Error "chmod failed")

let extract_remote sha host dir =
  let remote_cmd =
    Printf.sprintf "mkdir -p '%s' && tar -C '%s' -x && chmod -R u+w '%s'" dir
      dir dir
  in
  let pipe_r, pipe_w = Unix.pipe ~cloexec:true () in
  let archive_pid =
    Unix.create_process "git"
      [| "git"; "archive"; "--format=tar"; sha |]
      Unix.stdin pipe_w Unix.stderr
  in
  Unix.close pipe_w;
  let ssh_pid =
    Unix.create_process "ssh"
      [| "ssh"; host; remote_cmd |]
      pipe_r Unix.stdout Unix.stderr
  in
  Unix.close pipe_r;
  let _, ssh_status = Unix.waitpid [] ssh_pid in
  let _, archive_status = Unix.waitpid [] archive_pid in
  match ssh_status, archive_status with
  | Unix.WEXITED 0, Unix.WEXITED 0 -> Ok ()
  | _ -> Error "remote extraction failed"
