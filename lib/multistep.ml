type process_entry = {
  step : string;
  sys : string;
  key : string;
}

let collect_systems (config : Config.config) =
  let seen = Hashtbl.create 8 in
  let systems = ref [] in
  List.iter
    (fun (_, (step : Config.step_config)) ->
      List.iter
        (fun sys ->
          if not (Hashtbl.mem seen sys) then begin
            Hashtbl.add seen sys true;
            systems := sys :: !systems
          end)
        step.systems)
    config.steps;
  List.rev !systems

let build_process_entries (config : Config.config) =
  List.concat_map
    (fun (step_name, (step : Config.step_config)) ->
      let systems =
        if step.systems = [] then [ "" ] else step.systems
      in
      List.map
        (fun sys ->
          let key =
            if sys = "" then step_name
            else Printf.sprintf "%s (%s)" step_name sys
          in
          { step = step_name; sys; key })
        systems)
    config.steps

let generate_pc_config procs (config : Config.config) sha self cwd log_dir
    host_map workdir_map mcp_mode no_signoff =
  let short = Log.short_sha sha in
  let processes =
    List.map
      (fun p ->
        let step = List.assoc p.step config.steps in
        let step_sha =
          if mcp_mode then "@{sha:HEAD}" else sha
        in
        let cmd_parts = ref [ self; "--sha"; step_sha ] in
        if no_signoff then
          cmd_parts := !cmd_parts @ [ "--no-signoff" ];
        if p.sys <> "" then begin
          cmd_parts := !cmd_parts @ [ "-s"; p.sys ];
          if not mcp_mode then
            match List.assoc_opt p.sys workdir_map with
            | Some dir -> cmd_parts := !cmd_parts @ [ "--workdir"; dir ]
            | None -> ()
        end;
        cmd_parts :=
          !cmd_parts @ [ "-n"; p.step; "--"; step.command ];
        (* Resolve dependencies: same step name + same system *)
        let depends_on =
          List.filter_map
            (fun dep_name ->
              List.find_opt
                (fun dp -> dp.step = dep_name && dp.sys = p.sys)
                procs
              |> Option.map (fun dp ->
                   ( dp.key,
                     `Assoc
                       [
                         ( "condition",
                           `String "process_completed_successfully" );
                       ] )))
            step.depends_on
        in
        let log_file =
          Filename.concat log_dir
            (Report.sanitize_log_name p.key ^ ".log")
        in
        let namespace =
          if p.sys <> "" then
            let hostname =
              match List.assoc_opt p.sys host_map with
              | Some h -> h
              | None -> "local"
            in
            Printf.sprintf "%s (%s) @%s" p.sys hostname short
          else "@" ^ short
        in
        let fields =
          [
            ("command", `String (String.concat " " !cmd_parts));
            ("working_dir", `String cwd);
            ("log_location", `String log_file);
            ("namespace", `String namespace);
            ("shutdown", `Assoc [ ("signal", `Int 9) ]);
          ]
        in
        let fields =
          if depends_on <> [] then
            fields @ [ ("depends_on", `Assoc depends_on) ]
          else fields
        in
        let fields =
          if mcp_mode then
            fields
            @ [
                ("disabled", `Bool true);
                ( "mcp",
                  `Assoc
                    [
                      ("type", `String "tool");
                      ( "arguments",
                        `List
                          [
                            `Assoc
                              [
                                ("name", `String "sha");
                                ("type", `String "string");
                                ( "description",
                                  `String
                                    "Git ref to test (default: HEAD)" );
                                ("required", `Bool false);
                              ];
                          ] );
                    ] );
              ]
          else
            fields
            @ [
                ( "availability",
                  `Assoc [ ("restart", `String "exit_on_failure") ] );
              ]
        in
        (p.key, `Assoc fields))
      procs
  in
  let top_fields =
    [
      ("version", `String "0.5");
      ( "log_configuration",
        `Assoc [ ("flush_each_line", `Bool true) ] );
    ]
  in
  let top_fields =
    if mcp_mode then
      top_fields
      @ [ ("mcp_server", `Assoc [ ("transport", `String "stdio") ]) ]
    else top_fields
  in
  let top_fields =
    top_fields @ [ ("processes", `Assoc processes) ]
  in
  `Assoc top_fields

let run_multi_step ~sha ~config_file ~tui ~mcp ~no_signoff =
  let config =
    match Config.load_config config_file with
    | Ok c -> c
    | Error e ->
      Log.err "%s" e;
      1
      |> exit
  in
  let short = Log.short_sha sha in
  Log.msg "Multi-step mode: %s  %s" (Log.bold config_file)
    (Log.dim ("SHA=" ^ short));
  let current_system = Exec.get_current_system () in
  let cwd = Sys.getcwd () in
  let all_systems = collect_systems config in
  (* Resolve remote hosts upfront *)
  let host_map = ref [ (current_system, Unix.gethostname ()) ] in
  List.iter
    (fun sys ->
      if sys <> current_system then
        match Host.get_remote_host sys with
        | Ok host ->
          host_map := (sys, host) :: !host_map;
          Log.msg "Warming SSH connection to %s (%s)..." (Log.bold host) sys;
          ignore
            (Unix.create_process "ssh"
               [| "ssh"; host; "echo"; "ok" |]
               Unix.stdin Unix.stdout Unix.stderr
             |> Unix.waitpid [])
        | Error e ->
          Log.err "Failed to get host for %s: %s" sys e;
          exit 1)
    all_systems;
  (* Pre-extract repo per system (skip in MCP mode) *)
  let workdir_map = ref [] in
  let workdir_base = "/tmp/localci-" ^ short in
  if not mcp then begin
    let local_dir = workdir_base ^ "-local" in
    Log.msg "Extracting repo (local)...";
    (match Git.extract_local sha local_dir with
     | Ok () -> workdir_map := (current_system, local_dir) :: !workdir_map
     | Error e ->
       Log.err "Failed to extract repo locally: %s" e;
       exit 1);
    List.iter
      (fun sys ->
        if sys <> current_system then
          let host = List.assoc sys !host_map in
          let rdir = Printf.sprintf "%s-%s" workdir_base sys in
          Log.msg "Extracting repo on %s (%s)..." (Log.bold host) sys;
          match Git.extract_remote sha host rdir with
          | Ok () -> workdir_map := (sys, rdir) :: !workdir_map
          | Error e ->
            Log.err "Failed to extract repo on %s: %s" host e;
            exit 1)
      all_systems
  end;
  (* Log directory *)
  let log_dir = Printf.sprintf "/tmp/localci-%s-logs" short in
  (try
     ignore (Sys.command ("rm -rf " ^ Filename.quote log_dir))
   with _ -> ());
  Exec.mkdir_p log_dir;
  (* Build process entries *)
  let procs = build_process_entries config in
  (* Write manifest *)
  let manifest_entries =
    List.map
      (fun p ->
        {
          Report.key = p.key;
          step = p.step;
          system = p.sys;
          log_file =
            Filename.concat log_dir
              (Report.sanitize_log_name p.key ^ ".log");
        })
      procs
  in
  Report.write_manifest log_dir manifest_entries;
  (* Resolve self path *)
  let self =
    match Exec.self_path () with
    | Ok p -> p
    | Error e ->
      Log.err "Could not resolve self path: %s" e;
      exit 1
  in
  (* Generate process-compose config *)
  let pc_json =
    generate_pc_config procs config sha self cwd log_dir !host_map
      !workdir_map mcp no_signoff
  in
  let pc_file = Filename.temp_file "localci-pc-" ".json" in
  let oc = open_out pc_file in
  Yojson.Safe.pretty_to_channel oc pc_json;
  output_char oc '\n';
  close_out oc;
  (* Run process-compose *)
  let pc_args =
    [ "up"; "--config"; pc_file ]
    @ (if mcp then [ "--tui=false"; "--no-server" ]
       else
         [
           "--tui=" ^ string_of_bool tui;
           "--no-server";
         ])
  in
  let pc_argv = Array.of_list ("process-compose" :: pc_args) in
  let pc_pid =
    Unix.create_process "process-compose" pc_argv Unix.stdin Unix.stdout
      Unix.stderr
  in
  let _, pc_status = Unix.waitpid [] pc_pid in
  let pc_exit = Exec.exit_code pc_status in
  (* Cleanup *)
  (try Sys.remove pc_file with _ -> ());
  if pc_exit = 0 then (
    try ignore (Sys.command ("rm -rf " ^ Filename.quote log_dir))
    with _ -> ());
  if not mcp then begin
    let local_dir = workdir_base ^ "-local" in
    (try ignore (Sys.command ("rm -rf " ^ Filename.quote local_dir))
     with _ -> ());
    List.iter
      (fun sys ->
        if sys <> current_system then begin
          let host = List.assoc sys !host_map in
          let rdir = Printf.sprintf "%s-%s" workdir_base sys in
          Exec.cleanup_remote host rdir
        end)
      all_systems
  end;
  (* Summary *)
  if not mcp then begin
    Printf.eprintf "\n%!";
    if pc_exit = 0 then Log.ok "All steps passed"
    else begin
      Log.warn "One or more steps failed (exit %d)" pc_exit;
      Report.print_step_report log_dir;
      Log.info "Full logs: %s/" log_dir
    end
  end;
  pc_exit
