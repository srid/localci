open Cmdliner

let resolve_sha sha_pin =
  match sha_pin with
  | Some pin ->
    (match Localci.Git.resolve_ref pin with
     | Ok resolved -> resolved
     | Error _ -> pin)
  | None ->
    if not (Localci.Git.is_tree_clean ()) then begin
      Localci.Log.err
        "Working tree is dirty. Commit or stash changes first.";
      exit 1
    end;
    (match Localci.Git.resolve_ref "HEAD" with
     | Ok s -> s
     | Error e ->
       Localci.Log.err "Could not resolve HEAD: %s" e;
       exit 1)

let run_single_step ~sha ~no_signoff ~name ~system ~workdir ~cmd =
  let name =
    match name with Some n -> n | None -> Filename.basename (List.hd cmd)
  in
  let system_explicit = system <> None in
  let context =
    match system_explicit, system with
    | true, Some s -> Printf.sprintf "localci/%s/%s" name s
    | _ -> Printf.sprintf "localci/%s" name
  in
  let cmd_str = String.concat " " cmd in
  let short = Localci.Log.short_sha sha in
  (* Get repo for GitHub posting *)
  let repo =
    if no_signoff then None
    else
      match Localci.Github.get_repo () with
      | Ok r when r <> "" -> Some r
      | _ ->
        Localci.Log.err
          "Could not determine GitHub repository. Is 'gh' authenticated?";
        exit 1
  in
  Localci.Log.msg "%s  %s" (Localci.Log.bold context)
    (Localci.Log.dim short);
  (match repo with
   | Some r ->
     Localci.Log.info "%s@%s" r short
   | None -> ());
  Localci.Log.info "%s" cmd_str;
  (* Post pending status *)
  (match repo with
   | Some r ->
     ignore (Localci.Github.post_status r sha "pending" context
               ("Running: " ^ cmd_str))
   | None -> ());
  (* Determine local vs remote *)
  let remote =
    system_explicit
    && Localci.Exec.get_current_system ()
       <> (match system with Some s -> s | None -> "")
  in
  let start = Unix.gettimeofday () in
  let rc =
    match workdir with
    | Some dir ->
      (* Pre-extracted workdir from multi-step *)
      if remote then
        let host =
          match
            Localci.Host.get_remote_host
              (match system with Some s -> s | None -> "")
          with
          | Ok h -> h
          | Error e ->
            Localci.Log.err "%s" e;
            exit 1
        in
        Localci.Exec.run_ssh host dir cmd
      else Localci.Exec.run_in_dir dir cmd
    | None ->
      if remote then begin
        let sys = match system with Some s -> s | None -> "" in
        let host =
          match Localci.Host.get_remote_host sys with
          | Ok h -> h
          | Error e ->
            Localci.Log.err "%s" e;
            exit 1
        in
        let remote_dir = Printf.sprintf "/tmp/localci-%s" short in
        Localci.Exec.ensure_ssh_control_dir host;
        Localci.Log.msg "Copying repo to %s..." (Localci.Log.bold host);
        (match Localci.Git.extract_remote sha host remote_dir with
         | Error e ->
           Localci.Log.err "Failed to extract repo remotely: %s" e;
           exit 1
         | Ok () -> ());
        let rc = Localci.Exec.run_ssh host remote_dir cmd in
        Localci.Exec.cleanup_remote host remote_dir;
        rc
      end else begin
        let tmpdir =
          Filename.concat
            (Filename.get_temp_dir_name ())
            (Printf.sprintf "localci-%s-%d" short (Unix.getpid ()))
        in
        Localci.Log.msg "Extracting repo...";
        (match Localci.Git.extract_local sha tmpdir with
         | Error e ->
           Localci.Log.err "Failed to extract repo: %s" e;
           exit 1
         | Ok () -> ());
        let rc = Localci.Exec.run_in_dir tmpdir cmd in
        (try
           ignore
             (Sys.command
                (Printf.sprintf "rm -rf %s" (Filename.quote tmpdir)))
         with _ -> ());
        rc
      end
  in
  let elapsed =
    Localci.Log.fmt_duration (Unix.gettimeofday () -. start)
  in
  if rc = 0 then begin
    Localci.Log.ok "%s passed in %s" (Localci.Log.bold context)
      (Localci.Log.green elapsed);
    (match repo with
     | Some r ->
       ignore
         (Localci.Github.post_status r sha "success" context
            (Printf.sprintf "Passed in %s: %s" elapsed cmd_str))
     | None -> ())
  end else begin
    Localci.Log.warn "%s failed (exit %d) in %s"
      (Localci.Log.bold context) rc (Localci.Log.yellow elapsed);
    (match repo with
     | Some r ->
       ignore
         (Localci.Github.post_status r sha "failure" context
            (Printf.sprintf "Failed (exit %d) in %s: %s" rc elapsed
               cmd_str))
     | None -> ())
  end;
  rc

