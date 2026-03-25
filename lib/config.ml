type step_config = {
  command : string;
  systems : string list;
  depends_on : string list;
}

type config = { steps : (string * step_config) list }

let load_config path =
  if not (Sys.file_exists path) then
    Error (Printf.sprintf "config file not found: %s" path)
  else
    try
      let json = Yojson.Safe.from_file path in
      let open Yojson.Safe.Util in
      let steps_json = member "steps" json |> to_assoc in
      let steps =
        List.map
          (fun (name, sj) ->
            let command = member "command" sj |> to_string in
            let systems =
              match member "systems" sj with
              | `Null -> []
              | lst -> to_list lst |> List.map to_string
            in
            let depends_on =
              match member "depends_on" sj with
              | `Null -> []
              | lst -> to_list lst |> List.map to_string
            in
            (name, { command; systems; depends_on }))
          steps_json
      in
      Ok { steps }
    with
    | Yojson.Json_error msg ->
      Error (Printf.sprintf "failed to parse config: %s" msg)
    | e -> Error (Printf.sprintf "failed to parse config: %s" (Printexc.to_string e))
