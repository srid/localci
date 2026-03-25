let read_cmd ?(quiet_err = false) prog args =
  let argv = Array.of_list (prog :: args) in
  let pipe_r, pipe_w = Unix.pipe ~cloexec:true () in
  let err_fd =
    if quiet_err then Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0
    else Unix.stderr
  in
  let pid = Unix.create_process prog argv Unix.stdin pipe_w err_fd in
  Unix.close pipe_w;
  if quiet_err then Unix.close err_fd;
  let ic = Unix.in_channel_of_descr pipe_r in
  let buf = Buffer.create 256 in
  (try while true do Buffer.add_char buf (input_char ic) done
   with End_of_file -> ());
  close_in ic;
  let _, status = Unix.waitpid [] pid in
  match status with
  | Unix.WEXITED 0 -> Ok (String.trim (Buffer.contents buf))
  | _ -> Error (Printf.sprintf "%s failed" prog)

let run_silent prog args =
  let argv = Array.of_list (prog :: args) in
  let devnull = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
  let pid = Unix.create_process prog argv Unix.stdin devnull devnull in
  Unix.close devnull;
  let _, status = Unix.waitpid [] pid in
  match status with
  | Unix.WEXITED 0 -> Ok ()
  | _ -> Error (Printf.sprintf "%s failed" prog)

let run_in_dir dir cmd_args =
  let cmd_str = String.concat " " cmd_args in
  let pid = Unix.fork () in
  if pid = 0 then begin
    Unix.chdir dir;
    Unix.execvp "bash" [| "bash"; "-c"; cmd_str |]
  end else
    let _, status = Unix.waitpid [] pid in
    match status with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED _ -> 1
    | Unix.WSTOPPED _ -> 1

let run_ssh host dir cmd_args =
  let cmd_str = String.concat " " cmd_args in
  let remote_cmd = Printf.sprintf "cd '%s' && %s" dir cmd_str in
  let argv = [| "ssh"; "-tt"; host; remote_cmd |] in
  let pid = Unix.create_process "ssh" argv Unix.stdin Unix.stdout Unix.stderr in
  let _, status = Unix.waitpid [] pid in
  match status with
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED _ -> 1
  | Unix.WSTOPPED _ -> 1

let get_current_system () =
  match
    read_cmd "nix"
      [ "eval"; "--raw"; "--impure"; "--expr"; "builtins.currentSystem" ]
  with
  | Ok s -> s
  | Error _ ->
    (* Fallback for sandboxed environments where nix eval is unavailable *)
    (match (read_cmd "uname" [ "-m" ], read_cmd "uname" [ "-s" ]) with
     | Ok arch, Ok os -> arch ^ "-" ^ String.lowercase_ascii os
     | _ -> "")

let ensure_ssh_control_dir host =
  match read_cmd "ssh" [ "-G"; host ] with
  | Ok output ->
    String.split_on_char '\n' output
    |> List.iter (fun line ->
         if String.length line > 12
            && String.sub line 0 12 = "controlpath "
         then
           let path = String.sub line 12 (String.length line - 12) in
           let dir = Filename.dirname path in
           if not (Sys.file_exists dir) then
             try Unix.mkdir dir 0o700
             with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  | Error _ -> ()

let self_path () =
  try Ok (Unix.readlink "/proc/self/exe")
  with _ -> (
    try Ok (Unix.realpath Sys.executable_name)
    with _ -> Error "could not resolve self path")

let rec mkdir_p path =
  if Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    (try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  end

let cleanup_remote host dir =
  ignore
    (Unix.create_process "ssh"
       [| "ssh"; host; "rm -rf '" ^ dir ^ "'" |]
       Unix.stdin Unix.stdout Unix.stderr
     |> Unix.waitpid [])

let exit_code status =
  match status with
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED _ -> 1
  | Unix.WSTOPPED _ -> 1