let run sha_pin no_signoff name system file tui mcp workdir cmd =
  if not (Localci.Git.is_in_repo ()) then begin
    Localci.Log.err "Not inside a git repository.";
    exit 1
  end;
  let sha = resolve_sha sha_pin in
  match file with
  | Some config_file ->
    exit
      (Localci.Multistep.run_multi_step ~sha ~config_file ~tui ~mcp
         ~no_signoff)
  | None ->
    if cmd = [] then begin
      Localci.Log.err
        "A command after -- is required (or use -f for multi-step mode).";
      exit 1
    end;
    exit
      (run_single_step ~sha ~no_signoff ~name ~system ~workdir ~cmd)

let protect file =
  match file with
  | None ->
    Localci.Log.err "protect requires -f <config.json>";
    exit 1
  | Some config_file -> exit (Localci.Protect.run_protect config_file)

(* CLI flags *)
let sha_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "sha" ]
        ~doc:"Pin to a specific commit SHA (skips clean-tree check).")

let name_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "n"; "name" ] ~doc:"Check name for GitHub status context.")

let system_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "s"; "system" ] ~doc:"Nix system string.")

let no_signoff_arg =
  Arg.(
    value & flag
    & info [ "no-signoff" ] ~doc:"Skip GitHub status posting.")

let file_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "f"; "file" ] ~doc:"JSON config file for multi-step mode.")

let tui_arg =
  Arg.(
    value & flag
    & info [ "tui" ]
        ~doc:"Enable process-compose TUI (multi-step mode only).")

let mcp_arg =
  Arg.(
    value & flag
    & info [ "mcp" ]
        ~doc:
          "Expose steps as MCP tools via process-compose (multi-step mode \
           only).")

let workdir_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "workdir" ]
        ~doc:
          "Pre-extracted working directory (internal, used by multi-step \
           mode).")

let cmd_arg =
  Arg.(
    value & pos_all string []
    & info [] ~docv:"CMD" ~doc:"Command to run (after --).")

let run_term =
  Term.(
    const run $ sha_arg $ no_signoff_arg $ name_arg $ system_arg
    $ file_arg $ tui_arg $ mcp_arg $ workdir_arg $ cmd_arg)

let run_info =
  Cmd.info "run" ~doc:"Run a command in a clean git archive."

let protect_term = Term.(const protect $ file_arg)

let protect_info =
  Cmd.info "protect"
    ~doc:"Set branch protection with required status checks."

let default_info =
  Cmd.info "localci"
    ~doc:
      "Local CI tool — run commands on Nix platforms with GitHub status \
       reporting."

let () =
  let run_cmd = Cmd.v run_info run_term in
  let protect_cmd = Cmd.v protect_info protect_term in
  let main_cmd =
    Cmd.group ~default:run_term default_info [ run_cmd; protect_cmd ]
  in
  exit (Cmd.eval main_cmd)
