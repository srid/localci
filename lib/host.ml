let hosts_file_path () =
  let config_dir =
    match Sys.getenv_opt "XDG_CONFIG_HOME" with
    | Some d when d <> "" -> d
    | _ ->
      (match Sys.getenv_opt "HOME" with
       | Some h -> Filename.concat h ".config"
       | None -> ".config")
  in
  Filename.concat (Filename.concat config_dir "localci") "hosts.json"

let load_hosts () =
  let path = hosts_file_path () in
  if not (Sys.file_exists path) then []
  else
    try
      let json = Yojson.Safe.from_file path in
      Yojson.Safe.Util.to_assoc json
      |> List.map (fun (k, v) -> (k, Yojson.Safe.Util.to_string v))
    with _ -> []

let save_host system host =
  let hosts = load_hosts () in
  let hosts =
    (system, host)
    :: List.filter (fun (k, _) -> k <> system) hosts
  in
  let json =
    `Assoc (List.map (fun (k, v) -> (k, `String v)) hosts)
  in
  let path = hosts_file_path () in
  Exec.mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Yojson.Safe.pretty_to_channel oc json;
  close_out oc

let valid_hostname s =
  String.length s > 0
  &&
  let rec check i =
    if i >= String.length s then true
    else
      let c = s.[i] in
      ((c >= 'a' && c <= 'z')
       || (c >= 'A' && c <= 'Z')
       || (c >= '0' && c <= '9')
       || c = '.' || c = '_' || c = '-')
      && check (i + 1)
  in
  check 0

let get_remote_host system =
  let hosts = load_hosts () in
  match List.assoc_opt system hosts with
  | Some host when host <> "" ->
    Log.msg "Using saved host for %s: %s" system (Log.bold host);
    Ok host
  | _ ->
    Printf.eprintf "==> Enter hostname for %s: %!" system;
    (try
       let host = input_line stdin in
       if not (valid_hostname host) then
         Error (Printf.sprintf "invalid hostname: %s" host)
       else begin
         (try save_host system host
          with _ -> Log.warn "Could not save host");
         Ok host
       end
     with End_of_file -> Error "no hostname provided")
