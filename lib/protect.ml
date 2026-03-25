let build_contexts (config : Config.config) =
  List.concat_map
    (fun (name, (step : Config.step_config)) ->
      if step.systems = [] then [ "localci/" ^ name ]
      else
        List.map
          (fun sys -> Printf.sprintf "localci/%s/%s" name sys)
          step.systems)
    config.steps

let run_protect config_file =
  let config =
    match Config.load_config config_file with
    | Ok c -> c
    | Error e ->
      Log.err "%s" e;
      exit 1
  in
  let repo =
    match Github.get_repo () with
    | Ok r when r <> "" -> r
    | _ ->
      Log.err
        "Could not determine GitHub repository. Is 'gh' authenticated?";
      exit 1
  in
  let branch =
    match Github.get_default_branch repo with
    | Ok b -> b
    | Error e ->
      Log.err "Could not determine default branch: %s" e;
      exit 1
  in
  let contexts = build_contexts config in
  Log.msg "Setting required status checks on %s (%s)" (Log.bold repo)
    branch;
  List.iter (fun ctx -> Log.info "%s" ctx) contexts;
  let payload =
    `Assoc
      [
        ( "required_status_checks",
          `Assoc
            [
              ("strict", `Bool true);
              ( "contexts",
                `List (List.map (fun c -> `String c) contexts) );
            ] );
        ("enforce_admins", `Bool false);
        ("required_pull_request_reviews", `Null);
        ("restrictions", `Null);
      ]
  in
  let payload_str = Yojson.Safe.to_string payload in
  let endpoint =
    Printf.sprintf "repos/%s/branches/%s/protection" repo branch
  in
  (* Pipe payload via stdin to gh api *)
  let pipe_r, pipe_w = Unix.pipe ~cloexec:true () in
  let argv =
    [| "gh"; "api"; endpoint; "-X"; "PUT"; "--input"; "-" |]
  in
  let pid =
    Unix.create_process "gh" argv pipe_r Unix.stdout Unix.stderr
  in
  Unix.close pipe_r;
  let oc = Unix.out_channel_of_descr pipe_w in
  output_string oc payload_str;
  close_out oc;
  let _, status = Unix.waitpid [] pid in
  match status with
  | Unix.WEXITED 0 ->
    Log.ok "Branch protection set on %s/%s" repo branch;
    0
  | _ ->
    Log.err "Failed to set branch protection";
    1
