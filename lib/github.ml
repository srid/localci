let get_repo () =
  Exec.read_cmd "gh"
    [ "repo"; "view"; "--json"; "nameWithOwner"; "--jq"; ".nameWithOwner" ]

let post_status repo sha state context description =
  let desc =
    if String.length description > 140 then String.sub description 0 140
    else description
  in
  Exec.run_silent "gh"
    [
      "api";
      "repos/" ^ repo ^ "/statuses/" ^ sha;
      "-f"; "state=" ^ state;
      "-f"; "context=" ^ context;
      "-f"; "description=" ^ desc;
      "--silent";
    ]

let get_default_branch repo =
  Exec.read_cmd "gh" [ "api"; "repos/" ^ repo; "--jq"; ".default_branch" ]
